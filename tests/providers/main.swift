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

if failures > 0 { print("\(failures) test(s) FAILED"); exit(1) }
print("All provider tests passed")
