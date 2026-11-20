//
// ObjectVocabulary.swift
//
// Detector label -> word, for the Translate app's instant path. The data
// lives in ObjectVocabularyTable.swift; this is only the lookup.
//
// A label can be deliberately SILENT in a language: where no single word
// is safe for everything the label covers, saying nothing beats saying a
// confident wrong word. `entry` distinguishes silent from missing so the
// tests can require that nothing is ever simply forgotten.
//
// Foundation only; tested in tests/translate/.
//

import Foundation

enum ObjectVocabulary {
    enum Entry: Equatable {
        case word(String, romanized: String?)
        case silent
    }

    /// Every label the bundled yolo11n model can emit, in model order.
    static let labels: [String] = ObjectVocabularyTable.rows.map(\.label)

    /// Labels never spoken on the instant path. `person`: a street would
    /// otherwise be a stream of "personne".
    static let skippedLabels: Set<String> = ["person"]

    private static let byLabel: [String: ObjectVocabularyTable.Row] =
        Dictionary(uniqueKeysWithValues: ObjectVocabularyTable.rows.map { ($0.label, $0) })

    /// nil = the label is not in the table at all.
    static func entry(for label: String, in language: TranslateLanguage) -> Entry? {
        guard let row = byLabel[label] else { return nil }
        switch language {
        case .english:
            return .word(row.english, romanized: nil)
        case .french:
            return row.fr.map { .word($0, romanized: nil) } ?? .silent
        case .spanish:
            return row.es.map { .word($0, romanized: nil) } ?? .silent
        case .chinese:
            guard let zh = row.zh, let pinyin = row.pinyin else { return .silent }
            return .word(zh, romanized: pinyin)
        }
    }

    /// The word to speak, or nil for an unknown, silent or skipped label.
    static func term(for label: String, in language: TranslateLanguage) -> TranslatedTerm? {
        guard !skippedLabels.contains(label),
              let row = byLabel[label],
              case .word(let word, let romanized)? = entry(for: label, in: language)
        else { return nil }
        return TranslatedTerm(
            word: word, romanized: romanized, english: row.english, language: language
        )
    }
}
