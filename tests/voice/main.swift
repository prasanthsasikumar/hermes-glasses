//
// Standalone tests for the voice pipeline's pure parts. No XCTest target,
// so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Voice/SentenceChunker.swift \
//     HermesGlasses/Services/Voice/ElevenLabsRequest.swift \
//     tests/voice/main.swift -o /tmp/voice-tests && /tmp/voice-tests
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

// MARK: - SentenceChunker

var c = SentenceChunker()
expectEqual(c.feed("This is Mach"), [], "half a sentence releases nothing")
expectEqual(c.feed("ine A. Fit the"), ["This is Machine A."], "the first sentence is released at once")
expectEqual(c.feed(" sump."), [], "a sentence end with nothing after it waits - it may be '2.5'")
expectEqual(c.flush(), ["Fit the sump."], "flush releases the tail")
expectEqual(c.flush(), [], "flush is empty afterwards")

var d = SentenceChunker()
expectEqual(d.feed("Okay. "), ["Okay."], "a very short first sentence still goes first")
let two = "Fit the gasket to the sump. Torque the bolts to 25 newton metres. "
expectEqual(d.feed(two), [], "later short sentences are held to be grouped")
let more = String(repeating: "Check the seal is seated all the way round. ", count: 3)
let grouped = d.feed(more)
expectEqual(grouped.count, 1, "…and released as one piece once long enough")
expect(grouped.first?.hasPrefix("Fit the gasket") == true, "grouped piece starts where the held text did")
expect((grouped.first?.count ?? 0) >= SentenceChunker.targetLength, "grouped piece reached the target length")
expect(grouped.first?.hasSuffix(".") == true, "grouped piece ends on a sentence end")

expectEqual(SentenceChunker.pieces(of: "Set the gap to 2.5 mm. Then refit."),
            ["Set the gap to 2.5 mm.", "Then refit."], "decimals don't split")
expectEqual(SentenceChunker.pieces(of: "Use firmware v1.2 only"), ["Use firmware v1.2 only"],
            "no sentence end → one piece")
expectEqual(SentenceChunker.pieces(of: "Is it seated? Yes! Good."), ["Is it seated?", "Yes! Good."],
            "question and exclamation marks end sentences")
expectEqual(SentenceChunker.pieces(of: "First line\nSecond line"), ["First line", "Second line"],
            "a line break ends a piece")
expectEqual(SentenceChunker.pieces(of: ""), [], "empty text")
expectEqual(SentenceChunker.pieces(of: "   \n  "), [], "whitespace only")
expectEqual(SentenceChunker.pieces(of: "One."), ["One."], "a single sentence")

let run = String(repeating: "and then the next part, ", count: 30)   // 720 chars, no sentence end
let cut = SentenceChunker.pieces(of: run)
expect(cut.count >= 2, "a long unpunctuated run is still cut (\(cut.count) pieces)")
expect(cut.allSatisfy { $0.count <= SentenceChunker.hardLimit }, "no piece exceeds the hard limit")
expect(cut[0].hasSuffix(","), "the cut lands on a clause mark")
let solid = String(repeating: "x", count: 700)
expect(SentenceChunker.pieces(of: solid).allSatisfy { $0.count <= SentenceChunker.hardLimit },
       "even text with no spaces is cut")
expectEqual(SentenceChunker.pieces(of: solid).joined(), solid, "…without losing a character")

let reply = "This is the K9 pump. Step one: fit the gasket. Step two: torque the six bolts to 25 newton metres in a cross pattern. Step three: check for leaks."
var streamed = SentenceChunker()
var out: [String] = []
for ch in reply { out += streamed.feed(String(ch)) }
out += streamed.flush()
expectEqual(out, SentenceChunker.pieces(of: reply), "character-by-character feeding matches one-shot")
expectEqual(out.joined(separator: " "), reply, "nothing is lost or reordered")
expectEqual(out.first, "This is the K9 pump.", "streamed: first sentence first")

// MARK: - ElevenLabsRequest

let request = try! ElevenLabsRequest.speech(text: "Hello there.", key: "sk_test", voiceID: "VOICE123")
expectEqual(request.url?.absoluteString,
            "https://api.elevenlabs.io/v1/text-to-speech/VOICE123?output_format=mp3_44100_128",
            "request URL carries the voice and format")
expectEqual(request.httpMethod, "POST", "POST")
expectEqual(request.value(forHTTPHeaderField: "xi-api-key"), "sk_test", "key goes in xi-api-key")
let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
expectEqual(body["text"] as? String, "Hello there.", "body carries the text")
expectEqual(body["model_id"] as? String, ElevenLabsRequest.model, "body carries the low-latency model")
expect((try? ElevenLabsRequest.speech(text: "x", key: "", voiceID: "V")) == nil, "an empty key is refused")
expect((try? ElevenLabsRequest.speech(text: "x", key: "k", voiceID: "")) == nil, "an empty voice is refused")
expect((try! ElevenLabsRequest.speech(text: "x", key: "k", voiceID: "a/b?c")).url!.absoluteString
        .contains("/text-to-speech/a%2Fb%3Fc?output_format="), "a strange voice id cannot break the URL")

expect(ElevenLabsRequest.isFatal(status: 401), "401 turns the voice off for the session")
expect(ElevenLabsRequest.isFatal(status: 403), "403 too")
expect(!ElevenLabsRequest.isFatal(status: 429), "429 is a blip - next sentence may work")
expect(!ElevenLabsRequest.isFatal(status: 500), "500 is a blip")
expectEqual(ElevenLabsRequest.message(status: 401, body: Data(#"{"detail":{"message":"Invalid API key"}}"#.utf8)),
            "Invalid API key", "error message from a detail object")
expectEqual(ElevenLabsRequest.message(status: 422, body: Data(#"{"detail":"Bad voice"}"#.utf8)),
            "Bad voice", "error message from a detail string")
expectEqual(ElevenLabsRequest.message(status: 500, body: Data()), "ElevenLabs error 500.", "no body → status")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
