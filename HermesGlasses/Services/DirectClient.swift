//
// DirectClient.swift
//
// "Direct (your API)" mode: the phone calls the selected AI provider
// directly - no bridge. Provider, model, base URL and key come from
// UserDefaults/Keychain; same-day history and vision detection live here.
//

import Foundation
import os

final class DirectClient: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "direct")

    // MARK: - Provider selection (UserDefaults)

    static var providerID: String {
        UserDefaults.standard.string(forKey: "direct_provider_id") ?? "anthropic"
    }
    static var provider: AIProvider { AIProviderRegistry.provider(id: providerID) }

    static func model(for provider: AIProvider) -> String {
        let stored = UserDefaults.standard.string(forKey: "direct_model_\(provider.id)")
        if let stored, !stored.isEmpty { return stored }
        return provider.curatedModels.first?.id ?? ""
    }

    static func baseURL(for provider: AIProvider) -> String {
        let resolved: String
        if provider.allowsCustomBaseURL,
           let custom = UserDefaults.standard.string(forKey: "direct_base_url_\(provider.id)"),
           !custom.isEmpty {
            resolved = custom
        } else {
            resolved = provider.defaultBaseURL
        }
        // Trim a trailing "/" so "http://localhost:11434/" doesn't produce
        // a doubled slash when a path is appended (…//v1/...).
        if resolved.hasSuffix("/") {
            return String(resolved.dropLast())
        }
        return resolved
    }

    // MARK: - Keychain (per-provider API key)

    private static func account(_ providerID: String) -> String { "\(providerID)_api_key" }

    static func storeKey(_ key: String, for providerID: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(providerID),
        ]
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadKey(for providerID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(providerID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func hasKey(for providerID: String) -> Bool { loadKey(for: providerID) != nil }

    // MARK: - Same-day history (text-only, mirrors the bridge's semantics)

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

    /// Send a query (with optional glasses photo) to the selected provider.
    func ask(_ text: String, photoJPEG: Data?, contextLine: String? = nil) async throws -> String {
        let provider = Self.provider
        let key = Self.loadKey(for: provider.id)
        if provider.requiresKey, (key ?? "").isEmpty { throw AIProviderError.missingKey }

        let request = AIRequest(
            systemPrompt: Self.systemPrompt,
            contextLine: contextLine,
            history: Self.loadHistory(),
            userText: text,
            imageJPEG: provider.supportsVision ? photoJPEG : nil,
            model: Self.model(for: provider),
            baseURL: Self.baseURL(for: provider),
            apiKey: key)

        let urlRequest = try provider.buildRequest(request)
        logger.info("Direct request to \(provider.id, privacy: .public) (photo=\(photoJPEG != nil))")
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = try provider.parseReply(data, status: status)

        var newHistory = Self.loadHistory()
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

    /// "this X"/"that X"/"the one" - visual unless the noun is abstract
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
