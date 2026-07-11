# Hermes Glasses — notes for Claude

Part of the Sidekick project. See README.md for architecture and setup.

## Current state (2026-07-10)

Voice loop and vision loop both work end-to-end on device:
live on-device transcription (SFSpeechRecognizer) → `{"type":"query"}` over
WebSocket → Python bridge → `hermes chat -q [--image] -Q` → response text +
TTS (PCM16 mono 24 kHz) back to the phone. Visual queries trigger a glasses
photo via the DAT camera API.

## Key facts that are easy to get wrong

- **STT is on-device.** The app does NOT stream mic audio to the bridge
  anymore. The bridge's audio/VAD/Google-STT path is legacy fallback only.
- **Audio session uses mode `.default`, not `.voiceChat`** — voiceChat's DSP
  gates speech to the noise floor (~20 dB down). There is therefore NO echo
  cancellation: the recognizer is suspended while Hermes speaks and resumes
  0.7 s after playback ends.
- **Never detach the TTS player node** — `AVAudioEngine.detachNode` on a live
  node raises NSException (SIGABRT). The player is attached once and reused.
- **SFSpeechRecognizer:** `task.cancel()` fires the old task's handler with an
  error. Restart cycles are guarded by a generation counter or the recognizer
  goes deaf after the first suspend/resume.
- **Glasses camera needs a separate permission** granted through the Meta AI
  app: `wearables.requestPermission(.camera)` (the Photo test button runs it).
  Streams fail with `permissionDenied` otherwise.
- **Camera streams are one-shot:** fresh `addStream()` per capture, stopped
  via `defer` on every path. Config matches Meta's CameraAccess sample
  (`.raw`, `.low`, 24 fps).
- **WebSocket frames:** binary from app = mic audio (legacy). Photos travel
  ONLY as base64 JSON. The bridge runs `websockets.serve(..., max_size=16MiB)`
  because a base64 JPEG exceeds the 1 MiB default.
- **Display HUD (Ray-Ban Display):** `HermesDisplayManager` attaches
  `addDisplay()` to the SAME DeviceSession as the camera. Every display
  call is best-effort — errors are logged, never surfaced. Settings keys:
  `display_hud_enabled` (default true), `display_silent_mode`.
- **Glasses mic and the HUD are mutually exclusive.** The glasses mic is
  Bluetooth HFP (the DAT SDK has no audio capability); an active HFP/SCO
  link makes the glasses firmware show its CALL SCREEN on the lens, which
  covers all DAT display content. iPhone mic = HUD visible; glasses mic =
  call screen. Firmware behavior — cannot be overridden from the app.
- **Headset mode is the pocket setup:** `MicSource.headset` routes HFP to
  earbuds (never to the glasses — port chosen by name heuristic in
  `HermesAudioManager.looksLikeGlasses`), so the lens keeps the HUD while
  mic + TTS live in the ears. Falls back to the iPhone mic (with a notice)
  when no non-glasses HFP device is present.
- **Device context:** every query carries a context line (time, location,
  motion, connectivity, battery, weather). Claude Direct gets it as a
  SECOND, uncached system block (persona block stays first + cached);
  bridge mode gets it as a "[Context: …]" prefix on the query text — the
  bridges need no changes. History stores raw user text only. Keys:
  `context_enabled` / `context_precise_location` (both default true).

## Build & run

```bash
# iOS (from repo root; use your own device ID from `xcrun devicectl list devices`)
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'generic/platform=iOS' build

# Bridge (from bridge/) — logs to stdout; tests:
python -m unittest test_hermes_bridge -v
```

## Next milestones

- Route audio through the glasses microphone (`startCapture(useGlassesMic:
  true)`, HFP path) — currently the iPhone mic is used.
- Normalize EXIF rotation of glasses photos before sending to Hermes.
- Word-boundary matching for visual keywords ("outlook" currently matches
  "look").
