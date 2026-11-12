//
// Standalone tests for the machine guide's pure logic. No XCTest target, so
// build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Manuals/MachineManual.swift \
//     HermesGlasses/Services/Manuals/ManualStore.swift \
//     HermesGlasses/Services/Manuals/MachineGuideLogic.swift \
//     HermesGlasses/Services/BuildCheck/BuildCheckJSON.swift \
//     tests/manuals/main.swift -o /tmp/manuals-tests && /tmp/manuals-tests
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}

let a = MachineManual(name: "Machine A", profile: "Blue inline four, plate reads MA-100.")
let b = MachineManual(name: "Machine B")
let c = MachineManual(name: "The K9 Pump")
let manuals = [a, b, c]
let candidates = MachineIdentifier.candidates(manuals)

// MARK: - Identification

expectEqual(candidates.map(\.label), ["A", "B", "C"], "candidates are lettered in order")
expectEqual(MachineIdentifier.candidates(Array(repeating: a, count: 30)).count,
            MachineIdentifier.maxCandidates, "candidate list is capped")

expectEqual(MachineIdentifier.outcome(
    fromReply: #"{"machine":"B","confidence":0.9,"runner_up":"none","evidence":"plate"}"#,
    candidates: candidates), .match(b.id), "confident letter is a match")
expectEqual(MachineIdentifier.outcome(
    fromReply: "```json\n{\"machine\": \"a\", \"confidence\": \"0.8\"}\n```",
    candidates: candidates), .match(a.id), "fenced reply, lowercase letter, string confidence")
expectEqual(MachineIdentifier.outcome(
    fromReply: #"{"machine":"The K9 Pump","confidence":0.95}"#,
    candidates: candidates), .match(c.id), "a name instead of a letter still resolves")
expectEqual(MachineIdentifier.outcome(
    fromReply: #"{"machine":"A","confidence":0.4,"runner_up":"C"}"#,
    candidates: candidates), .unsure([a.id, c.id]), "low confidence asks, best guess first")
expectEqual(MachineIdentifier.outcome(
    fromReply: #"{"machine":"A","confidence":0.59}"#,
    candidates: candidates), .unsure([a.id]), "just under the threshold is unsure")
expectEqual(MachineIdentifier.outcome(
    fromReply: #"{"machine":"A","confidence":0.6}"#,
    candidates: candidates), .match(a.id), "exactly the threshold is accepted")
expectEqual(MachineIdentifier.outcome(
    fromReply: #"{"machine":"none","confidence":0.9,"runner_up":"none"}"#,
    candidates: candidates), .unsure([]), "a confident 'none' is not a match")
expectEqual(MachineIdentifier.outcome(
    fromReply: #"{"machine":"A"}"#, candidates: candidates),
    .unsure([a.id]), "missing confidence is never trusted")
expectEqual(MachineIdentifier.outcome(
    fromReply: #"{"machine":"Z","confidence":1.0}"#, candidates: candidates),
    .unsure([]), "an unknown letter matches nothing")
expectEqual(MachineIdentifier.outcome(
    fromReply: #"{"machine":"A","confidence":0.3,"runner_up":"A"}"#, candidates: candidates),
    .unsure([a.id]), "a repeated guess is listed once")
expectEqual(MachineIdentifier.outcome(fromReply: "I think it's machine A.", candidates: candidates),
            .unsure([]), "prose with no JSON is unsure")

let prompt = MachineIdentifier.userPrompt(candidates: candidates, hasReferenceTiles: true)
expect(prompt.contains("A: Machine A - Blue inline four"), "prompt carries name and profile")
expect(prompt.contains("B: Machine B\n"), "a manual with no profile is listed by name alone")
expect(prompt.contains("NOW"), "prompt explains the sheet when there are reference tiles")
expect(!MachineIdentifier.userPrompt(candidates: candidates, hasReferenceTiles: false).contains("NOW"),
       "no tiles, no talk of panels")

// MARK: - Picking a manual by name

expectEqual(ManualNameMatcher.explicitSelection("This is machine B.", manuals: manuals), b.id, "this is <name>")
expectEqual(ManualNameMatcher.explicitSelection("It's the K9 pump", manuals: manuals), c.id, "it's the <name>")
expectEqual(ManualNameMatcher.explicitSelection("use the K9 pump manual", manuals: manuals), c.id, "use the <name> manual")
expectEqual(ManualNameMatcher.explicitSelection("Hey Hermes, switch to Machine A", manuals: manuals), a.id, "filler + switch to")
expectEqual(ManualNameMatcher.explicitSelection("this is a different machine", manuals: manuals), nil,
            "'this is a different machine' names nothing")
expectEqual(ManualNameMatcher.explicitSelection("this is machine B right", manuals: manuals), nil,
            "extra words after the name are not an explicit switch")
expectEqual(ManualNameMatcher.explicitSelection("is machine B the heavy one", manuals: manuals), nil,
            "a question mentioning a name is not a switch")
expectEqual(ManualNameMatcher.explicitSelection("this is", manuals: manuals), nil, "lead-in alone")

expectEqual(ManualNameMatcher.answer("machine b", manuals: manuals), b.id, "bare name")
expectEqual(ManualNameMatcher.answer("B", manuals: manuals), b.id, "the one distinguishing word")
expectEqual(ManualNameMatcher.answer("the pump", manuals: manuals), c.id, "a word only one manual has")
expectEqual(ManualNameMatcher.answer("I think it's machine A actually", manuals: manuals), a.id,
            "full name inside a longer sentence")
expectEqual(ManualNameMatcher.answer("machine", manuals: manuals), nil, "a word two manuals share picks neither")
expectEqual(ManualNameMatcher.answer("A or B", manuals: manuals), nil, "two different manuals named")
expectEqual(ManualNameMatcher.answer("I have no idea what it is", manuals: manuals), nil, "no name")
expectEqual(ManualNameMatcher.answer("", manuals: manuals), nil, "empty")

let nested = [MachineManual(name: "Pump"), MachineManual(name: "Pump Mark Two")]
expectEqual(ManualNameMatcher.answer("pump mark two", manuals: nested), nested[1].id, "the longest contained name wins")
expectEqual(ManualNameMatcher.answer("pump", manuals: nested), nested[0].id, "the short name still selectable")

// MARK: - Excerpts

let small = ManualExcerpt.context(pages: ["Intro", "", "Fit the gasket."], query: "gasket")
expect(small.isComplete, "a manual that fits is sent whole")
expectEqual(small.includedPages, [1, 3], "blank pages are skipped but numbering is kept")
expect(small.text.contains("[Page 3]\nFit the gasket."), "pages are labelled")
expectEqual(small.totalPages, 2, "total counts pages with text")

let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 40)   // ~1080 chars
var big = (1...20).map { "Section \($0). " + filler }
big[11] = "Torque the cylinder head bolts to 90 newton metres. " + filler   // page 12
let cut = ManualExcerpt.context(pages: big, query: "What's the torque for the head bolts?", budget: 5000)
expect(!cut.isComplete, "an over-budget manual is excerpted")
expect(cut.includedPages.contains(12), "the page that answers the question is in")
expect(cut.includedPages.contains(13), "and the page after it")
expect(cut.includedPages.contains(1), "the opening page is kept when cheap")
expect(cut.text.count <= 5000, "the excerpt respects the budget (\(cut.text.count))")
expectEqual(cut.includedPages, cut.includedPages.sorted(), "pages stay in reading order")
expectEqual(cut.totalPages, 20, "total is reported for the prompt")

let noHit = ManualExcerpt.context(pages: big, query: "next", budget: 4000)
expectEqual(noHit.includedPages, [1, 2, 3], "no matching words → the start of the manual")

let huge = ManualExcerpt.context(pages: [String(repeating: "x", count: 10_000)], query: "anything", budget: 500)
expectEqual(huge.text.count, 500, "a single page over budget is truncated, not dropped")
expectEqual(ManualExcerpt.context(pages: [], query: "q").text, "", "no pages, no text")

var spam = (1...10).map { _ in filler }
spam[2] = String(repeating: "bolt ", count: 200)                     // parts table
spam[6] = "Fit the bolt through the bracket and tighten the bolt. " + "bracket tighten " + filler
let ranked = ManualExcerpt.context(pages: spam, query: "tighten the bracket bolt", budget: 2600)
expect(ranked.includedPages.contains(7), "term caps keep a word-spam page from outranking the real one")

// MARK: - Prompts

let whole = ManualExcerpt.context(pages: ["Step 1. Fit the sump."], query: "")
let system = MachineGuidePrompt.system(machineName: "Machine A", context: whole)
expect(system.contains("Machine A"), "system prompt names the machine")
expect(system.contains("Step 1. Fit the sump."), "system prompt carries the manual")
expect(system.contains("full manual"), "says when the manual is complete")
expect(MachineGuidePrompt.system(machineName: "Machine A", context: cut).contains("of 20"),
       "says when it is an excerpt, and of how many pages")

expect(MachineGuidePrompt.wantsPhoto("is this right"), "pointing question wants a photo")
expect(MachineGuidePrompt.wantsPhoto("Where does it go?"), "'where' wants a photo")
expect(!MachineGuidePrompt.wantsPhoto("what's the torque for the head bolts"), "a lookup doesn't")
expect(!MachineGuidePrompt.wantsPhoto("next"), "'next' doesn't")
expect(!MachineGuidePrompt.wantsPhoto("thistle"), "matches whole words only")

let parsed = MachineGuidePrompt.profile(fromAIReply: #"Sure: {"name":"K9 Pump","profile":"Red housing."}"#)
expectEqual(parsed?.name, "K9 Pump", "profile reply: name")
expectEqual(parsed?.profile, "Red housing.", "profile reply: profile")
expect(MachineGuidePrompt.profile(fromAIReply: "no json here") == nil, "unreadable profile reply")
expect(MachineGuidePrompt.profile(fromAIReply: #"{"name":"","profile":""}"#) == nil, "empty profile reply")
expectEqual(MachineGuidePrompt.profile(fromAIReply: #"{"profile":"Grey."}"#)?.name, nil, "profile without a name")
let longDoc = String(repeating: "m", count: 50_000)
expect(MachineGuidePrompt.profileUserPrompt(document: longDoc, filename: "a.pdf").count < 14_000,
       "the profile call reads only the opening")

expectEqual(MachineGuidePrompt.spokenList(["A"]), "A", "list of one")
expectEqual(MachineGuidePrompt.spokenList(["A", "B", "C"]), "A, B or C", "list of three")
expectEqual(MachineGuidePrompt.spokenList(["1", "2", "3", "4", "5", "6", "7"]), "1, 2, 3, 4 or 5", "list is capped at five")
expect(MachineGuidePrompt.unsure(guesses: ["Machine A"], allNames: ["Machine A", "Machine B"]).contains("might be Machine A"),
       "unsure line offers the guess")
expect(MachineGuidePrompt.unsure(guesses: [], allNames: ["Machine A", "Machine B"]).contains("Machine A or Machine B"),
       "unsure line with no guess lists what it has")

// MARK: - Model + store

let legacy = try! JSONDecoder().decode(MachineManual.self, from: Data(#"{"name":"Old"}"#.utf8))
expectEqual(legacy.name, "Old", "decodes with only a name")
expectEqual(legacy.referencePhotoFilenames, [], "missing keys default")
expectEqual(MachineManual(name: "  ").displayName, "Unnamed machine", "blank name has a display name")

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manuals-tests-\(UUID().uuidString)")
let store = ManualStore(directory: dir)
expect(store.all().isEmpty, "new store is empty")
var zed = MachineManual(name: "Zed engine")
let photo = try! store.addPhoto(Data([1, 2, 3]))
let source = try! store.addSource(Data([4, 5]), fileExtension: "PDF")
zed.referencePhotoFilenames = [photo]
zed.sourceFilename = source
store.save(zed)
store.save(MachineManual(name: "alpha engine"))
try! store.savePages(["one", "two"], for: zed.id)
expectEqual(store.all().map(\.name), ["alpha engine", "Zed engine"], "listed alphabetically, case-insensitive")
expectEqual(store.pages(for: zed.id), ["one", "two"], "pages round-trip")
expectEqual(store.pages(for: UUID()), [], "unknown manual has no pages")
expect(source.hasSuffix(".pdf"), "source extension is lowercased")
zed.name = "Zed engine mk2"
store.save(zed)
expectEqual(store.all().count, 2, "saving an existing id replaces it")
expectEqual(store.manual(id: zed.id)?.name, "Zed engine mk2", "lookup by id sees the edit")
expectEqual(ManualStore(directory: dir).all().count, 2, "a second store reads the same index")
store.delete(id: zed.id)
expectEqual(store.all().map(\.name), ["alpha engine"], "delete removes the entry")
expect(!FileManager.default.fileExists(atPath: store.photoURL(photo).path), "delete removes its pictures")
expect(!FileManager.default.fileExists(atPath: store.sourceURL(source).path), "delete removes its source")
expectEqual(store.pages(for: zed.id), [], "delete removes its pages")
try? FileManager.default.removeItem(at: dir)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
