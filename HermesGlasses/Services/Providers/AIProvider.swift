//
// AIProvider.swift
//
// The provider seam for "Direct (your API)" mode. Pure Foundation so it
// compiles under the standalone swiftc test harness - no os/SwiftUI here.
//

import Foundation

/// One conversation turn (text-only; mirrors the bridge's same-day memory).
struct Turn: Codable, Equatable {
    let role: String   // "user" | "assistant"
    let text: String
}

/// A model a provider offers in the picker (users can also type a custom id).
struct ModelOption: Equatable {
    let id: String     // wire value, e.g. "claude-opus-4-8"
    let label: String  // UI label, e.g. "Opus 4.8 - smartest"
}

/// Everything needed to shape one request, provider-agnostic.
struct AIRequest {
    let systemPrompt: String
    let contextLine: String?
    let history: [Turn]
    let userText: String
    let imageJPEG: Data?
    let model: String
    let baseURL: String
    let apiKey: String?
    /// Ask the provider to consult the web (a server-side search tool).
    /// Only Anthropic honours this today; other providers ignore it and
    /// answer from model knowledge.
    var webSearch = false
    /// How many web searches the provider may run before answering. Only
    /// Anthropic honours this (it is the tool's `max_uses`). The Lookup
    /// face path asks for more than the default so a person search has
    /// room to disambiguate namesakes.
    var webSearchMaxUses = 3
    /// Output token limit. Nil keeps each provider's chat default (1024 for
    /// Anthropic/OpenAI, the model default for Gemini). Build Check's
    /// procedure split asks for more: a long document's step list is JSON.
    var maxTokens: Int? = nil
    /// Ask for the reply as server-sent events, so its first sentence can
    /// be spoken while the rest is still being written. Only honoured by
    /// providers whose `supportsStreaming` is true.
    var stream = false
}

enum AIProviderError: LocalizedError, Equatable {
    case missingKey
    case http(status: Int, message: String)
    case badResponse(String)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No API key set for this provider. Add one in Settings."
        case .http(_, let message): return message
        case .badResponse(let message): return message
        case .invalidURL(let url): return "Invalid API base URL: \(url)"
        }
    }
}

/// A chat+vision backend the phone can call directly.
protocol AIProvider {
    var id: String { get }
    var displayName: String { get }
    var defaultBaseURL: String { get }
    var allowsCustomBaseURL: Bool { get }
    var requiresKey: Bool { get }
    var supportsVision: Bool { get }
    var curatedModels: [ModelOption] { get }

    func buildRequest(_ req: AIRequest) throws -> URLRequest
    func parseReply(_ data: Data, status: Int) throws -> String
}

extension AIProvider {
    /// Providers stream only when they say so; everyone else answers whole.
    var supportsStreaming: Bool { false }

    /// The text carried by one SSE `data:` payload, or nil when the event
    /// carries none (pings, block starts, usage).
    func streamDelta(_ payload: String) -> String? { nil }

    /// System prompt with the per-query context appended (used by providers
    /// that have no separate system-block mechanism).
    func systemText(_ req: AIRequest) -> String {
        guard let ctx = req.contextLine else { return req.systemPrompt }
        return req.systemPrompt + "\n\nCurrent user context: \(ctx)"
    }
}

/// The built-in providers, in display order.
enum AIProviderRegistry {
    static let all: [AIProvider] = [
        AnthropicProvider(),
        OpenAICompatibleProvider.openAI,
        GeminiProvider(),
        OpenAICompatibleProvider.ollama,
    ]

    static func provider(id: String) -> AIProvider {
        all.first { $0.id == id } ?? AnthropicProvider()
    }
}
