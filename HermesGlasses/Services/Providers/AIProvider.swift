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
