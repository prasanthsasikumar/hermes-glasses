//
// Standalone tests for DwellTracker. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Lens/DwellTracker.swift \
//     tests/dwell/main.swift -o /tmp/dwell-tests && /tmp/dwell-tests
//
import Foundation
import CoreGraphics

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func expectClose(_ got: Double, _ want: Double, _ label: String) {
    expect(abs(got - want) < 0.01, "\(label) (got \(got), want \(want))")
}

func det(_ label: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
         conf: Float = 0.9) -> Detection {
    Detection(label: label, confidence: conf,
              rect: CGRect(x: x, y: y, width: w, height: h))
}

// A box covering the center of the frame
let cup = det("cup", x: 0.35, y: 0.35, w: 0.3, h: 0.3)
// Same cup, jittered a little (IoU with `cup` well above 0.3)
let cupJittered = det("cup", x: 0.37, y: 0.34, w: 0.3, h: 0.3)
// A box nowhere near the center
let offCenter = det("book", x: 0.0, y: 0.0, w: 0.2, h: 0.2)

// 1. No detections -> no progress, no target
var t = DwellTracker()
var u = t.update(detections: [], at: 0)
expect(u.progress == 0 && u.target == nil && u.snap == nil, "empty frame")

// 2. Off-center boxes are ignored
u = t.update(detections: [offCenter], at: 0.1)
expect(u.target == nil, "off-center box ignored")

// 3. Dwell accumulates on a centered box and fires at 2 s
t = DwellTracker()
u = t.update(detections: [cup], at: 10.0)
expectClose(u.progress, 0, "dwell starts at 0")
expect(u.target?.label == "cup", "target acquired")
u = t.update(detections: [cup], at: 11.0)
expectClose(u.progress, 0.5, "dwell halfway at 1 s")
expect(u.snap == nil, "no snap before 2 s")
u = t.update(detections: [cup], at: 12.0)
expect(u.snap?.label == "cup", "snap fires at 2 s")
expectClose(u.progress, 1.0, "progress full at snap")

// 4. Cooldown: same object never re-snaps while it stays under the reticle
u = t.update(detections: [cup], at: 13.0)
expect(u.snap == nil, "no re-snap during cooldown")
expectClose(u.progress, 1.0, "progress stays full during cooldown")

// 5. Cooldown clears when the reticle leaves; dwell restarts fresh
u = t.update(detections: [offCenter], at: 14.0)
expect(u.target == nil, "target lost when centered box gone")
u = t.update(detections: [cup], at: 15.0)
expectClose(u.progress, 0, "dwell restarts after leaving")
u = t.update(detections: [cup], at: 17.0)
expect(u.snap != nil, "second snap after re-dwell")

// 6. Jitter tolerance: a shifted same-label box continues the dwell
t = DwellTracker()
_ = t.update(detections: [cup], at: 20.0)
u = t.update(detections: [cupJittered], at: 21.0)
expectClose(u.progress, 0.5, "jittered box continues dwell")

// 7. A different label under the reticle resets the dwell
t = DwellTracker()
_ = t.update(detections: [cup], at: 30.0)
let bowl = det("bowl", x: 0.3, y: 0.3, w: 0.4, h: 0.4)
u = t.update(detections: [bowl], at: 31.0)
expectClose(u.progress, 0, "label change resets dwell")
expect(u.target?.label == "bowl", "new target adopted")

// 8. Nearest box-center wins when several boxes contain the reticle
t = DwellTracker()
let tight = det("cup", x: 0.42, y: 0.40, w: 0.18, h: 0.22)  // center (0.51, 0.51)
let tvOff = det("tv", x: 0.0, y: 0.0, w: 0.95, h: 0.95)     // center (0.475, 0.475)
u = t.update(detections: [tvOff, tight], at: 40.0)
expect(u.target?.label == "cup", "nearest-center box wins")

// 9. Tracker follows the box as it drifts (target rect updates)
t = DwellTracker()
_ = t.update(detections: [cup], at: 50.0)
u = t.update(detections: [cupJittered], at: 50.5)
expect(u.target?.rect == cupJittered.rect, "target follows drifting box")

if failures > 0 { print("\n\(failures) FAILURES"); exit(1) }
print("\nAll dwell tests passed")
