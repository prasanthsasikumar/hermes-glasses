//
// ConversationCapture.swift
//
// Pure state for a conversation-capture session ("record this
// conversation"): every finalized utterance becomes a transcript line, and
// dwell-fired person snaps are gated so one long chat doesn't fill the
// store with near-duplicate photos. Foundation + CoreGraphics only (uses
// Detection) so tests/conversation compiles it with plain swiftc.
//
// The camera/STT plumbing lives in HermesSessionViewModel; this type only
// decides what to keep.
//

import Foundation
import CoreGraphics

struct ConversationCaptureModel {
    /// Hard cap on photos per session - a two-hour dinner should not
    /// produce fifty pictures.
    let maxPhotos: Int
    /// Minimum seconds between kept snaps. The dwell tracker already
    /// prevents re-fires while the reticle stays on one person; this gates
    /// the look-away-look-back re-fires.
    let minSnapGap: TimeInterval

    private(set) var lines: [String] = []
    private(set) var snapCount = 0
    private var lastSnapAt: TimeInterval?

    init(maxPhotos: Int = 12, minSnapGap: TimeInterval = 10) {
        self.maxPhotos = maxPhotos
        self.minSnapGap = minSnapGap
    }

    /// Append a finalized utterance. Blank utterances are dropped.
    mutating func addLine(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(trimmed)
    }

    /// The whole conversation as one note, in spoken order.
    var note: String { lines.joined(separator: "\n") }

    /// True when ending the session has something worth saving.
    var hasContent: Bool { !lines.isEmpty || snapCount > 0 }

    /// Ask permission to keep a dwell-fired snap; records it when granted.
    /// Refused when inside the gap or at the photo cap.
    mutating func recordSnap(at time: TimeInterval) -> Bool {
        guard snapCount < maxPhotos else { return false }
        if let last = lastSnapAt, time - last < minSnapGap { return false }
        lastSnapAt = time
        snapCount += 1
        return true
    }

    /// Person-only filter, applied at the detection boundary so the dwell
    /// tracker never locks onto a chair.
    static func people(_ detections: [Detection]) -> [Detection] {
        detections.filter { $0.label == "person" }
    }
}
