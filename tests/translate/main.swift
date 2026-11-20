//
// Standalone tests for the Translate app's pure logic. No XCTest target,
// so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Translate/*.swift \
//     tests/translate/main.swift -o /tmp/translate-tests && /tmp/translate-tests
//
// New assertions go ABOVE the final print/exit lines.
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}

// MARK: - Languages and vocabulary

expect(ObjectVocabulary.labels.count == 80, "80 labels")
expect(Set(ObjectVocabulary.labels).count == 80, "labels unique")
var tableProblems = 0
for lang in TranslateLanguage.allCases {
    for label in ObjectVocabulary.labels {
        switch ObjectVocabulary.entry(for: label, in: lang) {
        case nil:
            tableProblems += 1; print("FAIL \(label)/\(lang) missing")
        case .silent:
            break
        case .word(let w, let r):
            if w.trimmingCharacters(in: .whitespaces).isEmpty {
                tableProblems += 1; print("FAIL \(label)/\(lang) empty")
            }
            if (r != nil) != lang.needsRomanization {
                tableProblems += 1; print("FAIL \(label)/\(lang) romanization iff needed")
            }
            if let r, r.trimmingCharacters(in: .whitespaces).isEmpty {
                tableProblems += 1; print("FAIL \(label)/\(lang) empty romanization")
            }
        }
    }
}
expect(tableProblems == 0, "every label is translated or deliberately silent in every language")
expect(ObjectVocabulary.term(for: "banana", in: .french)?.word == "banane", "banana fr")
expect(ObjectVocabulary.term(for: "banana", in: .chinese) ==
       TranslatedTerm(word: "香蕉", romanized: "xiāngjiāo", english: "banana", language: .chinese), "banana zh")
expect(ObjectVocabulary.term(for: "banana", in: .spanish)?.word == "plátano", "banana es")
expect(ObjectVocabulary.term(for: "banana", in: .english)?.word == "banana", "banana en")
expect(ObjectVocabulary.term(for: "person", in: .french) == nil, "person skipped")
expect(ObjectVocabulary.entry(for: "person", in: .french) != nil, "person still in table")
expect(ObjectVocabulary.term(for: "unicorn", in: .french) == nil, "unknown label")
expect(ObjectVocabulary.entry(for: "unicorn", in: .french) == nil, "unknown label has no entry")
expect(TranslateLanguage.allCases.map(\.voiceCode) == ["en-US", "fr-FR", "zh-CN", "es-ES"], "voice codes")
expect(TranslateLanguage.defaultLanguage == .french, "default is French")
expect(TranslateLanguage.allCases.filter(\.needsRomanization) == [.chinese], "only Chinese is romanized")

// MARK: - Speak policy

let fr = ObjectVocabulary.term(for: "banana", in: .french)!
let zh = ObjectVocabulary.term(for: "banana", in: .chinese)!
let chair = ObjectVocabulary.term(for: "chair", in: .french)!

var p = TranslateSpeakPolicy()
expect(!p.shouldSpeak(fr, confidence: 0.59, at: 0), "below floor is silent")
expect(p.shouldSpeak(fr, confidence: 0.6, at: 0), "at floor speaks")
expect(!p.shouldSpeak(fr, confidence: 0.9, at: 7.9), "same word inside 8 s")
expect(p.shouldSpeak(chair, confidence: 0.9, at: 1), "different word inside 8 s")
expect(p.shouldSpeak(zh, confidence: 0.9, at: 2), "same object, other language")
expect(p.shouldSpeak(fr, confidence: 0.9, at: 8.0), "same word at 8 s")
var q = TranslateSpeakPolicy()
expect(!q.shouldSpeak(fr, confidence: 0.3, at: 0), "rejected")
expect(q.shouldSpeak(fr, confidence: 0.9, at: 1), "a rejection does not start the quiet period")
q.noteSpoken(chair, at: 10)
expect(!q.shouldSpeak(chair, confidence: 0.9, at: 12), "AI-spoken word is quiet too")
expect(q.shouldSpeak(chair, confidence: 0.9, at: 18), "AI-spoken word speaks again after 8 s")

// MARK: - AI reply parser

func parse(_ s: String, _ l: TranslateLanguage = .chinese) -> TranslateAnswer {
    TranslateAnswerParser.parse(s, language: l)
}
let zhTerm = TranslatedTerm(word: "订书机", romanized: "dìngshūjī", english: "stapler", language: .chinese)
expect(parse(#"{"english":"stapler","word":"订书机","romanized":"dìngshūjī"}"#) == .term(zhTerm), "plain json")
expect(parse("```json\n{\"english\":\"stapler\",\"word\":\"订书机\",\"romanized\":\"dìngshūjī\"}\n```") == .term(zhTerm), "code fence")
expect(parse("Sure! {\"english\":\"stapler\",\"word\":\"订书机\",\"romanized\":\"dìngshūjī\"} Hope that helps.") == .term(zhTerm), "prose around")
expect(parse(#"{"english":" stapler ","word":" agrafeuse ","romanized":"x"}"#, .french) ==
       .term(TranslatedTerm(word: "agrafeuse", romanized: nil, english: "stapler", language: .french)),
       "trimmed; romanized dropped for Latin script")
expect(parse(#"{"english":"stapler","word":"订书机"}"#) ==
       .term(TranslatedTerm(word: "订书机", romanized: nil, english: "stapler", language: .chinese)),
       "missing pinyin tolerated")
expect(parse(#"{"english":"stapler","word":"订书机","romanized":"  "}"#) ==
       .term(TranslatedTerm(word: "订书机", romanized: nil, english: "stapler", language: .chinese)),
       "blank pinyin becomes nil")
expect(parse(#"{"none":true}"#) == .nothing, "none")
expect(parse(#"{"english":"stapler","word":""}"#) == .malformed, "empty word")
expect(parse(#"{"english":"","word":"agrafeuse"}"#, .french) == .malformed, "empty english")
expect(parse(#"{"english":"x","word":"C'est une agrafeuse posée sur un bureau en bois clair."}"#, .french) == .malformed,
       "a sentence is not a word")
expect(parse(#"{"english":"stapler","word":42}"#) == .malformed, "non-string word")
expect(parse("I can't tell what that is.") == .malformed, "no json")
expect(parse("{not json}") == .malformed, "broken json")
expect(parse("") == .malformed, "empty")
expect(parse(#"{"english":"pair of scissors","word":"paire de ciseaux"}"#, .french) ==
       .term(TranslatedTerm(word: "paire de ciseaux", romanized: nil, english: "pair of scissors", language: .french)),
       "multi-word noun accepted")
expect(TranslatePrompt.system(for: .french).contains("French"), "prompt names the language")
expect(TranslatePrompt.system(for: .chinese).contains("pinyin"), "Chinese prompt asks for pinyin")
expect(!TranslatePrompt.system(for: .french).contains("pinyin"), "French prompt does not")

// MARK: - Final review fixes

// A short sentence or a placeholder in `word` is not a name.
expect(parse(#"{"english":"unknown","word":"Je ne sais pas."}"#, .french) == .malformed, "short sentence with a full stop")
expect(parse(#"{"english":"banana","word":"It is a banana"}"#, .english) == .malformed, "four-word phrase is prose")
expect(parse(#"{"english":"N/A","word":"N/A"}"#, .french) == .malformed, "placeholder N/A")
expect(parse(#"{"english":"unknown","word":"inconnu"}"#, .french) == .malformed, "placeholder english 'unknown'")
expect(parse(#"{"english":"cup","word":"这是什么？"}"#) == .malformed, "Chinese question mark")
expect(parse(#"{"english":"cup","word":"杯子","romanized":"This is the pinyin for the word cup, which is bēizi."}"#) ==
       .term(TranslatedTerm(word: "杯子", romanized: nil, english: "cup", language: .chinese)),
       "a sentence in romanized is dropped, the word kept")
expect(parse(#"{"english":"fire hydrant","word":"boca de incendios"}"#, .spanish) ==
       .term(TranslatedTerm(word: "boca de incendios", romanized: nil, english: "fire hydrant", language: .spanish)),
       "three-word noun still accepted")

// The policy says WHY it is silent: an uncertain snap is retried, a quiet one is not.
var v = TranslateSpeakPolicy()
expect(v.verdict(fr, confidence: 0.58, at: 0) == .uncertain, "low confidence is uncertain")
expect(v.verdict(fr, confidence: 0.8, at: 1) == .speak, "then speaks once confident")
expect(v.verdict(fr, confidence: 0.8, at: 2) == .quiet, "then quiet")
expect(v.verdict(fr, confidence: 0.3, at: 3) == .uncertain, "uncertain wins over quiet - nothing to repeat")

// Only labels with a word in this language may hold the reticle.
expect(ObjectVocabulary.isSpeakable("banana", in: .french), "banana holds the reticle")
expect(!ObjectVocabulary.isSpeakable("person", in: .french), "person never holds the reticle")
expect(!ObjectVocabulary.isSpeakable("sink", in: .french), "a silent label does not hold the reticle")
expect(!ObjectVocabulary.isSpeakable("unicorn", in: .french), "unknown label")

// Table corrections from review.
expect(ObjectVocabulary.entry(for: "sports ball", in: .french) == .silent, "sports ball fr: ballon is wrong for a tennis ball")
expect(ObjectVocabulary.term(for: "donut", in: .french)?.word == "donut", "donut fr is not a beignet")
expect(ObjectVocabulary.entry(for: "sink", in: .chinese) == .silent, "sink is silent in every translated language")

if failures > 0 { print("\n\(failures) FAILURES"); exit(1) }
print("\nAll translate tests passed")
