# Hermes Glasses

Talk to your own AI agent through Meta Ray-Ban smart glasses — hands-free voice
conversations with live on-device transcription, and computer vision through the
glasses camera ("what am I looking at?").

Part of the **Sidekick** project.

> 📸 Screenshots coming soon.

## What it does

- 🎙️ **Live transcription** — your words appear on screen as you speak, using
  Apple's on-device speech recognition (no audio leaves the phone for STT)
- 🤖 **Ask anything** — finished utterances are sent to a Hermes Agent running
  on your Mac, and the answer is spoken back through text-to-speech
- 👓 **Vision through the glasses** — say "what am I looking at?" and the app
  captures a photo from the Ray-Ban camera and Hermes answers about the image
- 🧪 **Built-in test panel** — Bridge / Photo / Query / Visual buttons verify
  each subsystem independently, with a live mic level meter

## Architecture

```
┌─────────────┐   Bluetooth    ┌──────────────┐    WebSocket     ┌──────────────────┐
│  Ray-Ban    │ ─────────────▶ │  iPhone app  │ ───────────────▶ │  Mac bridge      │
│  glasses    │  (DAT SDK:     │  (SwiftUI)   │  text queries +  │  (Python)        │
│             │   camera)      │              │  base64 photos   │                  │
└─────────────┘                │  on-device   │ ◀─────────────── │  hermes chat CLI │
                               │  live STT    │  responses + TTS │  + edge-tts      │
                               └──────────────┘    (PCM 24 kHz)  └──────────────────┘
```

- **iOS app** (`HermesGlasses/`) — SwiftUI app using the
  [Meta Wearables Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios)
  0.8.0 for glasses registration, sessions, and camera capture, plus
  `SFSpeechRecognizer` for live on-device transcription.
- **Bridge** (`bridge/hermes_bridge.py`) — a small Python WebSocket server on
  the Mac. Receives text queries, detects visual questions by keyword, requests
  a photo from the app when needed, invokes `hermes chat -q ... [--image ...]`,
  and streams back the reply text plus TTS audio (Edge TTS with macOS `say`
  fallback).

### WebSocket protocol (app ⇄ bridge, port 8765)

| Direction | Message | Meaning |
|---|---|---|
| app → bridge | `{"type":"query","text":...}` | Transcribed utterance (STT is on-device) |
| bridge → app | `{"type":"capture_photo"}` | Take a photo with the glasses now |
| app → bridge | `{"type":"photo","data":"<base64 jpeg>"}` | Captured photo |
| app → bridge | `{"type":"photo_error","message":...}` | Capture failed — answer text-only |
| bridge → app | `{"type":"response","text":...}` | Hermes's answer |
| bridge → app | `audio_start` / binary PCM16 24 kHz / `audio_end` | Spoken reply |

Binary frames from the app are reserved for mic audio (legacy server-side STT
path, still supported by the bridge).

## Setup

### Requirements

- iPhone with iOS 17+, Xcode 16+
- Meta Ray-Ban glasses paired with the Meta AI app
- macOS with Python 3.11+ and a working Hermes Agent install
  (`hermes chat` on PATH)

### Mac bridge

```bash
cd bridge
pip install websockets edge-tts SpeechRecognition   # SpeechRecognition optional (legacy audio path)
python hermes_bridge.py
# → listens on ws://0.0.0.0:8765/voice
```

### iOS app

1. Open `HermesGlasses.xcodeproj`, set your signing team, build to your iPhone.
2. In the app: **Connect Glasses** → complete registration in the Meta AI app.
3. Settings (gear icon) → set the endpoint to `ws://<your-mac-ip>:8765/voice`.
   The "Bridge" chip in the banner turns green when the bridge is reachable.
4. Start a session. First run prompts for microphone + speech recognition
   permissions; the first photo prompts for **camera permission via Meta AI**
   (tap the Photo test button to trigger the grant flow).

## Testing

Use the built-in test panel (visible while a session is active):

| Button | Verifies |
|---|---|
| Bridge | WebSocket connectivity + welcome handshake |
| Photo | Glasses camera capture alone (also runs the permission grant) |
| Query | Bridge → Hermes → response → TTS round trip |
| Visual | Full photo + vision pipeline |

Bridge-side unit tests:

```bash
cd bridge && python -m unittest test_hermes_bridge -v
```

## Project layout

```
HermesGlasses/
├── Services/
│   ├── HermesSpeechRecognizer.swift   # on-device live STT
│   ├── HermesAudioManager.swift       # mic capture + TTS playback
│   ├── HermesCameraManager.swift      # glasses photo capture (DAT camera)
│   └── HermesAPIClient.swift          # WebSocket client
├── ViewModels/                        # session orchestration, registration
└── Views/                             # SwiftUI UI + test panel
bridge/
├── hermes_bridge.py                   # WebSocket bridge on the Mac
└── test_hermes_bridge.py              # unit tests
docs/superpowers/                      # design specs and implementation plans
```

## Status / known limitations

- Voice loop and vision loop are working end-to-end on device.
- The microphone currently used is the **iPhone's** — routing audio through the
  glasses microphone is the next milestone.
- Glasses photos may arrive rotated (EXIF orientation not yet normalized).
- Visual-query detection is keyword-based ("look", "what is this", …).
