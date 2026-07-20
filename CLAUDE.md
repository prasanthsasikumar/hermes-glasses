# Hermes Glasses - notes for Claude

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
- **Audio session uses mode `.default`, not `.voiceChat`** - voiceChat's DSP
  gates speech to the noise floor (~20 dB down). There is therefore NO echo
  cancellation: the recognizer is suspended while Hermes speaks and resumes
  0.7 s after playback ends.
- **Never detach the TTS player node** - `AVAudioEngine.detachNode` on a live
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
  call is best-effort - errors are logged, never surfaced. Settings keys:
  `display_hud_enabled` (default true), `display_silent_mode`.
- **Glasses mic and the HUD are mutually exclusive.** The glasses mic is
  Bluetooth HFP (the DAT SDK has no audio capability); an active HFP/SCO
  link makes the glasses firmware show its CALL SCREEN on the lens, which
  covers all DAT display content. iPhone mic = HUD visible; glasses mic =
  call screen. Firmware behavior - cannot be overridden from the app.
- **Headset mode is the pocket setup:** `MicSource.headset` routes HFP to
  earbuds (never to the glasses - port chosen by name heuristic in
  `HermesAudioManager.looksLikeGlasses`), so the lens keeps the HUD while
  mic + TTS live in the ears. Falls back to the iPhone mic (with a notice)
  when no non-glasses HFP device is present.
- **Device context:** every query carries a context line (time, location,
  motion, connectivity, battery, weather). Direct mode (the provider path)
  gets it as a SECOND, uncached system block (persona block stays first + cached);
  bridge mode gets it as a "[Context: …]" prefix on the query text - the
  bridges need no changes. History stores raw user text only. Keys:
  `context_enabled` / `context_precise_location` (both default true).
- **On-device intents (`IntentDetector`):** the finalized transcript is
  classified BEFORE the AI brain. "take me to X" / "I want to go to X" starts
  `NavigationController` (MapKit route + CoreLocation) and never hits the AI;
  the lens shows a Mapbox static map re-centered on the user (https images
  only, 600x600, throttled >=15 m and >=4 s). "what is X" runs the normal
  answer AND fetches a Wikipedia lead image, rendered as text + `Image` on the
  lens. Keys: `navigation_enabled`, `definition_images_enabled`; Mapbox token
  in Keychain via `MapCredentials`. All display-only + best-effort.
- **Social encounters ("remember this person"):** a whole-utterance command
  (NOT a substring - "remember" is too common) starts a capture: the glasses
  photo and the spoken note run IN PARALLEL (`encounterPhotoTask` is joined by
  `finishEncounter`, so they can land in either order). The next finalized
  utterance is claimed as the note before any other intent runs; "cancel"
  discards; 30 s of silence saves the photo with an empty note; a camera
  failure saves the note alone. Persisted by `EncounterStore` to Application
  Support (`encounters.json` + `photos/*.jpg`) - no AI, no bridge, no network.
  Reviewed in `PeopleView`. Key: `social_notes_enabled`.
- **Settings is a hub, not one scroll** (`Views/SettingsView.swift`, extracted
  out of ContentView): a glasses status card plus one row per area, detail one
  tap deeper. Text the user types (bridge endpoint, API key) is owned by the
  ROOT SettingsView and committed on Done *and* swipe-dismiss - sub-pages take
  bindings, so nothing is lost whichever page is open.
- **Lens view (Object Snap):** live glasses video via a persistent stream -
  the ONE exception to one-shot camera streams, owned by
  `HermesCameraManager.startLiveStream`/`stopLiveStream` and running only
  while `LensView` is on screen. Lens does NOT need (and must never start)
  the voice session: it connects a camera-only DeviceSession via
  `HermesSessionViewModel.ensureCameraSession()` (reuses the voice session
  when one is live) and releases it on close - opening Lens never leaves
  the mic listening. While it runs, `capturePhoto()` serves the
  latest live frame as JPEG (voice visual queries keep working; no second
  stream). Detection: bundled `yolo11n.mlpackage` (ultralytics export,
  `nms=True` - see `tools/export-yolo.md`) via `VNCoreMLRequest`;
  `ObjectDetector` converts Vision's bottom-left boxes to top-left-origin
  `Detection`s ONCE at that boundary. `DwellTracker` (pure logic, tested in
  `tests/dwell/`) fires a snap after 2 s of center-reticle coverage with
  IoU-based identity + post-snap cooldown. Snaps are session-only, in
  memory, no AI/bridge/network.
- **`VoiceCommandCatalog` feeds the "What can I say?" page** from the
  detectors' own phrase lists (`IntentDetector.navTriggers` etc. are internal,
  NOT private, for exactly this). Never hand-copy trigger phrases into the UI -
  add them to the detector and the tester-facing list updates itself.

## Build & run

```bash
# iOS (from repo root; use your own device ID from `xcrun devicectl list devices`)
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'generic/platform=iOS' build

# Bridge (from bridge/) - logs to stdout; tests:
python -m unittest test_hermes_bridge -v
```

## Next milestones

- Route audio through the glasses microphone (`startCapture(useGlassesMic:
  true)`, HFP path) - currently the iPhone mic is used.
- Normalize EXIF rotation of glasses photos before sending to Hermes.
- Word-boundary matching for visual keywords ("outlook" currently matches
  "look").
