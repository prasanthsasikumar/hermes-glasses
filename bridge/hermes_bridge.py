#!/usr/bin/env python3
"""
Hermes Glasses Bridge — WebSocket server that bridges Meta Ray-Ban glasses
audio to Hermes Agent for voice conversation.

Protocol:
  - Receives binary PCM16 16kHz mono audio chunks
  - Receives {"type":"end_of_audio"} when user stops speaking
  - Transcribes audio via speech_recognition (Google STT or local whisper)
  - Sends transcript to Hermes Agent via CLI
  - Returns TTS audio response
"""

import array
import asyncio
import base64
import json
import math
import os
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

try:
    import websockets
except ImportError:
    print("Install websockets: pip install websockets")
    sys.exit(1)

# ── Configuration ──────────────────────────────────────────────────────────
HOST = "0.0.0.0"
PORT = 8765
HERMES_BIN = os.path.expanduser("~/.hermes/hermes-agent/venv/bin/hermes")

# STT backend: "google" (free, needs internet) or "whisper" (local)
STT_BACKEND = "google"

# Utterances containing any of these ask about something the user sees;
# the bridge then requests a photo from the glasses.
VISUAL_KEYWORDS = [
    "look", "looking at", "see this", "seeing", "what is this",
    "what's this", "read this", "in front of me", "picture", "photo",
    "camera",
]


def is_visual_query(text: str) -> bool:
    lowered = text.lower()
    return any(keyword in lowered for keyword in VISUAL_KEYWORDS)

# ── Server-side VAD (utterance detection) ──────────────────────────────────
# The app streams audio continuously; the bridge decides when an utterance
# has ended. Tune SPEECH_RMS using the [VAD] level logs.
SPEECH_RMS = 0.006   # normalized RMS above this counts as speech
SILENCE_MS = 1000    # this much silence after speech ends the utterance
PREROLL_MS = 500     # audio kept from before speech starts


def chunk_rms(pcm: bytes) -> float:
    """Normalized RMS (0..1) of a PCM16 chunk."""
    n = len(pcm) // 2 * 2
    if n == 0:
        return 0.0
    samples = array.array("h", pcm[:n])
    return math.sqrt(sum(s * s for s in samples) / len(samples)) / 32768.0


# ── Speech-to-Text ─────────────────────────────────────────────────────────

def transcribe_google(audio_path: str) -> str | None:
    """Transcribe using Google Speech Recognition (free tier)."""
    try:
        import speech_recognition as sr
    except ImportError:
        return None

    r = sr.Recognizer()
    with sr.AudioFile(audio_path) as source:
        audio = r.record(source)
    try:
        return r.recognize_google(audio)
    except sr.UnknownValueError:
        return None
    except sr.RequestError as e:
        print(f"[STT] Google error: {e}")
        return None


def transcribe_whisper(audio_path: str) -> str | None:
    """Transcribe using local Whisper."""
    try:
        import whisper
    except ImportError:
        return None

    model = whisper.load_model("tiny")  # tiny/base/small/medium/large
    result = model.transcribe(audio_path, fp16=False)
    text = result["text"].strip()
    return text if text else None


# ── Hermes Agent ────────────────────────────────────────────────────────────

import re

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
BOX_CHARS = set("╭╮╰╯│─═╞╡┌┐└┘┤├")


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


def ask_hermes(text: str, image_path: str | None = None) -> str | None:
    """Send text (and optionally an image) to Hermes Agent."""
    cmd = [HERMES_BIN, "chat", "-q", text, "-Q", "--cli"]
    if image_path:
        cmd += ["--image", image_path]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120 if image_path else 60,
            env={**os.environ, "HERMES_NO_COLOR": "1"},
        )
        output = result.stdout.strip()
        if output:
            # -Q should print only the reply; if box UI sneaks in, unwrap it
            if BOX_CHARS & set(output):
                reply = extract_hermes_reply(output)
                if reply:
                    return reply
            return output
        if result.stderr.strip():
            return result.stderr.strip()
        return None
    except subprocess.TimeoutExpired:
        return "Sorry, Hermes took too long to respond."
    except Exception as e:
        print(f"[Hermes] Error: {e}")
        return f"Error: {e}"


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

        # Decode MP3 → raw PCM16 mono 24kHz via afconvert (macOS built-in)
        result = subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", "LEI16@24000", "-c", "1",
             mp3_tmp.name, wav_tmp.name],
            capture_output=True, timeout=30,
        )
        os.unlink(mp3_tmp.name)
        if result.returncode == 0:
            with wave.open(wav_tmp.name, "rb") as wf:
                data = wf.readframes(wf.getnframes())
            os.unlink(wav_tmp.name)
            return data
        os.unlink(wav_tmp.name)
        print(f"[TTS] afconvert failed: {result.stderr.decode()[:200]}")
    except ImportError:
        pass
    except Exception as e:
        print(f"[TTS] Edge TTS error: {e}")

    # Fallback: macOS say command, directly as PCM16 24kHz WAV
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


# ── PCM16 to WAV ───────────────────────────────────────────────────────────

def pcm_to_wav(pcm_data: bytes, sample_rate: int = 16000) -> str:
    """Convert raw PCM16 audio to a temporary WAV file. Returns path."""
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    with wave.open(tmp.name, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)  # 16-bit
        wf.setframerate(sample_rate)
        wf.writeframes(pcm_data)
    return tmp.name


# ── WebSocket Handler ──────────────────────────────────────────────────────

async def await_photo(websocket, timeout: float = 10.0) -> bytes | None:
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
            continue  # mic audio while waiting — drop it
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


async def process_utterance(websocket, pcm: bytes, sample_rate: int):
    """Transcribe an utterance, ask Hermes, and stream the TTS reply."""
    wav_path = pcm_to_wav(pcm, sample_rate)

    # ── Step 1: Transcribe ── (in a thread so the socket stays alive)
    print("[Bridge] Transcribing...")
    if STT_BACKEND == "whisper":
        transcript = await asyncio.to_thread(transcribe_whisper, wav_path)
    else:
        transcript = await asyncio.to_thread(transcribe_google, wav_path)

    os.unlink(wav_path)

    if not transcript:
        print("[Bridge] STT returned nothing")
        await websocket.send(json.dumps({
            "type": "error",
            "message": "Couldn't understand. Please try again."
        }))
        return

    print(f"[Bridge] Transcript: {transcript}")

    # Send transcript to glasses app
    await websocket.send(json.dumps({
        "type": "transcript",
        "text": transcript,
    }))

    # ── Step 1.5: capture a photo for visual queries ──
    image_path = None
    query_text = transcript
    if is_visual_query(transcript):
        print("[Bridge] Visual query — requesting photo from glasses")
        await websocket.send(json.dumps({"type": "capture_photo"}))
        photo = await await_photo(websocket)
        if photo:
            img_tmp = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
            img_tmp.write(photo)
            img_tmp.close()
            image_path = img_tmp.name
            print(f"[Bridge] Photo received: {len(photo)} bytes")
        else:
            print("[Bridge] No photo — answering text-only")
            query_text = ("(No photo could be captured from the glasses.) "
                          + transcript)

    # ── Step 2: Ask Hermes ──
    print("[Bridge] Asking Hermes...")
    response = await asyncio.to_thread(ask_hermes, query_text, image_path)
    if image_path:
        os.unlink(image_path)
    response_text = response or "I'm not sure what to say."

    print(f"[Bridge] Hermes: {response_text[:100]}...")

    await websocket.send(json.dumps({
        "type": "response",
        "text": response_text,
    }))

    # ── Step 3: TTS ──
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


async def handle_connection(websocket):
    """Handle a single glasses connection."""
    print(f"[Bridge] Glasses connected from {websocket.remote_address}")

    # Send welcome to confirm connection
    await websocket.send(json.dumps({"type": "welcome"}))
    audio_buffer = bytearray()
    debug_dump = bytearray()  # everything received, saved to WAV on close
    sample_rate = 16000
    bytes_per_ms = sample_rate * 2 / 1000.0

    in_speech = False
    silence_ms = 0.0
    last_level_log = 0.0
    # Audio that arrives while we were processing (incl. TTS echo) is stale;
    # discard it until this wall-clock time.
    drop_until = 0.0

    try:
        async for message in websocket:
            if isinstance(message, bytes):
                now = time.monotonic()
                if now < drop_until:
                    continue

                audio_buffer.extend(message)
                if len(debug_dump) < sample_rate * 2 * 120:  # cap at 2 min
                    debug_dump.extend(message)
                rms = chunk_rms(message)
                chunk_ms = len(message) / bytes_per_ms

                if now - last_level_log > 1.0:
                    state = "SPEECH" if in_speech else "quiet"
                    print(f"[VAD] level={rms:.4f} threshold={SPEECH_RMS} "
                          f"({state}, buffer={len(audio_buffer)}b)")
                    last_level_log = now

                if rms > SPEECH_RMS:
                    if not in_speech:
                        in_speech = True
                        print(f"[VAD] Speech started (rms={rms:.4f})")
                    silence_ms = 0.0
                elif in_speech:
                    silence_ms += chunk_ms
                    if silence_ms >= SILENCE_MS:
                        print(f"[VAD] Utterance ended "
                              f"({len(audio_buffer)} bytes)")
                        pcm = bytes(audio_buffer)
                        audio_buffer.clear()
                        in_speech = False
                        silence_ms = 0.0
                        await process_utterance(websocket, pcm, sample_rate)
                        drop_until = time.monotonic() + 0.5
                else:
                    # No speech yet — keep only a short pre-roll so silence
                    # doesn't accumulate forever
                    max_preroll = int(PREROLL_MS * bytes_per_ms)
                    if len(audio_buffer) > max_preroll:
                        del audio_buffer[:len(audio_buffer) - max_preroll]

            elif isinstance(message, str):
                data = json.loads(message)
                msg_type = data.get("type")

                if msg_type == "end_of_audio":
                    # Manual end-of-utterance from the app (backup path)
                    if len(audio_buffer) < 1600:  # < 100ms — too short
                        await websocket.send(json.dumps({
                            "type": "error",
                            "message": "Audio too short. Please speak again."
                        }))
                        audio_buffer.clear()
                        continue

                    pcm = bytes(audio_buffer)
                    audio_buffer.clear()
                    in_speech = False
                    silence_ms = 0.0
                    await process_utterance(websocket, pcm, sample_rate)
                    drop_until = time.monotonic() + 0.5

                elif msg_type == "debug":
                    print(f"[App] {data.get('msg')}")

                elif msg_type == "ping":
                    await websocket.send(json.dumps({"type": "pong"}))

    except websockets.exceptions.ConnectionClosed:
        print("[Bridge] Glasses disconnected")
    except Exception as e:
        print(f"[Bridge] Error: {e}")
    finally:
        if debug_dump:
            with wave.open("/tmp/hermes_last_audio.wav", "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(sample_rate)
                wf.writeframes(bytes(debug_dump))
            print(f"[Bridge] Session audio saved: /tmp/hermes_last_audio.wav "
                  f"({len(debug_dump)} bytes)")
        print("[Bridge] Connection closed")


async def main():
    print(f"""
╔══════════════════════════════════════════════╗
║       Hermes Glasses Bridge Server           ║
║                                              ║
║  Listening on ws://{HOST}:{PORT}/voice           ║
║  STT backend: {STT_BACKEND}                         ║
║                                              ║
║  Connect your glasses app to:                ║
║  ws://192.168.1.16:{PORT}/voice                 ║
╚══════════════════════════════════════════════╝
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
