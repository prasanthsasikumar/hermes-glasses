//
// Standalone tests for ConversationCaptureModel. No XCTest target, so build
// via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Lens/DwellTracker.swift \
//     HermesGlasses/Services/Social/ConversationCapture.swift \
//     tests/conversation/main.swift -o /tmp/conversation-tests && /tmp/conversation-tests
//
import Foundation
import CoreGraphics

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}
func expectTrue(_ got: Bool, _ label: String) { expectEqual(got, true, label) }

// Transcript accumulation: trimmed, empty lines dropped, joined by newline
var model = ConversationCaptureModel()
expectTrue(!model.hasContent, "fresh model has no content")
expectEqual(model.note, "", "fresh model note is empty")

model.addLine("  Hi, I'm Sarah from the AR input team.  ")
model.addLine("")
model.addLine("   ")
model.addLine("We should demo the prototype on Thursday")
expectEqual(model.note,
            "Hi, I'm Sarah from the AR input team.\nWe should demo the prototype on Thursday",
            "note joins trimmed lines, skips blanks")
expectTrue(model.hasContent, "lines count as content")

// Snap gating: first snap always allowed, then minSnapGap apart, capped
var gated = ConversationCaptureModel(maxPhotos: 3, minSnapGap: 10)
expectTrue(gated.recordSnap(at: 100), "first snap allowed")
expectEqual(gated.snapCount, 1, "snap recorded")
expectTrue(!gated.recordSnap(at: 105), "snap inside the gap refused")
expectEqual(gated.snapCount, 1, "refused snap not recorded")
expectTrue(gated.recordSnap(at: 110), "snap at exactly the gap allowed")
expectTrue(gated.recordSnap(at: 130), "third snap allowed")
expectTrue(!gated.recordSnap(at: 200), "cap of 3 refused")
expectEqual(gated.snapCount, 3, "count stays at the cap")

// Photos alone are content (a silent room still met people)
var photosOnly = ConversationCaptureModel()
_ = photosOnly.recordSnap(at: 0)
expectTrue(photosOnly.hasContent, "snaps count as content")

// Person filter at the detection boundary
let people = ConversationCaptureModel.people([
    Detection(label: "person", confidence: 0.9,
              rect: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.5)),
    Detection(label: "chair", confidence: 0.8,
              rect: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3)),
    Detection(label: "person", confidence: 0.5,
              rect: CGRect(x: 0.7, y: 0.2, width: 0.2, height: 0.6)),
])
expectEqual(people.count, 2, "only persons pass the filter")
expectTrue(people.allSatisfy { $0.label == "person" }, "no other labels")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
