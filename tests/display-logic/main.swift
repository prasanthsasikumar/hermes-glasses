//
// Standalone tests for HermesDisplayLogic — no XCTest target in this
// project, so these run via swiftc (see command below).
//

import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

// truncateReply
expect(HermesDisplayLogic.truncateReply("short reply") == "short reply",
       "short reply unchanged")
expect(HermesDisplayLogic.truncateReply("  padded  ") == "padded",
       "reply trimmed")
let exactly300 = String(repeating: "a", count: 300)
expect(HermesDisplayLogic.truncateReply(exactly300) == exactly300,
       "300 chars unchanged")
let long = String(repeating: "b", count: 400)
let truncated = HermesDisplayLogic.truncateReply(long)
expect(truncated.count == 300, "long reply truncated to 300")
expect(truncated.hasSuffix("…"), "truncated reply ends with ellipsis")

// readingDwellSeconds: max(6, ceil(chars / 15))
expect(HermesDisplayLogic.readingDwellSeconds(charCount: 30) == 6,
       "short reply reads for the 6 s floor")
expect(HermesDisplayLogic.readingDwellSeconds(charCount: 300) == 20,
       "300 chars read for 20 s")
expect(HermesDisplayLogic.readingDwellSeconds(charCount: 91) == 7,
       "91 chars round up to 7 s")

// spoken dwell constant
expect(HermesDisplayLogic.spokenDwellSeconds == 8, "spoken dwell is 8 s")

// DisplaySendThrottle: at most one send per 0.4 s
var throttle = DisplaySendThrottle()
let t0 = Date(timeIntervalSince1970: 1_000)
expect(throttle.shouldSend(at: t0), "first send allowed")
expect(!throttle.shouldSend(at: t0.addingTimeInterval(0.2)),
       "send 0.2 s later blocked")
expect(throttle.shouldSend(at: t0.addingTimeInterval(0.5)),
       "send 0.5 s later allowed")
expect(!throttle.shouldSend(at: t0.addingTimeInterval(0.6)),
       "interval measured from last SENT, not last attempt")

if failures > 0 {
    print("\(failures) test(s) FAILED")
    exit(1)
}
print("All display logic tests passed")
