//
// IntentDetector.swift
//
// Pure, on-device classification of a finalized utterance into a navigation
// command, a definition request, an encounter capture, or nothing. Runs
// BEFORE the AI brain, so it stays cheap and Foundation-only (mirrors
// VisualQueryDetector's style).
//

import Foundation

enum IntentDetector {
    /// Standalone commands that start an encounter capture (photo + note).
    /// Matched against the WHOLE utterance, not as a substring: "remember"
    /// is far too common a word to trigger on mid-sentence ("remember to
    /// email her", "I remember this place").
    ///
    /// Internal, not private: `VoiceCommandCatalog` builds the in-app
    /// command reference from these lists so the two can't drift apart.
    static let rememberCommands: Set<String> = [
        "remember this person", "remember this guy", "remember this woman",
        "remember this man", "remember this face", "remember this one",
        "remember him", "remember her", "remember them",
        "save this person", "note this person", "new contact",
        "new person", "add contact",
    ]

    /// Spoken away-outs while a note is pending. Not part of `detect` - the
    /// session asks explicitly, because these words are only special in the
    /// awaiting-note state (otherwise "cancel" is a normal query).
    static let cancelWords: Set<String> = [
        "cancel", "never mind", "nevermind", "forget it", "cancel that",
        "discard", "delete that", "stop",
    ]

    /// True when an utterance offered as an encounter note is really the
    /// user backing out.
    static func isEncounterCancellation(_ text: String) -> Bool {
        cancelWords.contains(normalizeCommand(text))
    }

    /// Lowercase, strip punctuation and leading address filler, collapse
    /// whitespace - so "Hey, remember this person!" reduces to the bare
    /// command.
    private static func normalizeCommand(_ text: String) -> String {
        var s = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,'\""))
        for filler in ["hey ", "ok ", "okay ", "hermes ", "please "] {
            while s.hasPrefix(filler) {
                s = String(s.dropFirst(filler.count))
            }
        }
        return s.split(separator: " ").joined(separator: " ")
    }

    /// Phrases that start a navigation command. Order matters: longer, more
    /// specific phrases first so "go to" doesn't swallow "want to go to".
    static let navTriggers = [
        "how do i get to", "i want to go to", "take me to", "navigate to",
        "directions to", "drive me to", "walk me to", "go to",
    ]

    static let stopPhrases = [
        "stop navigation", "cancel navigation", "end navigation",
        "stop navigating", "stop the navigation",
    ]

    /// Phrases that request a definition. The captured tail is the subject.
    /// Order matters: longer, more specific phrases first so "what's a" doesn't
    /// match the 'a' in "what's an".
    static let defineTriggers = [
        "tell me about", "what is the", "what is an", "what's the",
        "what is a", "what's an", "what are", "what is", "what's a",
        "what's", "who is", "who was",
    ]

    /// Words that make "what is ..." a non-lookup (time, weather, etc.).
    private static let defineStopSubjects: Set<String> = [
        "it", "that", "this", "up", "the time", "time", "the weather",
        "the date", "today", "going on", "happening", "wrong", "left",
    ]

    static func detect(_ text: String) -> HermesIntent {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return .none }

        if stopPhrases.contains(where: { lowered.contains($0) }) {
            return .stopNavigation
        }

        // Whole-utterance match, so it runs before the substring-based
        // detectors below and can't be shadowed by them.
        if rememberCommands.contains(normalizeCommand(text)) {
            return .rememberPerson
        }

        if let nav = detectNavigate(lowered, original: text) {
            return nav
        }

        if let def = detectDefine(lowered, original: text) {
            return def
        }

        return .none
    }

    private static func detectNavigate(_ lowered: String, original: String) -> HermesIntent? {
        for trigger in navTriggers {
            guard let range = lowered.range(of: trigger) else { continue }
            var tail = extractTail(original, loweredMatchEnd: range.upperBound, lowered: lowered)
            guard !tail.isEmpty else { return nil }

            // Driving if the phrase mentions it (either the verb or a trailing
            // "driving"); strip a trailing mode word from the destination.
            var mode: TransportMode = .walking
            if trigger.contains("drive") { mode = .driving }
            let lowerTail = tail.lowercased()
            for word in [" driving", " by car", " walking", " on foot"] {
                if lowerTail.hasSuffix(word) {
                    if word.contains("driv") || word.contains("car") { mode = .driving }
                    tail = String(tail.dropLast(word.count)).trimmingCharacters(in: .whitespaces)
                }
            }
            return .navigate(destination: tail, mode: mode)
        }
        return nil
    }

    private static func detectDefine(_ lowered: String, original: String) -> HermesIntent? {
        for trigger in defineTriggers {
            // Anchor to the start so "so what is" style mid-sentence hits are
            // still fine, but the subject is what follows the trigger.
            guard let range = lowered.range(of: trigger) else { continue }
            let subject = extractTail(original, loweredMatchEnd: range.upperBound, lowered: lowered)
            guard !subject.isEmpty else { return nil }
            if defineStopSubjects.contains(subject.lowercased()) { return nil }
            return .define(subject: subject)
        }
        return nil
    }

    /// Return the original-cased substring after a match, trimmed of trailing
    /// punctuation. `loweredMatchEnd` is an index into `lowered`; map it to the
    /// same offset in `original` (same length, lowercasing is 1:1 here).
    private static func extractTail(
        _ original: String, loweredMatchEnd: String.Index, lowered: String
    ) -> String {
        let offset = lowered.distance(from: lowered.startIndex, to: loweredMatchEnd)
        guard offset <= original.count else { return "" }
        let start = original.index(original.startIndex, offsetBy: offset)
        return String(original[start...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
    }
}
