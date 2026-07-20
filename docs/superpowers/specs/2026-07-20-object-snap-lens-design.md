# Object Snap ("Lens" view) — Design

Date: 2026-07-20
Status: approved

## Goal

Stream live video from the Ray-Ban glasses camera to the phone, run YOLO
object detection on-device, and when the user holds an object under the
center of their view for 2 seconds, crop that object out of the frame and
show it as a snap in a strip below the live feed.

"Pointing" is center-of-view dwell: whatever object sits under a center
reticle. No hand detection.

Snaps are session-only: they live in memory while the Lens view is open
and are discarded when the user leaves the screen. No persistence, no AI,
no bridge, no network.

## Architecture

### New components

- **`LensView`** (SwiftUI, `Views/LensView.swift`) — opened from the home
  screen; requires glasses connected. Live feed on top, snap strip below.
  The stream starts `onAppear` and stops `onDisappear`; the feature never
  runs in the background, so glasses battery drain is bounded by the view
  being on screen.

- **`HermesCameraManager.startLiveStream(onFrame:)` / `stopLiveStream()`** —
  a second mode on the existing manager (it already owns the
  `DeviceSession`). Uses the DAT SDK's `videoFramePublisher` on a
  persistent stream. This is a deliberate, documented exception to the
  one-shot-stream rule, guarded by the same state lock as photo capture.
  While the live stream is active, `capturePhoto()` returns the latest
  video frame encoded as JPEG instead of opening a competing stream, so
  the voice loop's visual queries keep working during streaming.

- **`ObjectDetector`** (`Services/ObjectDetector.swift`) — wraps a
  YOLO11n/YOLOv8n CoreML model via `VNCoreMLRequest`. Latest-wins
  backpressure: at most one Vision request in flight; newer frames replace
  any queued frame. Output per processed frame: `[Detection]` with label,
  confidence, and normalized bounding box. COCO's 80 classes only.

- **`DwellTracker`** (`Services/DwellTracker.swift`, pure logic, no
  dependencies) — consumes `(detections, timestamp)` and tracks which
  detection contains the center reticle point. Fires a snap event after
  2.0 s of continuous coverage by the "same" object. Identity across
  frames = same label + IoU ≥ 0.3 with the previous frame's box (boxes
  jitter frame to frame). If several boxes contain the reticle, the one whose
  center is nearest the reticle wins. After a snap: cooldown — no re-snap
  of that object until the reticle has left it.

- **Model asset** — one-time export of YOLO11n to CoreML, documented in
  `tools/export-yolo.md` (ultralytics export command). The resulting
  ~6 MB `.mlpackage` is committed to the repo so builds are reproducible.

## Data flow

Glasses camera → `videoFramePublisher` (`CMSampleBuffer`) →
1. UI feed image (every frame), and
2. `ObjectDetector` (throttled, latest-wins) → `[Detection]` →
   overlay boxes + `DwellTracker` →
3. on 2 s dwell: crop the winning box (with ~10 % padding, clamped to
   frame bounds) out of the latest full frame → append
   `Snap { image, label, date }` to a session-only array rendered in the
   strip.

Stream resolution: the highest the SDK offers that keeps frame rate
acceptable on device (crops come from these frames, so resolution matters;
final choice made during on-device testing).

## UI

- Live feed: aspect-fit image with a `Canvas` overlay drawing detection
  boxes and labels.
- Center reticle with a progress ring that fills as dwell accumulates
  (0 → 2 s) so lock-on is visible.
- Below the feed: horizontal strip of snaps (thumbnail + label caption),
  newest first; tap opens a full-size sheet.
- Close/stop control and a small FPS/status line for debugging.
- No settings toggle: the feature only runs while the view is open.

## Edge cases & error handling

- Stream error or glasses disconnect → banner + stream teardown, reusing
  the existing error/state publisher plumbing and the camera-permission
  hint from the Photo test path (`wearables.requestPermission(.camera)`).
- Frames arriving before the CoreML model finishes loading are displayed
  without boxes.
- Frame orientation verified on device (the known EXIF-rotation caveat
  applies to captured photos; video frames may behave differently).
- Photo capture and live stream never compete for the camera: capture
  during streaming is served from the latest live frame.

## Testing

- `DwellTracker`: pure-logic test executable at `tests/dwell/main.swift`,
  matching the existing tests pattern. Covers: dwell accumulation to
  trigger, jitter tolerance via IoU identity, reset when the reticle
  leaves the object, nearest-center tie-breaking, and post-snap cooldown.
- `ObjectDetector`, streaming, orientation, and UI are verified on device.
