//
// TranslateAnswerParser.swift
//
// The AI half of the Translate app: what is asked, and how the answer is
// read. The model is asked for ONE small JSON object, and anything that
// is not that object is `.malformed` - never spoken. A model that replies
// with a sentence must not have the sentence read out as if it were the
// word for the thing in front of you.
//
// Foundation only; tested in tests/translate/.
//

import Foundation

enum TranslateAnswer: Equatable {
    case term(TranslatedTerm)
    /// The model looked and found nothing it could name.
    case nothing
    /// Not the JSON that was asked for.
    case malformed
}

enum TranslatePrompt {
    static func system(for language: TranslateLanguage) -> String {
        var lines = [
            "You name objects for a language learner.",
            "Look at the photo and identify the single main object at its centre.",
            "Reply with ONE JSON object and nothing else:",
        ]
        if language.needsRomanization {
            lines.append(#"{"english":"<name in English>","word":"<name in \#(language.englishName)>","romanized":"<tone-marked pinyin>"}"#)
        } else {
            lines.append(#"{"english":"<name in English>","word":"<name in \#(language.englishName)>"}"#)
        }
        lines.append(contentsOf: [
            "Both names are a bare, everyday noun: no article, no adjectives unless they are part of the name, no sentence.",
            #"If you cannot tell what the object is, reply exactly {"none":true}."#,
        ])
        return lines.joined(separator: "\n")
    }

    static let userText = "What is this object?"
}

enum TranslateAnswerParser {
    /// Longer than this is prose, not a name.
    static let maxWordLength = 40
    /// "boca de incendios" is three words; "It is a banana" is four.
    static let maxWords = 3
    private static let sentenceMarks = CharacterSet(charactersIn: ".!?:;。！？：；\n")
    private static let placeholders: Set<String> = [
        "n/a", "na", "none", "null", "unknown", "nothing", "?", "-",
    ]

    static func parse(_ reply: String, language: TranslateLanguage) -> TranslateAnswer {
        guard let object = firstJSONObject(in: reply) else { return .malformed }
        if object["none"] as? Bool == true { return .nothing }

        guard let word = clean(object["word"]),
              let english = clean(object["english"]),
              isName(word), isName(english)
        else { return .malformed }

        // A reading that turned into a sentence is dropped; the word stands.
        let romanized = language.needsRomanization
            ? clean(object["romanized"]).flatMap { isReading($0) ? $0 : nil }
            : nil
        return .term(TranslatedTerm(
            word: word, romanized: romanized, english: english, language: language
        ))
    }

    /// A name, not a sentence: short, few words, no sentence punctuation,
    /// and not a model's way of saying "I don't know".
    private static func isName(_ s: String) -> Bool {
        s.count <= maxWordLength
            && s.rangeOfCharacter(from: sentenceMarks) == nil
            && s.split(whereSeparator: \.isWhitespace).count <= maxWords
            && !placeholders.contains(s.lowercased())
    }

    private static func isReading(_ s: String) -> Bool {
        s.count <= maxWordLength && s.rangeOfCharacter(from: sentenceMarks) == nil
    }

    /// A trimmed, non-empty string, or nil.
    private static func clean(_ value: Any?) -> String? {
        guard let s = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }
        return s
    }

    /// The first `{…}` in the text that parses as a JSON object. Models
    /// wrap replies in code fences or a polite sentence; this reads past
    /// both without trusting either.
    private static func firstJSONObject(in text: String) -> [String: Any]? {
        guard let open = text.firstIndex(of: "{") else { return nil }
        var end = open
        while let close = text[text.index(after: end)...].firstIndex(of: "}") {
            if let data = String(text[open...close]).data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            end = close
        }
        return nil
    }
}
