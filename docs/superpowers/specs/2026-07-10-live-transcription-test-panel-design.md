# Live On-Device Transcription + Test Panel

**Date:** 2026-07-10
**Status:** Approved (user: "go ahead, i want on-device fast recognition")

## Goal

Words appear on screen in real time as the user speaks; the clunky
Recording/Processing state flapping disappears. Every subsystem gets a
manual test button so failures are isolated per component.

## Architecture change

Speech-to-text moves from the Mac (Google STT on streamed audio) to the
iPhone (Apple Speech framework, on-device). The app sends **final text**
to the bridge instead of audio. The bridge's audio+STT path remains for
backward compatibility but the app no longer streams mic audio.

```
Before: mic → PCM over WiFi → bridge VAD → Google STT → hermes → TTS
After:  mic → SFSpeechRecognizer (on device, live partials in UI)
             → {"type":"query","text":...} → bridge → hermes → TTS
```

Photo flow is unchanged: the bridge still keyword-checks the (now
client-supplied) text and requests `capture_photo` when visual.

## Components

- **`HermesGlasses/Services/HermesSpeechRecognizer.swift` (new)** — wraps
  `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest` with
  on-device recognition (`requiresOnDeviceRecognition` when supported).
  API: `requestAuthorization() async -> Bool`, `start() throws`,
  `append(_ buffer: AVAudioPCMBuffer)`, `finalizeNow()`, `stop()`;
  callbacks `onPartial(String)`, `onFinal(String)`.
  End-of-utterance: 1.5 s with no partial-transcript change → current text
  is final → `onFinal` → recognizer restarts for the next utterance.
  `finalizeNow()` forces the same immediately (Send button).
- **`HermesAudioManager`** — new `onRawBuffer((AVAudioPCMBuffer) -> Void)?`
  tap callback (raw, pre-conversion) and `onLevel((Float) -> Void)?`
  (RMS ~4×/s for the UI meter). Existing conversion path kept but unused
  by default.
- **`HermesAPIClient`** — `sendQuery(_ text: String)` sends
  `{"type":"query","text":...}`.
- **`HermesSessionViewModel`** — wires buffers → recognizer; publishes
  `liveTranscript`, `micLevel`; `sendNow()`; suppresses recognition while
  `.processing`/`.speaking` (no echo transcription); test-panel actions
  with published pass/fail results: `testBridge()`, `testPhoto()`,
  `testQuery()`, `testVisualQuery()`.
- **`ContentView`** — live transcript bubble (italic, updates per word) +
  "Send now" button; "Testing" section listing each test with ✓/✗/running
  state and error text; mic level bar.
- **`bridge/hermes_bridge.py`** — new `query` message type: text goes
  straight to the visual-keyword/photo/hermes/TTS pipeline (shared
  `process_query(websocket, text)` refactored out of `process_utterance`;
  the STT part stays in `process_utterance`). Unit test covers the query
  path including the visual branch (monkeypatched `ask_hermes`/TTS).
- **`Info.plist`** — `NSSpeechRecognitionUsageDescription`.

## Protocol addition

| Direction | Message | Meaning |
|---|---|---|
| app → bridge | `{"type":"query","text":"..."}` | Transcribed utterance; bridge skips STT |

## UI states

`Listening` (live words visible, mic meter moving) → `Processing`
(thinking) → `Speaking` (TTS) → back to `Listening`. `Recording` state is
no longer entered in the text-query flow.

## Error handling

- Speech authorization denied → clear error with Settings pointer; session
  can still start (test buttons work; no transcription).
- On-device model unavailable → falls back to Apple's server recognition
  automatically (still no Mac round-trip).
- Recognizer error mid-utterance → restart recognizer, keep session alive.

## Out of scope

- Removing the bridge's audio/STT path (kept as fallback).
- Wake-word detection; multi-language.
