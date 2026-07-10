# Barge-In (Interrupt Hermes While Speaking)

**Date:** 2026-07-10
**Status:** Approved

## Goal

Let the user cut Hermes off mid-reply: by voice in glasses mode (Bluetooth
HFP hardware echo cancellation makes this safe), and by tap in any mode.

## Behavior

- **Voice barge-in (glasses route only):** when TTS starts, recognition
  resumes immediately instead of staying suspended. If a partial transcript
  of ≥ 2 words arrives during `.speaking` — and is not an echo of Hermes's
  own words — playback stops and the utterance continues as the next query
  (normal pause-finalize → submit flow).
- **Tap-to-interrupt (all modes):** tapping the "Hermes is speaking…"
  indicator stops playback and returns to listening.
- **Phone route:** no voice barge-in (no echo cancellation between phone
  speaker and mic); recognition stays suspended through `.speaking` as today.

## Components

- `HermesAudioManager.stopPlayback()` — stops the AVAudioPlayer clip and
  fires `onPlaybackComplete` (AVAudioPlayer.stop() does not call the
  delegate).
- `HermesSessionViewModel`:
  - `client.onAudioResponse`: after entering `.speaking`, un-suspend the
    recognizer when the actual route is Bluetooth (`isUsingBluetoothInput`).
  - `onPartial` handler: during `.speaking`, drop echo-like partials
    (normalized substring of `lastResponse`); interrupt at ≥ 2 words.
  - `interruptSpeech()` — guard `.speaking`, call `stopPlayback()`.
- `ContentView`: speaking indicator becomes a button with a "tap to
  interrupt" hint.

## Echo guard

Normalize (lowercase, alphanumeric+space only) both the partial and
`lastResponse`; if the partial appears in the response text, treat it as
the glasses hearing Hermes and ignore it. Heuristic: a genuine interruption
that happens to quote Hermes verbatim is ignored — acceptable.

## Testing (on device)

1. Glasses mode, long answer: speak 2+ words mid-reply → TTS stops,
   words appear live, pause → answered as the next query.
2. Glasses mode: stay silent through a reply → plays to completion (echo
   does not self-interrupt).
3. Phone mode: tap the speaking indicator → immediate return to listening.
