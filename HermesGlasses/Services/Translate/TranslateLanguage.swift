//
// TranslateLanguage.swift
//
// The languages the Translate app can speak, and one translated word.
// Every language here has a built-in iPhone voice - that is the entry
// requirement, because Translate speaks offline and never uses ElevenLabs.
// Adding a language = one case here + one column in ObjectVocabularyTable.
//
// Foundation only; tested in tests/translate/.
//

import Foundation

enum TranslateLanguage: String, CaseIterable, Identifiable {
    case english, french, chinese, spanish

    var id: String { rawValue }

    /// The language's own name - what the picker and the lens label show.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .french: return "Français"
        case .chinese: return "中文"
        case .spanish: return "Español"
        }
    }

    /// Its name in English - what the AI prompt uses.
    var englishName: String {
        switch self {
        case .english: return "English"
        case .french: return "French"
        case .chinese: return "Chinese"
        case .spanish: return "Spanish"
        }
    }

    /// BCP-47 code handed to AVSpeechSynthesisVoice. Chinese is Mandarin,
    /// Spanish is Spain's - the table's word choices follow these.
    var voiceCode: String {
        switch self {
        case .english: return "en-US"
        case .french: return "fr-FR"
        case .chinese: return "zh-CN"
        case .spanish: return "es-ES"
        }
    }

    /// True when the script is not Latin and a reading helps (pinyin).
    var needsRomanization: Bool { self == .chinese }

    static let storageKey = "translate_language"
    static let defaultLanguage: TranslateLanguage = .french
}

/// One word, ready to show and speak.
struct TranslatedTerm: Equatable {
    /// In the target language's own script.
    let word: String
    /// Tone-marked pinyin for Chinese; nil for Latin-script languages.
    let romanized: String?
    let english: String
    let language: TranslateLanguage
}
