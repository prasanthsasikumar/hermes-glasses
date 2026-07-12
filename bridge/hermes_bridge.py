#!/usr/bin/env python3
"""
Hermes Glasses Bridge — WebSocket server connecting the Hermes Glasses iOS
app to a Hermes Agent. STT happens on the phone; this bridge handles text
queries, photo requests, conversation memory, and TTS.

Protocol (JSON text frames):
  app → bridge: {"type":"query","text":...}      transcribed utterance
  app → bridge: {"type":"new_session"}           forget the conversation
  app → bridge: {"type":"photo","data":<b64>}    reply to capture_photo
  app → bridge: {"type":"photo_error", ...}
  bridge → app: {"type":"welcome"} / {"type":"capture_photo"} /
                {"type":"response","text":...} / {"type":"session_reset"} /
                audio_start + binary PCM16 mono 24kHz TTS + audio_end
"""

import asyncio
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import wave
import urllib.error
import urllib.request
from urllib.parse import parse_qs, urlparse

try:
    import websockets
except ImportError:
    print("Install websockets: pip install websockets")
    sys.exit(1)

# ── Configuration ──────────────────────────────────────────────────────────
HOST = "0.0.0.0"
PORT = 8765
HERMES_BIN = os.environ.get(
    "HERMES_BIN",
    os.path.expanduser("~/.hermes/hermes-agent/venv/bin/hermes"),
)

# Shared-secret auth. When set (HERMES_BRIDGE_TOKEN env), clients must
# connect with ws://host:8765/voice?token=<value>. REQUIRED on any bridge
# reachable from the internet — hermes has tool access, so an open bridge
# is remote code execution for anyone who finds the port.
AUTH_TOKEN = os.environ.get("HERMES_BRIDGE_TOKEN", "")

# Bridge-side TTS (edge-tts/say → PCM streaming). Default OFF: the app
# speaks replies on-device with AVSpeechSynthesizer. Set HERMES_BRIDGE_TTS=1
# to fall back to server TTS for clients that can't speak locally.
BRIDGE_TTS = os.environ.get("HERMES_BRIDGE_TTS", "") == "1"

# Which brain answers queries:
#   "hermes" (default) — spawn the hermes CLI per query (agent with tools;
#                        slower: pays agent boot every question)
#   "claude"           — call the Claude API directly (fast conversational
#                        answers + vision; needs ANTHROPIC_API_KEY)
#   "anthropic" / "openai" / "gemini" — call the provider's HTTP API
#                        directly (fast conversational answers + vision;
#                        needs the matching *_API_KEY). "claude" is kept as
#                        an alias for "anthropic" (back-compat).
BRAIN = os.environ.get("HERMES_BRIDGE_BRAIN", "hermes")
CLAUDE_MODEL = os.environ.get("HERMES_BRIDGE_MODEL", "claude-opus-4-8")

# ── Provider brains (direct API, BRAIN="anthropic"|"openai"|"gemini") ──────
BASE_URLS = {
    "anthropic": "https://api.anthropic.com",
    "openai": "https://api.openai.com",
    "gemini": "https://generativelanguage.googleapis.com",
}
PROVIDER_API_KEY_ENV = {
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
    "gemini": "GEMINI_API_KEY",
}


def _canon_brain(brain):
    return "anthropic" if brain == "claude" else brain


def build_provider_request(brain, model, base_url, api_key, prompt, image_b64):
    """Return (url, headers, body_dict) for a one-shot chat+vision request."""
    brain = _canon_brain(brain)
    headers = {"Content-Type": "application/json"}
    if brain == "anthropic":
        content = []
        if image_b64:
            content.append({"type": "image", "source": {
                "type": "base64", "media_type": "image/jpeg", "data": image_b64}})
        content.append({"type": "text", "text": prompt})
        headers["x-api-key"] = api_key
        headers["anthropic-version"] = "2023-06-01"
        body = {"model": model, "max_tokens": 1024,
                "messages": [{"role": "user", "content": content}]}
        return base_url + "/v1/messages", headers, body
    if brain == "openai":
        if image_b64:
            content = [{"type": "text", "text": prompt},
                       {"type": "image_url", "image_url": {
                           "url": "data:image/jpeg;base64," + image_b64}}]
        else:
            content = prompt
        if api_key:
            headers["Authorization"] = "Bearer " + api_key
        body = {"model": model, "max_tokens": 1024,
                "messages": [{"role": "user", "content": content}]}
        return base_url + "/v1/chat/completions", headers, body
    if brain == "gemini":
        parts = []
        if image_b64:
            parts.append({"inline_data": {"mime_type": "image/jpeg", "data": image_b64}})
        parts.append({"text": prompt})
        body = {"contents": [{"role": "user", "parts": parts}]}
        url = "%s/v1beta/models/%s:generateContent?key=%s" % (base_url, model, api_key)
        return url, headers, body
    raise ValueError("unknown brain: %s" % brain)


def parse_provider_reply(brain, status, body_bytes):
    brain = _canon_brain(brain)
    data = json.loads(body_bytes.decode("utf-8"))
    if status != 200:
        raise RuntimeError(data.get("error", {}).get("message", "API error %s" % status))
    if brain == "anthropic":
        return next(b["text"] for b in data["content"] if b.get("type") == "text")
    if brain == "openai":
        return data["choices"][0]["message"]["content"]
    if brain == "gemini":
        return data["candidates"][0]["content"]["parts"][0]["text"]
    raise ValueError("unknown brain: %s" % brain)


def ask_provider(brain: str, text: str, photo: bytes | None = None) -> str:
    """Answer via a direct provider HTTP API (anthropic/openai/gemini).

    Stdlib-only (urllib), stateless single-turn request built with
    build_provider_request() and parsed with parse_provider_reply(). Unlike
    the legacy SDK-based ask_claude() below, this path carries no cross-turn
    history — each query is answered independently.
    """
    brain = _canon_brain(brain)
    base_url = os.environ.get("HERMES_BRIDGE_BASE_URL", BASE_URLS[brain])
    key_env = PROVIDER_API_KEY_ENV[brain]
    api_key = os.environ.get(key_env, "")
    if not api_key:
        return f"The {brain} brain needs an API key. Set {key_env} for the bridge."

    image_b64 = base64.b64encode(photo).decode() if photo else None
    url, headers, body = build_provider_request(
        brain, CLAUDE_MODEL, base_url, api_key, text, image_b64)

    request = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as resp:
            status, body_bytes = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        status, body_bytes = e.code, e.read()
    except urllib.error.URLError as e:
        print(f"[{brain}] Connection error: {e}")
        return f"Sorry, I couldn't reach the {brain} API."

    try:
        return parse_provider_reply(brain, status, body_bytes)
    except Exception as e:
        print(f"[{brain}] API error ({status}): {e}")
        return f"Sorry, the {brain} API returned an error."


# Utterances containing any of these ask about something the user sees;
# the bridge then requests a photo from the glasses. Phrases, not bare
# words: "picture" alone would fire on "why did you take a picture?"
VISUAL_KEYWORDS = [
    "look at", "looking at", "see this", "what am i seeing",
    "what is this", "what's this", "read this", "in front of me",
    "take a picture", "take a photo", "snap a photo", "use the camera",
    "through the camera",
]


def is_visual_query(text: str) -> bool:
    lowered = text.lower()
    return any(keyword in lowered for keyword in VISUAL_KEYWORDS)


# "this drink", "that building", "the one on the left" — references to
# something the user is (probably) looking at
DEICTIC_RE = None  # compiled below, after re is imported


# "this morning", "that question" — deictic in grammar but not about
# anything visible. Nouns here never trigger a photo.
DEICTIC_STOP_NOUNS = {
    "morning", "afternoon", "evening", "night", "time", "day", "week",
    "month", "year", "moment", "question", "answer", "idea", "point",
    "case", "way", "reason", "sense", "stuff", "conversation", "chat",
    "session", "app", "voice", "sound", "response", "reply", "much",
    "long", "short", "many", "far", "fast", "slow", "bit", "lot", "kind",
    "sort", "type",
    # Auxiliary/copular verbs: "this is a test", "that was fun" are not
    # about anything visible
    "is", "was", "are", "were", "be", "being", "been", "isn", "wasn",
    "will", "would", "can", "could", "should", "might", "may", "must",
    "does", "did", "done", "has", "had", "have", "gets", "got", "goes",
    "went", "seems", "means", "works", "sounds", "feels", "happened",
}


def should_capture_photo(text: str, last_photo_at: float, now: float) -> bool:
    """Decide whether a query needs a fresh photo.

    Explicit visual keywords always capture. Deictic references ("this X")
    capture only for plausibly-visible nouns, and only when no photo was
    taken recently — within the window, conversation memory already knows
    what the user is looking at.
    """
    if is_visual_query(text):
        return True
    if DEICTIC_RE:
        for match in DEICTIC_RE.finditer(text):
            noun = (match.group(2) or "").lower()
            if match.group(0).lower() == "the one" or (
                noun and noun not in DEICTIC_STOP_NOUNS
            ):
                return (now - last_photo_at) > PHOTO_MEMORY_WINDOW_S
    return False


PHOTO_MEMORY_WINDOW_S = 120.0

# ── Conversation memory (same-day hermes session) ──────────────────────────
SESSION_FILE = os.path.expanduser("~/.hermes_glasses_bridge_session.json")

VOICE_PERSONA = (
    "(You are a voice assistant running on smart glasses. Your answers are "
    "spoken aloud - keep them to 1-3 conversational sentences unless the "
    "user asks for detail. The user may reference things they see; photos "
    "may be attached to queries. Do not mention codebases or files unless "
    "asked.) "
)


def _today() -> str:
    import datetime
    return datetime.date.today().isoformat()


def load_session() -> str | None:
    """Stored hermes session ID, if it is from today."""
    try:
        with open(SESSION_FILE) as f:
            data = json.load(f)
        if data.get("date") == _today() and data.get("session_id"):
            return data["session_id"]
    except (OSError, ValueError):
        pass
    return None


def store_session(session_id: str):
    try:
        with open(SESSION_FILE, "w") as f:
            json.dump({"session_id": session_id, "date": _today()}, f)
    except OSError as e:
        print(f"[Bridge] Could not persist session: {e}")


def clear_session():
    try:
        os.unlink(SESSION_FILE)
    except OSError:
        pass


def extract_session_id(stderr_text: str) -> str | None:
    import re as _re
    match = _re.search(r"session_id:\s*(\S+)", stderr_text)
    return match.group(1) if match else None


# ── Legacy Claude SDK brain (unused by the request path below, which now
# routes anthropic/openai/gemini through ask_provider(); kept for its
# tested same-day history helpers) ──────────────────────────────────────────
CLAUDE_HISTORY_FILE = os.path.expanduser("~/.hermes_glasses_claude_history.json")
CLAUDE_MAX_HISTORY = 40  # messages kept (20 turns)

CLAUDE_SYSTEM = (
    "You are a voice assistant running on the user's smart glasses. Your "
    "answers are spoken aloud: keep them to 1-3 conversational sentences "
    "unless the user asks for detail. The user may reference things they "
    "see; photos from the glasses camera may be attached to queries. Be "
    "direct, natural, and helpful."
)


def load_claude_history() -> list:
    """Same-day conversation history for the Claude brain."""
    try:
        with open(CLAUDE_HISTORY_FILE) as f:
            data = json.load(f)
        if data.get("date") == _today():
            return data.get("messages", [])
    except (OSError, ValueError):
        pass
    return []


def store_claude_history(messages: list):
    try:
        with open(CLAUDE_HISTORY_FILE, "w") as f:
            json.dump({"date": _today(), "messages": messages}, f)
    except OSError as e:
        print(f"[Bridge] Could not persist Claude history: {e}")


def clear_claude_history():
    try:
        os.unlink(CLAUDE_HISTORY_FILE)
    except OSError:
        pass


def trim_claude_history(messages: list, max_messages: int = CLAUDE_MAX_HISTORY) -> list:
    return messages[-max_messages:] if len(messages) > max_messages else messages


def build_claude_user_content(text: str, photo: bytes | None) -> list:
    """User content blocks: optional glasses photo first, then the words."""
    content = []
    if photo:
        content.append({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": "image/jpeg",
                "data": base64.b64encode(photo).decode(),
            },
        })
    content.append({"type": "text", "text": text})
    return content


def ask_claude(text: str, photo: bytes | None = None) -> str | None:
    """Answer via the Claude API with same-day conversation memory.

    Fast path: no process spawn, no agent boot — typically 2-4s for a
    spoken-length reply. Photos go in as native image blocks.
    """
    try:
        import anthropic
    except ImportError:
        return "The Claude brain needs the anthropic package: pip install anthropic"

    history = load_claude_history()
    user_message = {"role": "user", "content": build_claude_user_content(text, photo)}

    try:
        client = anthropic.Anthropic()
        response = client.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=1024,
            # Stable prefix cached; history rides behind it
            system=[{
                "type": "text",
                "text": CLAUDE_SYSTEM,
                "cache_control": {"type": "ephemeral"},
            }],
            messages=trim_claude_history(history + [user_message]),
        )
        reply = next(
            (b.text for b in response.content if b.type == "text"), None
        )
        if reply:
            # Persist text-only user turn (images would bloat the file and
            # re-bill on every later request)
            history.append({"role": "user", "content": text})
            history.append({"role": "assistant", "content": reply})
            store_claude_history(trim_claude_history(history))
        return reply
    except anthropic.AuthenticationError:
        return ("The Claude API key is missing or invalid. Set "
                "ANTHROPIC_API_KEY for the bridge.")
    except anthropic.APIStatusError as e:
        print(f"[Claude] API error {e.status_code}: {e.message}")
        return "Sorry, the Claude API returned an error."
    except anthropic.APIConnectionError:
        return "Sorry, I couldn't reach the Claude API."
    except Exception as e:
        print(f"[Claude] Error: {e}")
        return f"Error: {e}"

# ── Hermes Agent ────────────────────────────────────────────────────────────

import re

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
BOX_CHARS = set("╭╮╰╯│─═╞╡┌┐└┘┤├")

# Deictic references — compiled here because `re` is imported at this point
DEICTIC_RE = re.compile(r"\b(this|that|these|those)\s+([a-z]+)|\bthe one\b",
                        re.IGNORECASE)


def extract_hermes_reply(raw: str) -> str | None:
    """Pull just the assistant's reply out of the hermes CLI output.

    The CLI prints: a Query echo, spinner lines, then the reply inside a
    box whose top border contains 'Hermes', then a session footer.
    """
    text = ANSI_RE.sub("", raw).replace("\r", "\n")
    lines = text.split("\n")

    reply_lines = []
    in_box = False
    for line in lines:
        stripped = line.strip()
        if not in_box:
            if "Hermes" in stripped and BOX_CHARS & set(stripped):
                in_box = True
            continue
        # Bottom border (or any pure box-drawing line) ends the reply
        if stripped and set(stripped) <= (BOX_CHARS | set(" ")):
            break
        cleaned = stripped.strip("│").strip()
        reply_lines.append(cleaned)

    reply = "\n".join(reply_lines).strip()
    return reply or None


def ask_hermes(
    text: str,
    image_path: str | None = None,
    resume: str | None = None,
) -> tuple[str | None, str | None]:
    """Send text (and optionally an image) to Hermes Agent.

    Returns (reply, session_id). session_id enables conversation memory
    via --resume on the next query; either value may be None.
    """
    cmd = [HERMES_BIN, "chat", "-q", text, "-Q", "--cli"]
    if image_path:
        cmd += ["--image", image_path]
    if resume:
        cmd += ["--resume", resume]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120 if image_path else 60,
            env={**os.environ, "HERMES_NO_COLOR": "1"},
        )
        session_id = extract_session_id(result.stderr)
        output = result.stdout.strip()
        if output:
            # -Q should print only the reply; if box UI sneaks in, unwrap it
            if BOX_CHARS & set(output):
                reply = extract_hermes_reply(output)
                if reply:
                    return reply, session_id
            return output, session_id
        if result.stderr.strip():
            # No reply on stdout — return the error text sans session line
            err = "\n".join(
                line for line in result.stderr.strip().splitlines()
                if not line.startswith("session_id:")
            ).strip()
            return (err or None), session_id
        return None, session_id
    except subprocess.TimeoutExpired:
        return "Sorry, Hermes took too long to respond.", None
    except Exception as e:
        print(f"[Hermes] Error: {e}")
        return f"Error: {e}", None


# ── Text-to-Speech ─────────────────────────────────────────────────────────

def synthesize_speech(text: str) -> bytes | None:
    """Convert text to speech. Always returns raw PCM16 mono 24kHz —
    the only format the app can play."""
    # Try Edge TTS first (better quality)
    try:
        import edge_tts

        mp3_tmp = tempfile.NamedTemporaryFile(suffix=".mp3", delete=False)
        mp3_tmp.close()
        wav_tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        wav_tmp.close()

        async def _synth():
            communicate = edge_tts.Communicate(text, "en-US-AriaNeural")
            await communicate.save(mp3_tmp.name)

        asyncio.run(_synth())

        # Decode MP3 → PCM16 mono 24kHz WAV. afconvert on macOS,
        # ffmpeg elsewhere (Linux).
        if shutil.which("afconvert"):
            cmd = ["afconvert", "-f", "WAVE", "-d", "LEI16@24000", "-c", "1",
                   mp3_tmp.name, wav_tmp.name]
        elif shutil.which("ffmpeg"):
            cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", mp3_tmp.name,
                   "-ar", "24000", "-ac", "1", "-sample_fmt", "s16",
                   wav_tmp.name]
        else:
            cmd = None
            print("[TTS] Neither afconvert nor ffmpeg found")

        if cmd:
            result = subprocess.run(cmd, capture_output=True, timeout=30)
            os.unlink(mp3_tmp.name)
            if result.returncode == 0:
                with wave.open(wav_tmp.name, "rb") as wf:
                    data = wf.readframes(wf.getnframes())
                os.unlink(wav_tmp.name)
                return data
            os.unlink(wav_tmp.name)
            print(f"[TTS] decode failed: {result.stderr.decode()[:200]}")
    except ImportError:
        pass
    except Exception as e:
        print(f"[TTS] Edge TTS error: {e}")

    # Fallback: macOS say command, directly as PCM16 24kHz WAV
    if not shutil.which("say"):
        print("[TTS] No 'say' fallback available on this platform")
        return None
    try:
        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        tmp.close()
        subprocess.run(
            ["say", "-o", tmp.name,
             "--file-format=WAVE", "--data-format=LEI16@24000", text],
            capture_output=True, timeout=30,
        )
        with wave.open(tmp.name, "rb") as wf:
            data = wf.readframes(wf.getnframes())
        os.unlink(tmp.name)
        return data
    except Exception as e:
        print(f"[TTS] Error: {e}")
        return None


# ── WebSocket Handler ──────────────────────────────────────────────────────

async def await_photo(websocket, timeout: float = 25.0) -> bytes | None:
    """Wait for the app to answer a capture_photo request.

    Discards mic-audio (binary) frames that arrive meanwhile. Returns the
    decoded JPEG bytes, or None on photo_error or timeout.
    """
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print("[Bridge] Photo wait timed out")
            return None
        try:
            message = await asyncio.wait_for(websocket.recv(), timeout=remaining)
        except asyncio.TimeoutError:
            print("[Bridge] Photo wait timed out")
            return None
        if isinstance(message, bytes):
            continue  # stray binary frame while waiting — drop it
        data = json.loads(message)
        msg_type = data.get("type")
        if msg_type == "photo":
            try:
                return base64.b64decode(data.get("data", ""))
            except Exception as e:
                print(f"[Bridge] Bad photo payload: {e}")
                return None
        if msg_type == "photo_error":
            print(f"[Bridge] Photo error from app: {data.get('message')}")
            return None
        if msg_type == "debug":
            print(f"[App] {data.get('msg')}")
        # any other message type: keep waiting


async def process_query(websocket, text: str, conn_state: dict | None = None,
                        want_tts: bool | None = None):
    """Answer a text query: photo capture if visual, Hermes, TTS reply.

    The app transcribes on-device and sends {"type":"query"} text.
    conn_state carries per-connection context: {"last_photo_at": float}.
    want_tts: app's per-query choice of bridge TTS; None falls back to the
    HERMES_BRIDGE_TTS env default.
    """
    bridge_tts = BRIDGE_TTS if want_tts is None else bool(want_tts)
    if conn_state is None:
        conn_state = {"last_photo_at": 0.0}

    # ── Capture a photo for visual/deictic queries ──
    photo = None
    query_text = text
    if should_capture_photo(text, conn_state.get("last_photo_at", 0.0),
                            time.monotonic()):
        print("[Bridge] Visual query — requesting photo from glasses")
        await websocket.send(json.dumps({"type": "capture_photo"}))
        photo = await await_photo(websocket)
        if photo:
            conn_state["last_photo_at"] = time.monotonic()
            print(f"[Bridge] Photo received: {len(photo)} bytes")
        else:
            print("[Bridge] No photo — answering text-only")
            query_text = ("(No photo could be captured from the glasses.) "
                          + text)

    canon_brain = _canon_brain(BRAIN)
    if canon_brain in ("anthropic", "openai", "gemini"):
        # ── Ask the provider API directly (fast path) ──
        print(f"[Bridge] Asking {canon_brain} ({CLAUDE_MODEL})...")
        response = await asyncio.to_thread(ask_provider, canon_brain, query_text, photo)
    else:
        # ── Ask Hermes (with same-day conversation memory) ──
        image_path = None
        if photo:
            img_tmp = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
            img_tmp.write(photo)
            img_tmp.close()
            image_path = img_tmp.name
        resume = load_session()
        if not resume:
            # Fresh conversation: teach Hermes it is a glasses voice assistant
            query_text = VOICE_PERSONA + query_text
        print(f"[Bridge] Asking Hermes... (session: {resume or 'new'})")
        try:
            response, session_id = await asyncio.to_thread(
                ask_hermes, query_text, image_path, resume
            )
            if resume and not response:
                # Stored session may have been pruned — retry fresh once
                print("[Bridge] Resume failed — retrying with a fresh session")
                clear_session()
                response, session_id = await asyncio.to_thread(
                    ask_hermes, VOICE_PERSONA + text, image_path, None
                )
            if session_id:
                store_session(session_id)
        finally:
            if image_path:
                os.unlink(image_path)
    response_text = response or "I'm not sure what to say."

    print(f"[Bridge] Hermes: {response_text[:100]}...")

    # "tts": whether PCM audio follows. False → the app speaks the text
    # itself with on-device synthesis.
    await websocket.send(json.dumps({
        "type": "response",
        "text": response_text,
        "tts": bridge_tts,
    }))

    if bridge_tts:
        # ── Server-side TTS (legacy fallback, HERMES_BRIDGE_TTS=1) ──
        print("[Bridge] Generating speech...")
        await websocket.send(json.dumps({"type": "audio_start"}))

        audio_data = await asyncio.to_thread(synthesize_speech, response_text)
        if audio_data:
            # Send in chunks to avoid frame size limits
            chunk_size = 16384
            for i in range(0, len(audio_data), chunk_size):
                await websocket.send(audio_data[i:i+chunk_size])
                await asyncio.sleep(0.01)

        await websocket.send(json.dumps({"type": "audio_end"}))
    print("[Bridge] Response complete.")


def is_authorized(websocket) -> bool:
    """When AUTH_TOKEN is set, require ?token=<AUTH_TOKEN> in the WS path."""
    if not AUTH_TOKEN:
        return True
    try:
        path = websocket.request.path if websocket.request else ""
        query = parse_qs(urlparse(path).query)
        return query.get("token", [""])[0] == AUTH_TOKEN
    except Exception:
        return False


async def handle_connection(websocket):
    """Handle a single glasses connection."""
    if not is_authorized(websocket):
        print(f"[Bridge] REJECTED unauthorized connection from "
              f"{websocket.remote_address}")
        await websocket.close(code=4401, reason="unauthorized")
        return

    print(f"[Bridge] Glasses connected from {websocket.remote_address}")

    # Send welcome to confirm connection
    await websocket.send(json.dumps({"type": "welcome"}))
    # Per-connection context for photo-recency suppression
    conn_state = {"last_photo_at": 0.0}

    try:
        async for message in websocket:
            if isinstance(message, bytes):
                # Binary frames were the legacy mic-audio path; the app
                # transcribes on-device now. Ignore them.
                continue

            data = json.loads(message)
            msg_type = data.get("type")

            if msg_type == "query":
                # App transcribed on-device and sends text directly
                text = (data.get("text") or "").strip()
                if text:
                    print(f"[Bridge] Query: {text}")
                    await process_query(websocket, text, conn_state,
                                        data.get("tts"))
                else:
                    await websocket.send(json.dumps({
                        "type": "error",
                        "message": "Empty query."
                    }))

            elif msg_type == "new_session":
                # Forget the conversation; next query starts fresh
                clear_session()
                clear_claude_history()
                conn_state["last_photo_at"] = 0.0
                print("[Bridge] Conversation reset by app")
                await websocket.send(json.dumps({"type": "session_reset"}))

            elif msg_type == "debug":
                print(f"[App] {data.get('msg')}")

            elif msg_type == "ping":
                await websocket.send(json.dumps({"type": "pong"}))

    except websockets.exceptions.ConnectionClosed:
        print("[Bridge] Glasses disconnected")
    except Exception as e:
        print(f"[Bridge] Error: {e}")
    finally:
        print("[Bridge] Connection closed")


def local_ip() -> str:
    """Best-effort LAN IP for the connection hint."""
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "<your-mac-ip>"


async def main():
    print(f"""
╔══════════════════════════════════════════════════════════╗
║              Hermes Glasses Bridge Server                ║
║                                                          ║
║  Listening on ws://{HOST}:{PORT}/voice                       ║
║  STT: on the phone — the app sends text queries          ║
║  Brain: {BRAIN} {f"({CLAUDE_MODEL})" if _canon_brain(BRAIN) in ("anthropic", "openai", "gemini") else "(CLI agent)":<30}  ║
║                                                          ║
║  Connect your glasses app to:                            ║
║  ws://{local_ip()}:{PORT}/voice                             ║
╚══════════════════════════════════════════════════════════╝
""")
    # Glasses photos arrive as a single large base64-encoded JSON text frame
    # (a 1-3 MB raw JPEG becomes an even bigger base64 string), so raise
    # max_size well above the websockets default of 1 MiB to avoid a 1009
    # close before the frame is fully received.
    async with websockets.serve(handle_connection, HOST, PORT, max_size=16 * 1024 * 1024):
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[Bridge] Shutting down.")
