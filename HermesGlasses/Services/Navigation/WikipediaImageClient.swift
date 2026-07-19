//
// WikipediaImageClient.swift
//
// Fetches a topic's lead image from the Wikimedia REST summary endpoint for
// the definition feature. Returns an https thumbnail URL or nil (no page, no
// image, or a non-https source). No API key required.
//

import Foundation

enum WikipediaImageClient {
    /// REST summary endpoint. Spaces become underscores (Wikipedia titles),
    /// then the title is percent-encoded for the path.
    static func summaryURL(for subject: String) -> URL? {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let title = trimmed.replacingOccurrences(of: " ", with: "_")
        guard let encoded = title.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else { return nil }
        return URL(string:
            "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
    }

    /// Decode the summary JSON and return `thumbnail.source` if it is https.
    static func parseImageURL(from data: Data) -> String? {
        struct Source: Decodable { let source: String }
        struct Summary: Decodable {
            let thumbnail: Source?
            let originalimage: Source?
        }
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data)
        else { return nil }
        let candidate = summary.thumbnail?.source ?? summary.originalimage?.source
        guard let candidate, candidate.hasPrefix("https://") else { return nil }
        return candidate
    }

    /// Full fetch. Any failure returns nil (definition falls back to text).
    static func image(for subject: String, session: URLSession = .shared) async -> String? {
        guard let url = summaryURL(for: subject) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("HermesGlasses/1.0 (github.com/hermes-glasses)",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return parseImageURL(from: data)
    }
}
