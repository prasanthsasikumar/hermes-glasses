//
// HermesDisplayLogic.swift
//
// Pure logic for the glasses display HUD: reply truncation, dwell
// times, and partial-transcript send throttling. Foundation-only so it
// unit-tests standalone (tests/display-logic/) without the DAT SDK.
//

import Foundation

enum HermesDisplayLogic {
    /// Replies longer than this are cut with an ellipsis — spoken
    /// replies are 1-3 sentences, so truncation is rare.
    static let replyCharLimit = 300

    /// How long a spoken reply stays on the lens after TTS ends.
    static let spokenDwellSeconds: Double = 8

    /// Minimum interval between partial-transcript sends (BLE budget).
    static let partialMinInterval: TimeInterval = 0.4

    static func truncateReply(
        _ text: String, limit: Int = replyCharLimit
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// Silent mode: reading time instead of TTS duration.
    static func readingDwellSeconds(charCount: Int) -> Double {
        max(6, (Double(charCount) / 15).rounded(.up))
    }
}

/// Rate limiter for partial-transcript sends. Callers bypass it for
/// finalized utterances (those always send).
struct DisplaySendThrottle {
    private var lastSent: Date?
    let minInterval: TimeInterval

    init(minInterval: TimeInterval = HermesDisplayLogic.partialMinInterval) {
        self.minInterval = minInterval
    }

    mutating func shouldSend(at now: Date = Date()) -> Bool {
        if let lastSent, now.timeIntervalSince(lastSent) < minInterval {
            return false
        }
        lastSent = now
        return true
    }
}
