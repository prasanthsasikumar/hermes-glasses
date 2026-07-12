//
// Standalone tests for the AIProvider layer — no XCTest target in this
// project, so these run via swiftc. Build command (all provider sources
// + this file):
//   xcrun swiftc \
//     HermesGlasses/Services/Providers/AIProvider.swift \
//     HermesGlasses/Services/Providers/AnthropicProvider.swift \
//     HermesGlasses/Services/Providers/OpenAICompatibleProvider.swift \
//     HermesGlasses/Services/Providers/GeminiProvider.swift \
//     tests/providers/main.swift -o /tmp/provider-tests && /tmp/provider-tests
//
import Foundation

var failures = 0
func expect(_ c: Bool, _ label: String) {
    if c { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}
// Decode a URLRequest body back into a dictionary for assertions.
func bodyJSON(_ req: URLRequest) -> [String: Any] {
    guard let d = req.httpBody,
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    else { return [:] }
    return j
}

// ── Registry ────────────────────────────────────────────────────────────
expectEqual(AIProviderRegistry.provider(id: "anthropic").id, "anthropic", "registry anthropic")
expectEqual(AIProviderRegistry.provider(id: "openai").id, "openai", "registry openai")
expectEqual(AIProviderRegistry.provider(id: "gemini").id, "gemini", "registry gemini")
expectEqual(AIProviderRegistry.provider(id: "ollama").id, "ollama", "registry ollama")
expectEqual(AIProviderRegistry.provider(id: "nope").id, "anthropic", "registry unknown falls back to anthropic")
expectEqual(AIProviderRegistry.all.count, 4, "four built-in providers")

// Turn Codable round-trips
let t = Turn(role: "user", text: "hi")
let td = try! JSONEncoder().encode(t)
expectEqual(try! JSONDecoder().decode(Turn.self, from: td), t, "Turn codable round-trip")

// ── AnthropicProvider ───────────────────────────────────────────────────
do {
    let p = AnthropicProvider()
    expectEqual(p.id, "anthropic", "anthropic id")
    expect(p.requiresKey, "anthropic requires key")
    expect(!p.allowsCustomBaseURL, "anthropic no custom base url")

    let req = AIRequest(
        systemPrompt: "SYS", contextLine: "ctx", history: [Turn(role: "user", text: "prev")],
        userText: "hello", imageJPEG: Data([0xFF, 0xD8]), model: "claude-opus-4-8",
        baseURL: p.defaultBaseURL, apiKey: "sk-ant-xyz")
    let ur = try! p.buildRequest(req)
    expectEqual(ur.url!.absoluteString, "https://api.anthropic.com/v1/messages", "anthropic url")
    expectEqual(ur.value(forHTTPHeaderField: "x-api-key"), "sk-ant-xyz", "anthropic x-api-key")
    expectEqual(ur.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01", "anthropic version header")
    let body = bodyJSON(ur)
    expectEqual(body["model"] as? String, "claude-opus-4-8", "anthropic model in body")
    let sys = body["system"] as? [[String: Any]] ?? []
    expectEqual(sys.count, 2, "anthropic system has persona + context blocks")
    expect((sys.first?["cache_control"] as? [String: Any]) != nil, "anthropic persona block cached")
    let msgs = body["messages"] as? [[String: Any]] ?? []
    expectEqual(msgs.count, 2, "anthropic history + new user msg")
    let last = msgs.last?["content"] as? [[String: Any]] ?? []
    expect(last.contains { $0["type"] as? String == "image" }, "anthropic image block present")

    // parse success
    let ok = "{\"content\":[{\"type\":\"text\",\"text\":\"hi there\"}]}".data(using: .utf8)!
    expectEqual(try! p.parseReply(ok, status: 200), "hi there", "anthropic parse success")
    // parse 401
    let err = "{\"error\":{\"message\":\"bad key\"}}".data(using: .utf8)!
    do { _ = try p.parseReply(err, status: 401); expect(false, "anthropic 401 throws") }
    catch { expect(true, "anthropic 401 throws") }

    // missing key
    let noKey = AIRequest(systemPrompt: "S", contextLine: nil, history: [], userText: "x",
                          imageJPEG: nil, model: "m", baseURL: p.defaultBaseURL, apiKey: nil)
    do { _ = try p.buildRequest(noKey); expect(false, "anthropic missing key throws") }
    catch { expect(true, "anthropic missing key throws") }
}

if failures > 0 { print("\(failures) test(s) FAILED"); exit(1) }
print("All provider tests passed")
