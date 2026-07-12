//
// OpenAICompatibleProvider.swift — /v1/chat/completions. One shape serves
// OpenAI, Ollama, and OpenAI-style proxies (LM Studio, Groq, OpenRouter)
// via base-URL override. Pure Foundation.
//

import Foundation

struct OpenAICompatibleProvider: AIProvider {
    let id: String
    let displayName: String
    let defaultBaseURL: String
    let requiresKey: Bool
    let curatedModels: [ModelOption]
    var allowsCustomBaseURL: Bool { true }
    var supportsVision: Bool { true }

    static let openAI = OpenAICompatibleProvider(
        id: "openai", displayName: "OpenAI",
        defaultBaseURL: "https://api.openai.com", requiresKey: true,
        curatedModels: [
            ModelOption(id: "gpt-4o", label: "GPT-4o"),
            ModelOption(id: "gpt-4o-mini", label: "GPT-4o mini — fastest"),
        ])

    static let ollama = OpenAICompatibleProvider(
        id: "ollama", displayName: "Local (Ollama)",
        defaultBaseURL: "http://localhost:11434", requiresKey: false,
        curatedModels: [
            ModelOption(id: "llama3.2", label: "Llama 3.2"),
            ModelOption(id: "llava", label: "LLaVA — vision"),
        ])

    func buildRequest(_ req: AIRequest) throws -> URLRequest {
        if requiresKey, (req.apiKey ?? "").isEmpty { throw AIProviderError.missingKey }

        var messages: [[String: Any]] = [["role": "system", "content": systemText(req)]]
        messages += req.history.map { ["role": $0.role, "content": $0.text] }

        if let jpeg = req.imageJPEG {
            let dataURI = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
            messages.append(["role": "user", "content": [
                ["type": "text", "text": req.userText],
                ["type": "image_url", "image_url": ["url": dataURI]],
            ]])
        } else {
            messages.append(["role": "user", "content": req.userText])
        }

        let body: [String: Any] = ["model": req.model, "max_tokens": 1024, "messages": messages]
        guard let url = URL(string: req.baseURL + "/v1/chat/completions") else {
            throw AIProviderError.invalidURL(req.baseURL + "/v1/chat/completions")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = req.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseReply(_ data: Data, status: Int) throws -> String {
        guard status == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
            if status == 401 {
                throw AIProviderError.http(status: 401, message: "The API key was rejected. Check it in Settings.")
            }
            throw AIProviderError.http(status: status, message: msg ?? "API error \(status).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let reply = message["content"] as? String
        else { throw AIProviderError.badResponse("Unexpected response from the API.") }
        return reply
    }
}
