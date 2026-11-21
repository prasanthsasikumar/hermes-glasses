//
// TranslatePhrases.swift
//
// A pocket phrasebook for the moment after "what is that called": six
// things to say to the person behind the counter. Bundled, offline, never
// sent to the AI - in places where the AI providers are unreachable this
// is the part of Translate that still works.
//
// Data only, like ObjectVocabularyTable, so it can be handed to a speaker.
// Written by the builder and NOT reviewed by a native speaker.
//
// Foundation only; tested in tests/translate/.
//

import Foundation

struct TranslatePhrase: Identifiable, Equatable {
    let id: String
    /// The button label, and the gloss under the phrase.
    let english: String
    let fr: String
    let zh: String
    let pinyin: String
    let es: String
}

enum TranslatePhrases {
    static let all: [TranslatePhrase] = [
        TranslatePhrase(id: "what", english: "What is this?",
                        fr: "Qu'est-ce que c'est ?",
                        zh: "这是什么？", pinyin: "zhè shì shénme",
                        es: "¿Qué es esto?"),
        TranslatePhrase(id: "price", english: "How much is this?",
                        fr: "C'est combien ?",
                        zh: "这个多少钱？", pinyin: "zhège duōshao qián",
                        es: "¿Cuánto cuesta?"),
        TranslatePhrase(id: "want", english: "I'd like this one",
                        fr: "Je voudrais celui-ci",
                        zh: "我要这个", pinyin: "wǒ yào zhège",
                        es: "Quiero este"),
        TranslatePhrase(id: "expensive", english: "Too expensive",
                        fr: "C'est trop cher",
                        zh: "太贵了", pinyin: "tài guì le",
                        es: "Es demasiado caro"),
        TranslatePhrase(id: "cheaper", english: "Can it be cheaper?",
                        fr: "Vous pouvez faire un prix ?",
                        zh: "可以便宜一点吗？", pinyin: "kěyǐ piányi yìdiǎn ma",
                        es: "¿Me hace un descuento?"),
        TranslatePhrase(id: "no", english: "No, thank you",
                        fr: "Non merci",
                        zh: "不要，谢谢", pinyin: "búyào, xièxie",
                        es: "No, gracias"),
    ]

    /// The phrase ready to show and speak. Nil in English: there is
    /// nothing to translate, so no button is offered.
    static func term(for phrase: TranslatePhrase, in language: TranslateLanguage) -> TranslatedTerm? {
        switch language {
        case .english:
            return nil
        case .french:
            return TranslatedTerm(word: phrase.fr, romanized: nil, english: phrase.english, language: language)
        case .chinese:
            return TranslatedTerm(word: phrase.zh, romanized: phrase.pinyin, english: phrase.english, language: language)
        case .spanish:
            return TranslatedTerm(word: phrase.es, romanized: nil, english: phrase.english, language: language)
        }
    }
}
