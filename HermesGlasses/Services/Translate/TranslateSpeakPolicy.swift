//
// TranslateSpeakPolicy.swift
//
// Decides whether a word the detector just offered is actually SPOKEN.
// It sits on top of DwellTracker rather than inside it: the tracker is
// shared with Lens and conversation capture, and its cooldown clears on a
// single missed frame - fine for a log, but a flickering box (or a row of
// parked cars) would make Translate chatter.
//
// Two rules:
//  - a confidence floor above the detector's own (0.4 is fine for a log
//    row, not for a word said aloud to someone learning it);
//  - the same word, in the same language, is not repeated within the
//    quiet period. Keyed by language + word, so switching language and
//    looking at the same banana still speaks.
//
// Both constants are PROVISIONAL until tried on a real walk.
// Time is passed in; tested in tests/translate/.
//

import Foundation

struct TranslateSpeakPolicy {
    static let minimumConfidence: Float = 0.6
    static let quietPeriod: TimeInterval = 8

    private var lastSpoken: [String: TimeInterval] = [:]

    enum Verdict: Equatable {
        /// Say it now. The policy has recorded it.
        case speak
        /// The detector wasn't sure enough on this frame. Worth another
        /// look: the caller restarts the dwell rather than spending it.
        case uncertain
        /// Said recently. Silence is the intended outcome - do not retry.
        case quiet
    }

    /// Instant path: what to do with a word the detector just offered.
    mutating func verdict(
        _ term: TranslatedTerm, confidence: Float, at time: TimeInterval
    ) -> Verdict {
        guard confidence >= Self.minimumConfidence else { return .uncertain }
        if let last = lastSpoken[key(term)], time - last < Self.quietPeriod {
            return .quiet
        }
        lastSpoken[key(term)] = time
        return .speak
    }

    /// True = speak now; the policy records it.
    mutating func shouldSpeak(
        _ term: TranslatedTerm, confidence: Float, at time: TimeInterval
    ) -> Bool {
        verdict(term, confidence: confidence, at: time) == .speak
    }

    /// AI path: the user tapped, so the word is always spoken - but it
    /// still starts the quiet period, so the detector doesn't echo it.
    mutating func noteSpoken(_ term: TranslatedTerm, at time: TimeInterval) {
        lastSpoken[key(term)] = time
    }

    private func key(_ term: TranslatedTerm) -> String {
        "\(term.language.rawValue)|\(term.word)"
    }
}
