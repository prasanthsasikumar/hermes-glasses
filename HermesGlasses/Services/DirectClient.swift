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
    private static let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "direct"
    )

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

    /// Returns false when the Keychain refused the write - the caller must
    /// not tell the user the key is stored on the strength of having asked.
    @discardableResult
    static func storeKey(_ key: String, for providerID: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(providerID),
        ]
        SecItemDelete(query as CFDictionary)
        // An empty key is a deletion, and the delete above already did it
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return true }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Keychain store failed for \(providerID, privacy: .public): OSStatus \(status)")
            return false
        }
        return true
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

    /// Cached: building a DateFormatter costs more than the comparison it
    /// feeds, and this runs on every ask. Formatting on a shared instance is
    /// thread-safe.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func todayString() -> String {
        dayFormatter.string(from: Date())
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
        Self.logger.info("Direct request to \(provider.id, privacy: .public) (photo=\(photoJPEG != nil))")
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = try provider.parseReply(data, status: status)

        var newHistory = Self.loadHistory()
        newHistory.append(Turn(role: "user", text: text))
        newHistory.append(Turn(role: "assistant", text: reply))
        Self.storeHistory(newHistory)
        return reply
    }

    // MARK: - Streaming

    /// The reply to `request` as it is written. A provider that streams
    /// yields many small pieces; one that doesn't yields the whole reply as
    /// a single piece - callers treat both the same. `onComplete` gets the
    /// full text once, only on success.
    private func deltas(
        for request: AIRequest, provider: AIProvider, timeout: TimeInterval,
        onComplete: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = request
                    request.stream = provider.supportsStreaming
                    var urlRequest = try provider.buildRequest(request)
                    urlRequest.timeoutInterval = timeout
                    let started = Date()
                    var full = ""

                    if provider.supportsStreaming {
                        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard status == 200 else {
                            var body = Data()
                            for try await byte in bytes { body.append(byte) }
                            _ = try provider.parseReply(body, status: status)   // throws the provider's message
                            throw AIProviderError.http(status: status, message: "API error \(status).")
                        }
                        var sawFirst = false
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            guard let text = provider.streamDelta(payload), !text.isEmpty else { continue }
                            if !sawFirst {
                                sawFirst = true
                                let ms = Int(Date().timeIntervalSince(started) * 1000)
                                Self.logger.info("First words from \(provider.id, privacy: .public) after \(ms) ms")
                            }
                            full += text
                            continuation.yield(text)
                        }
                        guard !full.isEmpty else {
                            throw AIProviderError.badResponse("The API sent an empty reply.")
                        }
                    } else {
                        let (data, response) = try await URLSession.shared.data(for: urlRequest)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        full = try provider.parseReply(data, status: status)
                        continuation.yield(full)
                    }
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    Self.logger.info("Reply from \(provider.id, privacy: .public) complete after \(ms) ms (\(full.count) chars)")
                    onComplete?(full)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `ask`, streamed: same request, same history bookkeeping (written
    /// once the reply is complete), but the words arrive as they are made.
    func askStream(_ text: String, photoJPEG: Data?, contextLine: String? = nil) -> AsyncThrowingStream<String, Error> {
        let provider = Self.provider
        let key = Self.loadKey(for: provider.id)
        if provider.requiresKey, (key ?? "").isEmpty {
            return AsyncThrowingStream { $0.finish(throwing: AIProviderError.missingKey) }
        }
        let request = AIRequest(
            systemPrompt: Self.systemPrompt,
            contextLine: contextLine,
            history: Self.loadHistory(),
            userText: text,
            imageJPEG: provider.supportsVision ? photoJPEG : nil,
            model: Self.model(for: provider),
            baseURL: Self.baseURL(for: provider),
            apiKey: key)
        Self.logger.info("Direct stream to \(provider.id, privacy: .public) (photo=\(photoJPEG != nil))")
        return deltas(for: request, provider: provider, timeout: 60) { reply in
            var history = Self.loadHistory()
            history.append(Turn(role: "user", text: text))
            history.append(Turn(role: "assistant", text: reply))
            Self.storeHistory(history)
        }
    }

    /// `askWithHistory`, streamed. Reads and writes nothing stored.
    func askWithHistoryStream(
        systemPrompt: String, history: [Turn], userText: String,
        photoJPEG: Data?, timeout: TimeInterval = 60
    ) -> AsyncThrowingStream<String, Error> {
        let provider = Self.provider
        let key = Self.loadKey(for: provider.id)
        if provider.requiresKey, (key ?? "").isEmpty {
            return AsyncThrowingStream { $0.finish(throwing: AIProviderError.missingKey) }
        }
        let request = AIRequest(
            systemPrompt: systemPrompt,
            contextLine: nil,
            history: history,
            userText: userText,
            imageJPEG: provider.supportsVision ? photoJPEG : nil,
            model: Self.model(for: provider),
            baseURL: Self.baseURL(for: provider),
            apiKey: key)
        return deltas(for: request, provider: provider, timeout: timeout)
    }

    /// One question that must NOT touch conversation memory. `ask` splices
    /// its query and reply into the stored same-day history; a badge photo
    /// has no business in the user's chat. Reads nothing, writes nothing.
    /// `webSearch` asks the provider to consult the web (Anthropic's
    /// server-side tool; other providers ignore it and answer from model
    /// knowledge) - used by the Lookup app to identify a person from their
    /// face, not just read what is in front of them.
    func askOneShot(
        systemPrompt: String, userText: String, photoJPEG: Data,
        webSearch: Bool = false, webSearchMaxUses: Int = 3,
        timeout: TimeInterval = 20
    ) async throws -> String {
        let provider = Self.provider
        guard provider.supportsVision else {
            throw AIProviderError.badResponse(
                "\(provider.displayName) cannot read images."
            )
        }
        let key = Self.loadKey(for: provider.id)
        if provider.requiresKey, (key ?? "").isEmpty { throw AIProviderError.missingKey }

        let request = AIRequest(
            systemPrompt: systemPrompt,
            contextLine: nil,
            history: [],
            userText: userText,
            imageJPEG: photoJPEG,
            model: Self.model(for: provider),
            baseURL: Self.baseURL(for: provider),
            apiKey: key,
            webSearch: webSearch,
            webSearchMaxUses: webSearchMaxUses)

        var urlRequest = try provider.buildRequest(request)
        urlRequest.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try provider.parseReply(data, status: status)
    }

    /// A conversation whose memory the CALLER owns. Like `askOneShot` it
    /// reads and writes nothing stored - the machine guide keeps its own
    /// short history per machine, so an afternoon of torque questions never
    /// lands in the user's chat memory and the chat never leaks into the
    /// guide. The system prompt carries the manual; on Anthropic that block
    /// is cached, so follow-up questions about one machine are cheap.
    func askWithHistory(
        systemPrompt: String, history: [Turn], userText: String,
        photoJPEG: Data?, maxTokens: Int? = nil, timeout: TimeInterval = 60
    ) async throws -> String {
        let provider = Self.provider
        let key = Self.loadKey(for: provider.id)
        if provider.requiresKey, (key ?? "").isEmpty { throw AIProviderError.missingKey }

        var request = AIRequest(
            systemPrompt: systemPrompt,
            contextLine: nil,
            history: history,
            userText: userText,
            imageJPEG: provider.supportsVision ? photoJPEG : nil,
            model: Self.model(for: provider),
            baseURL: Self.baseURL(for: provider),
            apiKey: key)
        request.maxTokens = maxTokens

        var urlRequest = try provider.buildRequest(request)
        urlRequest.timeoutInterval = timeout
        Self.logger.info("History request to \(provider.id, privacy: .public) (turns=\(history.count), photo=\(photoJPEG != nil))")
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try provider.parseReply(data, status: status)
    }

    /// Text-only sibling of `askOneShot`, for questions that carry no photo
    /// and must not touch conversation memory - the Lookup app sends a
    /// badge NAME here, never the person's picture. `webSearch` asks the
    /// provider to consult the web (Anthropic's server-side tool; other
    /// providers ignore it and answer from model knowledge).
    func askOneShotText(
        systemPrompt: String, userText: String, webSearch: Bool = false,
        maxTokens: Int? = nil, timeout: TimeInterval = 30
    ) async throws -> String {
        let provider = Self.provider
        let key = Self.loadKey(for: provider.id)
        if provider.requiresKey, (key ?? "").isEmpty { throw AIProviderError.missingKey }

        var request = AIRequest(
            systemPrompt: systemPrompt,
            contextLine: nil,
            history: [],
            userText: userText,
            imageJPEG: nil,
            model: Self.model(for: provider),
            baseURL: Self.baseURL(for: provider),
            apiKey: key,
            webSearch: webSearch)
        request.maxTokens = maxTokens

        var urlRequest = try provider.buildRequest(request)
        urlRequest.timeoutInterval = timeout
        Self.logger.info("One-shot text request to \(provider.id, privacy: .public) (webSearch=\(webSearch))")
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try provider.parseReply(data, status: status)
    }
}

// MARK: - Visual query detection (ported from the bridge)

enum VisualQueryDetector {
    /// Explicit phrases that always need a fresh photo
    static let keywords = [
        "look at", "looking at", "see this", "what am i seeing",
        "what is this", "what's this", "read this", "in front of me",
        "take a picture", "take a photo", "snap a photo", "use the camera",
        "through the camera",
    ]

    /// "this X"/"that X"/"the one" - visual unless the noun is abstract.
    /// Optional rather than `try!`: the pattern is a literal, so the only way
    /// it fails is a typo in an edit, and losing deictic detection beats
    /// trapping every query on the voice path.
    private static let deicticPattern = try? NSRegularExpression(
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
        guard let deicticPattern else { return false }
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
