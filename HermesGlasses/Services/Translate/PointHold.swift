//
// PointHold.swift
//
// "The finger has rested on one spot long enough to mean it." Fires ONCE
// per hold, then stays spent until the finger goes somewhere else or the
// hand leaves - a finger resting on a thing must not send it to the AI
// again and again.
//
// Time is passed in, so this is tested without a clock. Distances are
// fractions of the frame. All constants PROVISIONAL.
//
// Foundation only; tested in tests/translate/.
//

import Foundation
import CoreGraphics

struct PointHold {
    static let holdSeconds: TimeInterval = 1.0
    /// The probe may wander this far from where the hold began.
    static let stillRadius: CGFloat = 0.05
    /// After firing, the probe must move this far to arm again.
    static let rearmDistance: CGFloat = 0.12
    /// Hand-pose detection flickers; a gap shorter than this is ignored.
    static let flickerGrace: TimeInterval = 0.3
    /// No pointing hand for this long arms the same spot again.
    static let lostReset: TimeInterval = 1.0

    struct Update: Equatable {
        /// 0...1, how much of the hold has elapsed. 1 while spent.
        let progress: Double
        let fired: Bool
    }

    private var anchor: CGPoint?
    private var startedAt: TimeInterval = 0
    /// When the pointing hand was first reported gone; nil while seen.
    private var missingSince: TimeInterval?
    private var spentAt: CGPoint?

    /// `probe` is nil when no pointing hand is in the frame.
    mutating func update(probe: CGPoint?, at time: TimeInterval) -> Update {
        guard let probe else {
            if missingSince == nil { missingSince = time }
            applyAbsence(until: time)
            return Update(progress: 0, fired: false)
        }
        applyAbsence(until: time)
        missingSince = nil

        if let spent = spentAt {
            guard Self.distance(probe, spent) > Self.rearmDistance else {
                return Update(progress: 1, fired: false)
            }
            spentAt = nil
            anchor = nil
        }

        guard let held = anchor, Self.distance(probe, held) <= Self.stillRadius else {
            anchor = probe
            startedAt = time
            return Update(progress: 0, fired: false)
        }

        let progress = min(1, (time - startedAt) / Self.holdSeconds)
        // The tolerance absorbs floating-point dust in the timestamps.
        guard progress >= 1 - 1e-9 else { return Update(progress: progress, fired: false) }
        spentAt = held
        anchor = nil
        return Update(progress: 1, fired: true)
    }

    /// The hold fired but a guard blocked what it was for (a call already
    /// in flight, too soon after the last one). Not spent: a finger still
    /// resting there fires again after another full hold.
    mutating func restart() {
        spentAt = nil
        anchor = nil
    }

    mutating func reset() {
        anchor = nil
        spentAt = nil
        missingSince = nil
    }

    private mutating func applyAbsence(until time: TimeInterval) {
        guard let missingSince else { return }
        let gap = time - missingSince
        if gap >= Self.flickerGrace { anchor = nil }
        if gap >= Self.lostReset { spentAt = nil }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
