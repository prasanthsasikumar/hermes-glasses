# Glasses Photo + Vision ("What am I looking at?")

**Date:** 2026-07-10
**Status:** Approved

## Goal

Let the user ask visual questions hands-free. When an utterance implies sight
("what am I looking at?"), the app captures a photo from the Meta Ray-Ban
glasses camera and Hermes answers about the image, spoken aloud like any
other reply. Non-visual questions are unaffected.

## Background

The voice loop already works end-to-end: app streams 16 kHz PCM to the Python
bridge (`bridge/hermes_bridge.py`), which does server-side VAD, Google STT,
`hermes chat`, and TTS back as PCM16 mono 24 kHz. The DAT SDK's
`MWDATCamera` framework is already linked: `DeviceSession.addStream()` returns
a `Stream` with `capturePhoto(format:)`, and photos arrive as JPEG `Data`
through `photoDataPublisher`. `hermes chat` accepts `--image <path>` on a
single query and `-Q` (quiet) prints only the final response.

## Flow

1. User speaks; bridge transcribes (unchanged).
2. Bridge checks the transcript, case-insensitively, against visual keywords:
   "look", "looking at", "see this", "seeing", "what is this", "what's this",
   "read this", "in front of me", "picture", "photo", "camera".
3. No match → existing flow, no added latency.
4. Match → bridge sends `{"type":"capture_photo"}` to the app and awaits the
   photo (10 s timeout).
5. App captures via DAT camera: lazily `addStream()` on the existing device
   session → `start()` → wait for `.streaming` state → `capturePhoto(.jpeg)`
   → JPEG from `photoDataPublisher` → `stop()` the stream (no idle battery
   drain on the glasses).
6. App replies with a single text frame `{"type":"photo","data":"<base64>"}`.
   Base64-in-JSON keeps binary WebSocket frames unambiguous: binary always
   means mic audio.
7. Bridge decodes to a temp JPEG and runs
   `hermes chat -q "<transcript>" --image <tmp.jpg> -Q`; reply flows through
   the existing response + TTS path. Temp file deleted afterwards.
8. The app shows the captured photo as a thumbnail in that conversation turn.

## Components

- **`HermesGlasses/Services/HermesCameraManager.swift` (new)** - owns the DAT
  camera stream lifecycle. API: `capturePhoto() async throws -> Data`.
  Receives the `DeviceSession` from the ViewModel. Handles stream start/stop,
  state waiting, timeout.
- **`HermesAPIClient`** - new incoming message `capture_photo` → callback
  `onCapturePhotoRequested`; new method `sendPhoto(_ data: Data)` that
  base64-encodes and sends the JSON frame.
- **`HermesSessionViewModel`** - wires `onCapturePhotoRequested` →
  `HermesCameraManager.capturePhoto()` → `sendPhoto`. On failure sends
  `{"type":"photo_error","message":...}` so the bridge stops waiting.
  Stores the last photo to attach to the next `ConversationTurn` for display.
- **`ContentView`** - renders a thumbnail in the turn bubble when the turn
  has a photo.
- **`bridge/hermes_bridge.py`** - keyword check after STT; when triggered,
  sends `capture_photo`, awaits `photo` / `photo_error` / 10 s timeout while
  still consuming (and discarding) incoming audio frames; invokes
  `ask_hermes(text, image_path=...)`.
  Ride-along cleanup: `ask_hermes` switches to `-Q` quiet mode; the
  box-scraping `extract_hermes_reply` remains only as fallback if quiet
  output still contains the session footer.

## Protocol additions

| Direction | Message | Meaning |
|---|---|---|
| bridge → app | `{"type":"capture_photo"}` | Take a photo now |
| app → bridge | `{"type":"photo","data":"<base64 jpeg>"}` | Captured photo |
| app → bridge | `{"type":"photo_error","message":"..."}` | Capture failed |

## Error handling

- Camera unavailable, stream fails, timeout, or glasses disconnected →
  app sends `photo_error`; bridge proceeds **text-only**, prepending
  "(No photo could be captured from the glasses.)" to the query so Hermes
  can acknowledge the miss.
- Bridge-side 10 s await timeout behaves identically to `photo_error`.
- App-side errors also surface in the existing error banner.

## Testing

- Bridge: exercise keyword matching and the photo-await path with a small
  fake WebSocket client on the Mac (send transcript-triggering audio is not
  needed - unit-test `is_visual_query()` and drive the socket directly).
- Device: end-to-end - wear glasses, ask "what am I looking at?", verify
  thumbnail + spoken answer; ask a non-visual question, verify no capture.

## Out of scope

- Video streaming/live preview.
- Saving photos to the camera roll.
- Multi-photo queries or follow-up references to earlier photos.
