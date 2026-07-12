import asyncio
import base64
import unittest

from hermes_bridge import (
    is_visual_query, await_photo, build_provider_request, parse_provider_reply,
)


class TestIsVisualQuery(unittest.TestCase):
    def test_visual_phrases_match(self):
        for phrase in [
            "What am I looking at?",
            "can you see this",
            "READ THIS for me",
            "what is this thing in front of me",
            "take a picture",
            "use the camera",
        ]:
            self.assertTrue(is_visual_query(phrase), phrase)

    def test_non_visual_phrases_do_not_match(self):
        for phrase in [
            "what's the weather tomorrow",
            "tell me a joke",
            "who wrote hamlet",
            # bare 'picture'/'photo' must NOT trigger — meta-questions about
            # photos were re-photographing the room. (Note: a meta-question
            # containing the literal phrase 'take a picture' still triggers;
            # keyword matching cannot tell it from the command.)
            "why was a photo captured just now",
            "do you always talk this much",
        ]:
            self.assertFalse(is_visual_query(phrase), phrase)

    def test_deictic_covers_photo_reference(self):
        from hermes_bridge import should_capture_photo
        # "describe this photo" flows through the deictic path now
        self.assertTrue(should_capture_photo("describe this photo", 0.0, 1000.0))
        # ...but meta/degree deictics never capture
        self.assertFalse(should_capture_photo("do you always talk this much", 0.0, 1000.0))
        self.assertFalse(should_capture_photo("keep it short like this answer", 0.0, 1000.0))
        # auxiliary verbs after this/that must not trigger
        self.assertFalse(should_capture_photo("hi this is a test", 0.0, 1000.0))
        self.assertFalse(should_capture_photo("that was great", 0.0, 1000.0))
        self.assertFalse(should_capture_photo("this should work now", 0.0, 1000.0))


class FakeWebSocket:
    """Minimal stand-in exposing recv()/send() like websockets."""

    def __init__(self, messages):
        self._messages = list(messages)
        self.sent = []

    async def recv(self):
        if not self._messages:
            await asyncio.sleep(30)  # simulate silence until timeout
        return self._messages.pop(0)

    async def send(self, message):
        self.sent.append(message)


class TestAwaitPhoto(unittest.TestCase):
    def test_photo_message_returns_decoded_bytes(self):
        jpeg = b"\xff\xd8\xff\xe0fakejpeg"
        ws = FakeWebSocket([
            b"\x00\x01binary-mic-audio-to-skip",
            '{"type":"debug","msg":"ignored"}',
            '{"type":"photo","data":"%s"}' % base64.b64encode(jpeg).decode(),
        ])
        result = asyncio.run(await_photo(ws, timeout=2.0))
        self.assertEqual(result, jpeg)

    def test_photo_error_returns_none(self):
        ws = FakeWebSocket(['{"type":"photo_error","message":"no camera"}'])
        result = asyncio.run(await_photo(ws, timeout=2.0))
        self.assertIsNone(result)

    def test_timeout_returns_none(self):
        ws = FakeWebSocket([])
        result = asyncio.run(await_photo(ws, timeout=0.2))
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()


class TestProcessQuery(unittest.TestCase):
    """process_query: text in → hermes → response + TTS out, incl. photo path."""

    def _run(self, text, ws, fake_reply="ok", fake_tts=b"\x00\x00",
             stored_session=None, bridge_tts=True):
        import tempfile as tf

        import hermes_bridge as hb

        orig_ask, orig_tts = hb.ask_hermes, hb.synthesize_speech
        orig_bridge_tts = hb.BRIDGE_TTS
        hb.BRIDGE_TTS = bridge_tts
        orig_session_file = hb.SESSION_FILE
        tmp = tf.NamedTemporaryFile(suffix=".json", delete=False)
        tmp.close()
        os_mod = __import__("os")
        os_mod.unlink(tmp.name)  # start with no stored session
        hb.SESSION_FILE = tmp.name
        if stored_session:
            hb.store_session(stored_session)
        calls = {}

        def fake_ask(query, image_path=None, resume=None):
            calls["query"] = query
            calls["image_path"] = image_path
            calls["resume"] = resume
            return fake_reply, "20260710_000000_test"

        hb.ask_hermes = fake_ask
        hb.synthesize_speech = lambda t: fake_tts
        try:
            asyncio.run(hb.process_query(ws, text))
        finally:
            hb.ask_hermes, hb.synthesize_speech = orig_ask, orig_tts
            hb.BRIDGE_TTS = orig_bridge_tts
            try:
                os_mod.unlink(tmp.name)
            except OSError:
                pass
            hb.SESSION_FILE = orig_session_file
        return calls

    def test_default_no_bridge_tts(self):
        ws = FakeWebSocket([])
        self._run("tell me a joke", ws, bridge_tts=False)
        sent = [m for m in ws.sent if isinstance(m, str)]
        self.assertTrue(any('"tts": false' in m for m in sent))
        self.assertFalse(any('"audio_start"' in m for m in sent))
        self.assertFalse(any('"audio_end"' in m for m in sent))

    def test_plain_query_answers_without_photo(self):
        ws = FakeWebSocket([])
        calls = self._run("tell me a joke", ws)
        # Fresh session → persona preamble prefixed
        self.assertTrue(calls["query"].endswith("tell me a joke"))
        self.assertIn("voice assistant", calls["query"])
        self.assertIsNone(calls["resume"])
        self.assertIsNone(calls["image_path"])
        sent_types = [m for m in ws.sent if isinstance(m, str)]
        self.assertFalse(any('"capture_photo"' in m for m in sent_types))
        self.assertTrue(any('"response"' in m for m in sent_types))
        self.assertTrue(any('"audio_end"' in m for m in sent_types))

    def test_resumed_session_skips_persona(self):
        ws = FakeWebSocket([])
        calls = self._run("tell me a joke", ws, stored_session="sid123")
        self.assertEqual(calls["query"], "tell me a joke")
        self.assertEqual(calls["resume"], "sid123")

    def test_visual_query_requests_photo_and_passes_image(self):
        jpeg = b"\xff\xd8\xff\xe0fakejpeg"
        ws = FakeWebSocket([
            '{"type":"photo","data":"%s"}' % base64.b64encode(jpeg).decode(),
        ])
        calls = self._run("what am I looking at", ws)
        self.assertTrue(any('"capture_photo"' in m
                            for m in ws.sent if isinstance(m, str)))
        self.assertIsNotNone(calls["image_path"])
        self.assertTrue(calls["query"].endswith("what am I looking at"))

    def test_visual_query_photo_error_falls_back_to_text(self):
        ws = FakeWebSocket(['{"type":"photo_error","message":"no camera"}'])
        calls = self._run("what am I looking at", ws)
        self.assertIsNone(calls["image_path"])
        self.assertIn("No photo could be captured", calls["query"])


class TestSessionStore(unittest.TestCase):
    def setUp(self):
        import hermes_bridge as hb
        import tempfile as tf
        self.hb = hb
        self.tmp = tf.NamedTemporaryFile(suffix=".json", delete=False)
        self.tmp.close()
        self.orig = hb.SESSION_FILE
        hb.SESSION_FILE = self.tmp.name

    def tearDown(self):
        import os
        self.hb.SESSION_FILE = self.orig
        try:
            os.unlink(self.tmp.name)
        except OSError:
            pass

    def test_store_and_load_same_day(self):
        self.hb.store_session("20260710_120000_abc123")
        self.assertEqual(self.hb.load_session(), "20260710_120000_abc123")

    def test_stale_session_not_loaded(self):
        import json as j
        with open(self.tmp.name, "w") as f:
            j.dump({"session_id": "old", "date": "2020-01-01"}, f)
        self.assertIsNone(self.hb.load_session())

    def test_clear(self):
        self.hb.store_session("x")
        self.hb.clear_session()
        self.assertIsNone(self.hb.load_session())


class TestSessionIdExtraction(unittest.TestCase):
    def test_extracts_from_stderr(self):
        from hermes_bridge import extract_session_id
        self.assertEqual(
            extract_session_id("\nsession_id: 20260710_162225_7c1fec\n"),
            "20260710_162225_7c1fec",
        )
        self.assertIsNone(extract_session_id("no id here"))


class TestShouldCapturePhoto(unittest.TestCase):
    def test_explicit_keyword_always_captures(self):
        from hermes_bridge import should_capture_photo
        self.assertTrue(should_capture_photo("take a picture", 100.0, 110.0))

    def test_deictic_triggers_capture(self):
        from hermes_bridge import should_capture_photo
        for phrase in ["how do I make this drink", "what's that building",
                       "is the one on the left better"]:
            self.assertTrue(should_capture_photo(phrase, 0.0, 1000.0), phrase)

    def test_deictic_suppressed_by_recent_photo(self):
        from hermes_bridge import should_capture_photo
        # photo 30s ago → deictic follow-up uses memory, no re-capture
        self.assertFalse(
            should_capture_photo("how do I make this drink", 970.0, 1000.0))

    def test_non_visual_never_captures(self):
        from hermes_bridge import should_capture_photo
        self.assertFalse(should_capture_photo("tell me a joke", 0.0, 1000.0))


# Tests for the retained legacy SDK helper (ask_claude / build_claude_user_content
# / trim_claude_history) — not on the live request path, which now goes through
# ask_provider()/build_provider_request(); kept for reference.
class TestClaudeBrain(unittest.TestCase):
    def test_user_content_text_only(self):
        from hermes_bridge import build_claude_user_content
        content = build_claude_user_content("hello there", None)
        self.assertEqual(content, [{"type": "text", "text": "hello there"}])

    def test_user_content_with_photo(self):
        from hermes_bridge import build_claude_user_content
        content = build_claude_user_content("what is this", b"\xff\xd8jpegbytes")
        self.assertEqual(content[0]["type"], "image")
        self.assertEqual(content[0]["source"]["type"], "base64")
        self.assertEqual(content[0]["source"]["media_type"], "image/jpeg")
        self.assertEqual(content[1], {"type": "text", "text": "what is this"})

    def test_history_trimmed_to_cap(self):
        from hermes_bridge import trim_claude_history
        history = [{"role": "user", "content": f"m{i}"} for i in range(100)]
        trimmed = trim_claude_history(history, max_messages=40)
        self.assertEqual(len(trimmed), 40)
        self.assertEqual(trimmed[-1]["content"], "m99")

    def test_claude_history_store_same_day(self):
        import tempfile as tf

        import hermes_bridge as hb
        tmp = tf.NamedTemporaryFile(suffix=".json", delete=False)
        tmp.close()
        os_mod = __import__("os")
        os_mod.unlink(tmp.name)
        orig = hb.CLAUDE_HISTORY_FILE
        hb.CLAUDE_HISTORY_FILE = tmp.name
        try:
            hb.store_claude_history([{"role": "user", "content": "hi"}])
            self.assertEqual(len(hb.load_claude_history()), 1)
            hb.clear_claude_history()
            self.assertEqual(hb.load_claude_history(), [])
        finally:
            try:
                os_mod.unlink(tmp.name)
            except OSError:
                pass
            hb.CLAUDE_HISTORY_FILE = orig


class ProviderRequestTests(unittest.TestCase):
    def test_anthropic_request_shape(self):
        url, headers, body = build_provider_request(
            "anthropic", "claude-opus-4-8", "https://api.anthropic.com",
            "sk-ant", "hello", None)
        self.assertEqual(url, "https://api.anthropic.com/v1/messages")
        self.assertEqual(headers["x-api-key"], "sk-ant")
        self.assertEqual(body["model"], "claude-opus-4-8")

    def test_anthropic_request_has_persona_system_prompt(self):
        from hermes_bridge import CLAUDE_SYSTEM
        _, _, body = build_provider_request(
            "anthropic", "claude-opus-4-8", "https://api.anthropic.com",
            "sk-ant", "hello", None)
        self.assertIsInstance(body["system"], str)
        self.assertTrue(body["system"])
        self.assertEqual(body["system"], CLAUDE_SYSTEM)

    def test_openai_request_shape_with_image(self):
        url, headers, body = build_provider_request(
            "openai", "gpt-4o", "https://api.openai.com", "sk-oai", "look", "QUJD")
        self.assertEqual(url, "https://api.openai.com/v1/chat/completions")
        self.assertEqual(headers["Authorization"], "Bearer sk-oai")
        content = body["messages"][-1]["content"]
        self.assertTrue(any(p.get("type") == "image_url" for p in content))

    def test_openai_request_has_persona_system_message_first(self):
        from hermes_bridge import CLAUDE_SYSTEM
        _, _, body = build_provider_request(
            "openai", "gpt-4o", "https://api.openai.com", "sk-oai", "look", None)
        self.assertEqual(body["messages"][0],
                          {"role": "system", "content": CLAUDE_SYSTEM})

    def test_gemini_request_shape(self):
        url, headers, body = build_provider_request(
            "gemini", "gemini-2.5-flash",
            "https://generativelanguage.googleapis.com", "g-key", "hi", None)
        self.assertIn(":generateContent?key=g-key", url)

    def test_gemini_request_has_persona_system_instruction(self):
        _, _, body = build_provider_request(
            "gemini", "gemini-2.5-flash",
            "https://generativelanguage.googleapis.com", "g-key", "hi", None)
        text = body["systemInstruction"]["parts"][0]["text"]
        self.assertIsInstance(text, str)
        self.assertTrue(text)

    def test_parse_replies(self):
        self.assertEqual(
            parse_provider_reply("anthropic", 200,
                b'{"content":[{"type":"text","text":"a"}]}'), "a")
        self.assertEqual(
            parse_provider_reply("openai", 200,
                b'{"choices":[{"message":{"content":"b"}}]}'), "b")
        self.assertEqual(
            parse_provider_reply("gemini", 200,
                b'{"candidates":[{"content":{"parts":[{"text":"c"}]}}]}'), "c")

    def test_claude_is_alias_for_anthropic(self):
        url, _, _ = build_provider_request(
            "claude", "claude-opus-4-8", "https://api.anthropic.com", "k", "hi", None)
        self.assertTrue(url.endswith("/v1/messages"))
