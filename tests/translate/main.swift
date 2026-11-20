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


// MARK: - Finger pointing

func joint(_ x: Double, _ y: Double, _ c: Double = 0.9) -> HandJoint {
    HandJoint(point: CGPoint(x: x, y: y), confidence: c)
}
/// Index finger straight up from (0.5, 0.8) to (0.5, 0.6).
func straightIndex() -> HandJoints {
    var j = HandJoints()
    j.indexMCP = joint(0.5, 0.8); j.indexPIP = joint(0.5, 0.7)
    j.indexDIP = joint(0.5, 0.65); j.indexTip = joint(0.5, 0.6)
    return j
}
func curlMiddle(_ j: inout HandJoints) {
    j.middleMCP = joint(0.55, 0.8); j.middlePIP = joint(0.55, 0.72)
    j.middleDIP = joint(0.56, 0.76); j.middleTip = joint(0.56, 0.8)
}
func straightenMiddle(_ j: inout HandJoints) {
    j.middleMCP = joint(0.55, 0.8); j.middlePIP = joint(0.55, 0.69)
    j.middleDIP = joint(0.55, 0.63); j.middleTip = joint(0.55, 0.58)
}

var pointHand = straightIndex(); curlMiddle(&pointHand)
let pointed = FingerPointer.pointing(from: pointHand, aspect: 1)
expect(pointed != nil, "straight index + curled middle is a point")
expect(pointed.map { abs($0.direction.dx) < 0.001 && abs($0.direction.dy + 1) < 0.001 } == true,
       "direction is a unit vector along the finger")
expect(pointed?.tip == CGPoint(x: 0.5, y: 0.6), "tip is the index tip")
expect(pointed.map { abs($0.probe.y - 0.54) < 0.001 } == true, "probe sits 0.06 past the tip")

var palm = straightIndex(); straightenMiddle(&palm)
expect(FingerPointer.pointing(from: palm, aspect: 1) == nil, "open palm / peace sign is not a point")

var fist = HandJoints()
fist.indexMCP = joint(0.5, 0.8); fist.indexPIP = joint(0.5, 0.72)
fist.indexDIP = joint(0.51, 0.76); fist.indexTip = joint(0.51, 0.8)
curlMiddle(&fist)
expect(FingerPointer.pointing(from: fist, aspect: 1) == nil, "a fist is not a point")

var unsure = pointHand; unsure.indexDIP = joint(0.5, 0.65, 0.4)
expect(FingerPointer.pointing(from: unsure, aspect: 1) == nil, "a low-confidence index joint is not a point")
expect(FingerPointer.pointing(from: straightIndex(), aspect: 1) != nil, "middle finger not found still points")
expect(FingerPointer.pointing(from: HandJoints(), aspect: 1) == nil, "no joints, no point")

// A middle finger seen at low confidence is "not confidently found".
var faintMiddle = straightIndex(); straightenMiddle(&faintMiddle)
faintMiddle.middleTip = joint(0.55, 0.58, 0.2)
expect(FingerPointer.pointing(from: faintMiddle, aspect: 1) != nil, "an unsure middle finger does not veto the point")

// Target choice. `up` points straight up from (0.5, 0.6); probe (0.5, 0.54).
let up = Pointing(tip: CGPoint(x: 0.5, y: 0.6), direction: CGVector(dx: 0, dy: -1))
let small = CGRect(x: 0.45, y: 0.5, width: 0.1, height: 0.1)
let around = CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.3)
expect(FingerPointer.target(for: up, boxes: [small]) == .box(0), "probe inside a box picks it")
expect(FingerPointer.target(for: up, boxes: [around, small]) == .box(1), "nested boxes: the smaller wins")
let table = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
expect(FingerPointer.target(for: up, boxes: [table]) == .region(FingerPointer.region(for: up)),
       "a box over 0.35 of the frame is never a finger target")
expect(FingerPointer.target(for: up, boxes: [table, small]) == .box(1), "the thing on the table still wins")
let ahead = CGRect(x: 0.45, y: 0.3, width: 0.1, height: 0.1)      // entered at 0.2
let further = CGRect(x: 0.45, y: 0.27, width: 0.1, height: 0.02)  // entered at 0.31
expect(FingerPointer.target(for: up, boxes: [further, ahead]) == .box(1), "the ray takes the box it enters first")
let tooFar = CGRect(x: 0.45, y: 0.05, width: 0.1, height: 0.1)    // entered at 0.45
expect(FingerPointer.target(for: up, boxes: [tooFar]) == .region(FingerPointer.region(for: up)),
       "a box beyond reach is not a target")
let aside = CGRect(x: 0.7, y: 0.3, width: 0.1, height: 0.1)
expect(FingerPointer.target(for: up, boxes: [aside]) == .region(FingerPointer.region(for: up)),
       "a box off the ray is not a target")
expect(FingerPointer.target(for: up, boxes: []) == .region(FingerPointer.region(for: up)), "no boxes -> region")

let region = FingerPointer.region(for: up)
expect(abs(region.width - 0.4) < 0.001 && abs(region.height - 0.4) < 0.001, "region is 0.4 square")
expect(abs(region.midX - 0.5) < 0.001 && abs(region.midY - 0.45) < 0.001, "region is centred 0.15 past the tip")
expect(region.contains(up.tip), "the region includes the fingertip")
let corner = Pointing(tip: CGPoint(x: 0.05, y: 0.05), direction: CGVector(dx: -0.7071, dy: -0.7071))
let clamped = FingerPointer.region(for: corner)
expect(clamped.minX >= 0 && clamped.minY >= 0 && clamped.maxX <= 1 && clamped.maxY <= 1
       && abs(clamped.width - 0.4) < 0.001, "region is clamped inside the frame at full size")


// MARK: - Point hold

let spot = CGPoint(x: 0.5, y: 0.5)
var hold = PointHold()
expect(hold.update(probe: spot, at: 0) == .init(progress: 0, fired: false), "hold starts at zero")
expect(abs(hold.update(probe: spot, at: 0.5).progress - 0.5) < 0.001, "progress grows with time held")
expect(hold.update(probe: CGPoint(x: 0.52, y: 0.5), at: 0.9).fired == false, "not yet at 0.9 s")
expect(hold.update(probe: spot, at: 1.0) == .init(progress: 1, fired: true), "fires at 1.0 s held")
expect(hold.update(probe: spot, at: 1.1).fired == false, "does not fire again while still")
expect(hold.update(probe: spot, at: 5.0).fired == false, "a finger resting for seconds fires once")
expect(hold.update(probe: CGPoint(x: 0.58, y: 0.5), at: 5.1).fired == false, "a small move does not re-arm")
expect(hold.update(probe: CGPoint(x: 0.58, y: 0.5), at: 6.5).fired == false, "still spent after a small move")
let elsewhere = CGPoint(x: 0.7, y: 0.5)
expect(hold.update(probe: elsewhere, at: 7.0).fired == false, "first sample away: not re-armed yet")
expect(hold.update(probe: elsewhere, at: 7.3) == .init(progress: 0, fired: false), "staying 0.12 away for 0.3 s re-arms")
expect(hold.update(probe: elsewhere, at: 8.3).fired, "and the new place fires after its own hold")

var moving = PointHold()
_ = moving.update(probe: spot, at: 0)
_ = moving.update(probe: spot, at: 0.8)
expect(moving.update(probe: CGPoint(x: 0.6, y: 0.5), at: 0.9).progress == 0, "moving before firing restarts the hold")
expect(moving.update(probe: CGPoint(x: 0.6, y: 0.5), at: 1.5).fired == false, "the restart costs a full hold")
expect(moving.update(probe: CGPoint(x: 0.6, y: 0.5), at: 1.9).fired, "fires 1.0 s after the restart")

var flicker = PointHold()
_ = flicker.update(probe: spot, at: 0)
_ = flicker.update(probe: spot, at: 0.5)
_ = flicker.update(probe: nil, at: 0.6)
expect(flicker.update(probe: spot, at: 0.7).progress > 0.6, "a 0.2 s dropout keeps the hold")
_ = flicker.update(probe: nil, at: 0.75)
_ = flicker.update(probe: nil, at: 1.15)
expect(flicker.update(probe: spot, at: 1.2).progress == 0, "a 0.4 s dropout restarts it")
expect(flicker.update(probe: nil, at: 1.3).fired == false, "nothing fires with no finger")

var lost = PointHold()
_ = lost.update(probe: spot, at: 0)
expect(lost.update(probe: spot, at: 1.0).fired, "lost: first fire")
_ = lost.update(probe: nil, at: 1.5)
expect(lost.update(probe: spot, at: 1.6).fired == false, "hand gone 0.6 s: still spent on return")
_ = lost.update(probe: spot, at: 3.0)
_ = lost.update(probe: nil, at: 3.1)
_ = lost.update(probe: nil, at: 4.1)
expect(lost.update(probe: spot, at: 4.2).progress == 0, "hand gone 1.0 s re-arms the same place")
expect(lost.update(probe: spot, at: 5.2).fired, "and it fires again")

var blocked = PointHold()
_ = blocked.update(probe: spot, at: 0)
expect(blocked.update(probe: spot, at: 1.0).fired, "blocked: first fire")
blocked.restart()
expect(blocked.update(probe: spot, at: 1.1).progress == 0, "restart() un-spends the hold")
expect(blocked.update(probe: spot, at: 2.1).fired, "a blocked hold fires again from the same place")

var forgotten = PointHold()
_ = forgotten.update(probe: spot, at: 0)
_ = forgotten.update(probe: spot, at: 0.9)
forgotten.reset()
expect(forgotten.update(probe: spot, at: 1.0).fired == false, "reset() forgets a hold in progress")


// MARK: - Phrases

expect(TranslatePhrases.all.count == 6, "six phrases")
expect(Set(TranslatePhrases.all.map(\.id)).count == 6, "phrase ids unique")
expect(TranslatePhrases.all.map(\.english) == [
    "What is this?", "How much is this?", "I'd like this one",
    "Too expensive", "Can it be cheaper?", "No, thank you",
], "phrases in the order the design gives")
for phrase in TranslatePhrases.all {
    expect(TranslatePhrases.term(for: phrase, in: .english) == nil, "\(phrase.id): no button in English mode")
    for lang in [TranslateLanguage.french, .chinese, .spanish] {
        let term = TranslatePhrases.term(for: phrase, in: lang)
        expect(term.map { !$0.word.isEmpty && $0.english == phrase.english && $0.language == lang } == true,
               "\(phrase.id)/\(lang) has a phrase")
        expect((term?.romanized?.isEmpty == false) == lang.needsRomanization,
               "\(phrase.id)/\(lang) pinyin only where the script needs it")
    }
}
let howMuch = TranslatePhrases.all[1]
expect(TranslatePhrases.term(for: howMuch, in: .chinese)?.word == "这个多少钱？", "how much, in Chinese")
expect(TranslatePhrases.term(for: howMuch, in: .chinese)?.romanized == "zhège duōshao qián", "how much, pinyin")

expect(TranslatePrompt.system(for: .chinese, pointing: false) == TranslatePrompt.system(for: .chinese),
       "the tap prompt is unchanged")
let pointingPrompt = TranslatePrompt.system(for: .chinese, pointing: true)
expect(pointingPrompt.lowercased().contains("finger"), "the pointing prompt mentions the finger")
expect(pointingPrompt.contains(#"{"none":true}"#), "the pointing prompt keeps the nothing-recognisable reply")
expect(!TranslatePrompt.system(for: .chinese).lowercased().contains("finger"), "the tap prompt does not mention a finger")


// MARK: - Review fixes: unintended sends

// One stray pose frame (another hand, a jumping fingertip) must not
// re-arm a spent hold - the same thing would be sent again.
var glitch = PointHold()
_ = glitch.update(probe: spot, at: 0)
expect(glitch.update(probe: spot, at: 1.0).fired, "glitch: first fire")
_ = glitch.update(probe: CGPoint(x: 0.9, y: 0.1), at: 1.1)
var refired = false
for step in 2...40 { refired = glitch.update(probe: spot, at: 1.0 + Double(step) * 0.1).fired || refired }
expect(!refired, "one outlier frame does not re-arm a spent hold")

// A tap while pointing sends the finger's target itself; the hold must
// not send it a second time.
var tappedHold = PointHold()
_ = tappedHold.update(probe: spot, at: 0)
_ = tappedHold.update(probe: spot, at: 0.5)
tappedHold.spend(at: spot)
var firedAfterTap = false
for step in 6...40 { firedAfterTap = tappedHold.update(probe: spot, at: Double(step) * 0.1).fired || firedAfterTap }
expect(!firedAfterTap, "spend(at:) stops the hold firing for the same spot")
expect(tappedHold.update(probe: elsewhere, at: 4.1).fired == false, "spent by tap: away, not yet re-armed")
_ = tappedHold.update(probe: elsewhere, at: 4.4)
expect(tappedHold.update(probe: elsewhere, at: 5.4).fired, "spent by tap: a new place still fires")

// The middle finger vetoes loosely: an open hand must not be a point
// just because one joint was unsure or the finger was relaxed.
var relaxed = straightIndex()
relaxed.middleMCP = joint(0.55, 0.8); relaxed.middlePIP = joint(0.55, 0.71)
relaxed.middleDIP = joint(0.60, 0.65); relaxed.middleTip = joint(0.67, 0.63)
expect(FingerPointer.pointing(from: relaxed, aspect: 1) == nil, "a relaxed, curved middle finger is still an open hand")
var hazyPalm = straightIndex(); straightenMiddle(&hazyPalm)
hazyPalm.middlePIP = joint(0.55, 0.69, 0.45)
expect(FingerPointer.pointing(from: hazyPalm, aspect: 1) == nil, "one unsure middle joint does not turn a palm into a point")
var halfSure = straightIndex(); straightenMiddle(&halfSure)
halfSure.middleTip = joint(0.55, 0.58, 0.4)
expect(FingerPointer.pointing(from: halfSure, aspect: 1) == nil, "a half-sure extended middle finger still vetoes")

if failures > 0 { print("\n\(failures) FAILURES"); exit(1) }
print("\nAll translate tests passed")
