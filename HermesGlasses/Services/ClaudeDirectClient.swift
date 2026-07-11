//
// ClaudeDirectClient.swift
//
// Standalone brain: the app calls the Claude Messages API directly —
// no bridge, no server, works anywhere the phone has internet.
// Same-day conversation history lives on-device; glasses photos attach
// as native image blocks.
//

import Foundation
import os

/// Claude models selectable for direct mode
enum ClaudeModel: String, CaseIterable {
    case opus = "claude-opus-4-8"
    case sonnet = "claude-sonnet-5"
    case haiku = "claude-haiku-4-5"

    var label: String {
        switch self {
        case .opus: return "Opus 4.8 — smartest"
        case .sonnet: return "Sonnet 5 — balanced"
        case .haiku: return "Haiku 4.5 — fastest"
        }
    }
}

enum ClaudeDirectError: LocalizedError {
    case missingKey
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Claude API key set. Add one in Settings."
        case .apiError(let message):
            return message
        }
    }
}

final class ClaudeDirectClient: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.flowsxr.hermes-glasses", category: "claude")

    /// User-selectable model (Settings → Assistant → Model)
    static var model: String {
        UserDefaults.standard.string(forKey: "claude_direct_model") ?? ClaudeModel.opus.rawValue
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxHistoryMessages = 40
    private static let historyKey = "claude_direct_history"
    private static let historyDateKey = "claude_direct_history_date"

    private static let systemPrompt = """
        You are a voice assistant running on the user's smart glasses. Your \
        answers are spoken aloud: keep them to 1-3 conversational sentences \
        unless the user asks for detail. The user may reference things they \
        see; photos from the glasses camera may be attached to queries. Be \
        direct, natural, and helpful.
        """

    // MARK: - Keychain (API key)

    private static let keychainAccount = "anthropic_api_key"

    static func storeAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            return nil
        }
        return key
    }

    static var hasAPIKey: Bool { loadAPIKey() != nil }

    // MARK: - Same-day history (text-only, mirrors the bridge's semantics)

    private struct Turn: Codable {
        let role: String
        let text: String
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func loadHistory() -> [Turn] {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: historyDateKey) == todayString(),
              let data = defaults.data(forKey: historyKey),
              let turns = try? JSONDecoder().decode([Turn].self, from: data) else {
            return []
        }
        return turns
    }

    private static func storeHistory(_ turns: [Turn]) {
        let capped = turns.count > maxHistoryMessages
            ? Array(turns.suffix(maxHistoryMessages)) : turns
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(capped), forKey: historyKey)
        defaults.set(todayString(), forKey: historyDateKey)
    }

    static func clearHistory() {
        UserDefaults.standard.removeObject(forKey: historyKey)
        UserDefaults.standard.removeObject(forKey: historyDateKey)
    }

    // MARK: - Ask

    /// Send a query (with optional glasses photo) and return the reply text.
    func ask(_ text: String, photoJPEG: Data?, contextLine: String? = nil) async throws -> String {
        guard let apiKey = Self.loadAPIKey() else {
            throw ClaudeDirectError.missingKey
        }

        let history = Self.loadHistory()

        var messages: [[String: Any]] = history.map {
            ["role": $0.role, "content": $0.text]
        }
        var userContent: [[String: Any]] = []
        if let photoJPEG {
            userContent.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": photoJPEG.base64EncodedString(),
                ],
            ])
        }
        userContent.append(["type": "text", "text": text])
        messages.append(["role": "user", "content": userContent])

        // Persona block stays FIRST and cached (stable prefix); the
        // context block is per-query and never cached.
        var system: [[String: Any]] = [[
            "type": "text",
            "text": Self.systemPrompt,
            "cache_control": ["type": "ephemeral"],
        ]]
        if let contextLine {
            system.append([
                "type": "text",
                "text": "Current user context: \(contextLine)",
            ])
        }
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 1024,
            "system": system,
            "messages": messages,
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.info("Claude direct request (\(messages.count) messages, photo=\(photoJPEG != nil))")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeDirectError.apiError("No response from the Claude API.")
        }
        guard http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
            logger.error("Claude API \(http.statusCode): \(detail ?? "?", privacy: .public)")
            if http.statusCode == 401 {
                throw ClaudeDirectError.apiError("The Claude API key was rejected. Check it in Settings.")
            }
            throw ClaudeDirectError.apiError(detail ?? "Claude API error \(http.statusCode).")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let reply = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else {
            throw ClaudeDirectError.apiError("Unexpected response from the Claude API.")
        }

        // Persist text-only turns (photos would bloat storage and re-bill)
        var newHistory = history
        newHistory.append(Turn(role: "user", text: text))
        newHistory.append(Turn(role: "assistant", text: reply))
        Self.storeHistory(newHistory)

        return reply
    }
}

// MARK: - Visual query detection (ported from the bridge)

enum VisualQueryDetector {
    /// Explicit phrases that always need a fresh photo
    private static let keywords = [
        "look at", "looking at", "see this", "what am i seeing",
        "what is this", "what's this", "read this", "in front of me",
        "take a picture", "take a photo", "snap a photo", "use the camera",
        "through the camera",
    ]

    /// "this X"/"that X"/"the one" — visual unless the noun is abstract
    private static let deicticPattern = try! NSRegularExpression(
        pattern: "\\b(this|that|these|those)\\s+([a-z]+)|\\bthe one\\b",
        options: [.caseInsensitive]
    )

    private static let stopNouns: Set<String> = [
        "morning", "afternoon", "evening", "night", "time", "day", "week",
        "month", "year", "moment", "question", "answer", "idea", "point",
        "case", "way", "reason", "sense", "stuff", "conversation", "chat",
        "session", "app", "voice", "sound", "response", "reply", "much",
        "long", "short", "many", "far", "fast", "slow", "bit", "lot",
        "kind", "sort", "type",
        // Auxiliary/copular verbs: "this is a test", "that was fun" are
        // not about anything visible
        "is", "was", "are", "were", "be", "being", "been", "isn", "wasn",
        "will", "would", "can", "could", "should", "might", "may", "must",
        "does", "did", "done", "has", "had", "have", "gets", "got", "goes",
        "went", "seems", "means", "works", "sounds", "feels", "happened",
    ]

    static let photoMemoryWindow: TimeInterval = 120

    /// Mirrors the bridge's should_capture_photo()
    static func shouldCapturePhoto(
        _ text: String,
        lastPhotoAt: Date?,
        now: Date = Date()
    ) -> Bool {
        let lowered = text.lowercased()
        if keywords.contains(where: { lowered.contains($0) }) {
            return true
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = deicticPattern.matches(in: text, range: range)
        for match in matches {
            var isVisual = false
            if match.numberOfRanges > 2,
               let nounRange = Range(match.range(at: 2), in: text) {
                let noun = text[nounRange].lowercased()
                isVisual = !noun.isEmpty && !stopNouns.contains(noun)
            } else {
                isVisual = true  // "the one"
            }
            if isVisual {
                guard let lastPhotoAt else { return true }
                return now.timeIntervalSince(lastPhotoAt) > photoMemoryWindow
            }
        }
        return false
    }
}
