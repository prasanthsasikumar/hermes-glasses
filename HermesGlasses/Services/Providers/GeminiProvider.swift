//
// GeminiProvider.swift — Google Generative Language generateContent.
// Vision via inline_data parts; system via systemInstruction. Pure Foundation.
//

import Foundation

struct GeminiProvider: AIProvider {
    let id = "gemini"
    let displayName = "Gemini"
    let defaultBaseURL = "https://generativelanguage.googleapis.com"
    let allowsCustomBaseURL = false
    let requiresKey = true
    let supportsVision = true
    let curatedModels = [
        ModelOption(id: "gemini-2.5-flash", label: "2.5 Flash — fast"),
        ModelOption(id: "gemini-2.5-pro", label: "2.5 Pro — smartest"),
    ]

    func buildRequest(_ req: AIRequest) throws -> URLRequest {
        guard let key = req.apiKey, !key.isEmpty else { throw AIProviderError.missingKey }

        var contents: [[String: Any]] = req.history.map {
            ["role": $0.role == "assistant" ? "model" : "user",
             "parts": [["text": $0.text]]]
        }
        var parts: [[String: Any]] = []
        if let jpeg = req.imageJPEG {
            parts.append(["inline_data": ["mime_type": "image/jpeg",
                                          "data": jpeg.base64EncodedString()]])
        }
        parts.append(["text": req.userText])
        contents.append(["role": "user", "parts": parts])

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemText(req)]]],
            "contents": contents,
        ]
        let urlString = "\(req.baseURL)/v1beta/models/\(req.model):generateContent?key=\(key)"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseReply(_ data: Data, status: Int) throws -> String {
        guard status == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
            throw AIProviderError.http(status: status, message: msg ?? "API error \(status).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let reply = parts.first(where: { $0["text"] != nil })?["text"] as? String
        else { throw AIProviderError.badResponse("Unexpected response from the API.") }
        return reply
    }
}
