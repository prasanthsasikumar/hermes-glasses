//
// AnthropicProvider.swift - Claude Messages API (system blocks + base64
// image blocks). Persona block stays first & cached; context is a second,
// uncached block. Pure Foundation.
//

import Foundation

struct AnthropicProvider: AIProvider {
    let id = "anthropic"
    let displayName = "Claude"
    let defaultBaseURL = "https://api.anthropic.com"
    let allowsCustomBaseURL = false
    let requiresKey = true
    let supportsVision = true
    let curatedModels = [
        ModelOption(id: "claude-opus-4-8", label: "Opus 4.8 - smartest"),
        ModelOption(id: "claude-sonnet-5", label: "Sonnet 5 - balanced"),
        ModelOption(id: "claude-haiku-4-5", label: "Haiku 4.5 - fastest"),
    ]

    func buildRequest(_ req: AIRequest) throws -> URLRequest {
        guard let key = req.apiKey, !key.isEmpty else { throw AIProviderError.missingKey }

        var messages: [[String: Any]] = req.history.map { ["role": $0.role, "content": $0.text] }
        var userContent: [[String: Any]] = []
        if let jpeg = req.imageJPEG {
            userContent.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg",
                           "data": jpeg.base64EncodedString()],
            ])
        }
        userContent.append(["type": "text", "text": req.userText])
        messages.append(["role": "user", "content": userContent])

        var system: [[String: Any]] = [[
            "type": "text", "text": req.systemPrompt,
            "cache_control": ["type": "ephemeral"],
        ]]
        if let ctx = req.contextLine {
            system.append(["type": "text", "text": "Current user context: \(ctx)"])
        }

        let body: [String: Any] = [
            "model": req.model, "max_tokens": 1024, "system": system, "messages": messages,
        ]
        guard let url = URL(string: req.baseURL + "/v1/messages") else {
            throw AIProviderError.invalidURL(req.baseURL + "/v1/messages")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseReply(_ data: Data, status: Int) throws -> String {
        guard status == 200 else {
            let msg = errorMessage(data)
            if status == 401 {
                throw AIProviderError.http(status: 401, message: "The API key was rejected. Check it in Settings.")
            }
            throw AIProviderError.http(status: status, message: msg ?? "API error \(status).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let reply = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw AIProviderError.badResponse("Unexpected response from the API.") }
        return reply
    }

    private func errorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any] else { return nil }
        return err["message"] as? String
    }
}
