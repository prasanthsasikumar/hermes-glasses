# Mic Source Toggle (iPhone ⇄ Glasses)

**Date:** 2026-07-10
**Status:** Approved

## Goal

Let the user choose where voice is captured: the iPhone microphone (default,
highest quality) or the Meta Ray-Ban glasses microphone over Bluetooth HFP
(hands-free). In glasses mode, TTS output also plays through the glasses
speakers (HFP is bidirectional; approved trade-off: call-grade quality both
ways).

## UX

- The banner's mic chip ("iPhone Mic"/"Glasses Mic") becomes a button; tapping
  toggles the source, mid-session included. The chip always shows the ACTUAL
  current input route, not the preference.
- Preference persists in `UserDefaults` key `mic_source` (`phone`|`glasses`)
  and is applied at session start.
- Settings gains a "Microphone" picker mirroring the toggle.
- If the glasses route is unavailable (off/out of range), capture falls back
  to the iPhone mic and the standard error banner explains why; the chip shows
  "iPhone Mic".

## Components

- **`HermesAudioManager`**
  - `startCapture(useGlassesMic: Bool) async throws -> Bool` — returns whether
    the glasses (HFP) route is actually active. Glasses mode: category
    `.playAndRecord`, mode `.default` (never `.voiceChat` — its DSP silences
    speech), options `[.allowBluetoothHFP]`, `setPreferredInput` to the HFP
    port, wait up to 3 s (non-blocking) for the route. Phone mode: unchanged
    (`[.defaultToSpeaker]`, no Bluetooth options).
  - New `onRouteChanged: (() -> Void)?` — fired from the engine
    configuration-change observer after the tap is reinstalled.
- **`HermesSpeechRecognizer`**
  - New `restartCycle()` — tears down and restarts the recognition cycle.
    Required because `SFSpeechAudioBufferRecognitionRequest` cannot absorb a
    buffer-format change mid-request; without a restart the recognizer goes
    silently deaf after any route change.
- **`HermesSessionViewModel`**
  - `micSource: MicSource` (`.phone`/`.glasses`) published, backed by
    UserDefaults.
  - `toggleMicSource() async` — persists the flip; if a session is live:
    `stopCapture()` → `startCapture(useGlassesMic:)` → `restartCycle()`;
    shows an error and reflects reality on fallback.
  - Wires `onRouteChanged` → `restartCycle()` (fixes the latent deaf-after-
    route-change bug for AirPods/cable events too).
- **`ContentView`** — chip becomes a Button; Settings picker.

Bridge: no changes.

## Error handling

- No HFP input found after 3 s → automatic phone-mic fallback + error banner
  ("Glasses mic not available — using iPhone mic").
- `startCapture` failure mid-toggle → endSession with the standard error path
  (same as today's startup failure).

## Testing (on device)

1. Toggle to glasses mid-session: live words continue; TTS audible in glasses.
2. Toggle back to phone: live words continue; TTS from phone speaker.
3. Glasses-off toggle: fallback banner, capture keeps working on iPhone mic.
4. Session start with glasses preference persisted: comes up in glasses mode.

## Out of scope

- DAT SDK-native mic access (SDK does not expose the mic; HFP is the path).
- Per-source gain/EQ tuning.
