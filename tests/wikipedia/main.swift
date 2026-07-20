//
// swiftc HermesGlasses/Services/Navigation/WikipediaImageClient.swift \
//        tests/wikipedia/main.swift -o /tmp/wiki-tests && /tmp/wiki-tests
//
import Foundation

var failures = 0
func expect(_ c: Bool, _ label: String) {
    if c { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(String(describing: got))\n  want: \(String(describing: want))") }
}

// URL building: spaces -> underscores, percent-encoded, https REST summary.
let url = WikipediaImageClient.summaryURL(for: "Eiffel Tower")
expectEqual(url?.absoluteString,
            "https://en.wikipedia.org/api/rest_v1/page/summary/Eiffel_Tower",
            "summary url")
expect(WikipediaImageClient.summaryURL(for: "   ") == nil, "blank subject -> nil")
expectEqual(WikipediaImageClient.summaryURL(for: "AC/DC")?.absoluteString,
            "https://en.wikipedia.org/api/rest_v1/page/summary/AC%2FDC",
            "slash in title is escaped")

// Parsing: pick thumbnail.source; https only; nil when absent.
let withThumb = """
{"title":"Potato","thumbnail":{"source":"https://upload.wikimedia.org/x/Potato.jpg","width":320},
 "originalimage":{"source":"https://upload.wikimedia.org/x/Potato_full.jpg"}}
""".data(using: .utf8)!
expectEqual(WikipediaImageClient.parseImageURL(from: withThumb),
            "https://upload.wikimedia.org/x/Potato.jpg", "parse thumbnail source")

let noThumb = #"{"title":"Nothing"}"#.data(using: .utf8)!
expect(WikipediaImageClient.parseImageURL(from: noThumb) == nil, "no image -> nil")

let httpThumb = #"{"thumbnail":{"source":"http://insecure/x.jpg"}}"#.data(using: .utf8)!
expect(WikipediaImageClient.parseImageURL(from: httpThumb) == nil, "reject non-https")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
