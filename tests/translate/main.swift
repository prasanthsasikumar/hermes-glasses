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

if failures > 0 { print("\n\(failures) FAILURES"); exit(1) }
print("\nAll translate tests passed")
