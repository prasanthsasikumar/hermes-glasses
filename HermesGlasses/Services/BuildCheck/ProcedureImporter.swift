//
// ProcedureImporter.swift
//
// Document → text → steps. PDF text comes from PDFKit; a page with no text
// layer (a scan) is rendered and read with on-device OCR, so import itself
// sends nothing anywhere. Only the split of a non-numbered document uses
// the AI, once, and the result always goes to the review screen.
//

import Foundation
import PDFKit
import UIKit
import Vision

enum ProcedureImporter {
    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Couldn't read any text from that document." }
    }

    static func text(fromFileAt url: URL) async throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { throw ImportError.unreadable }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                pages.append(text.isEmpty ? await ocr(page) : text)
            }
            let joined = pages.joined(separator: "\n")
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.unreadable }
            return joined
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadable
        }
        return text
    }

    /// Internal: the machine-manual importer reads scanned pages the same way.
    static func ocr(_ page: PDFPage) async -> String {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 2000 / max(bounds.width, bounds.height, 1)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cg = image.cgImage else { return "" }
        return await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    /// Clean numbered list → local split; otherwise one AI split.
    static func steps(from text: String, checker: BuildChecker) async throws -> ProcedureParser.Split {
        let valid = try ProcedureParser.validate(text)
        if let numbered = ProcedureParser.numberedSteps(in: valid) {
            return ProcedureParser.Split(title: nil, steps: ProcedureParser.steps(fromNumbered: numbered))
        }
        return try await checker.splitProcedure(valid)
    }
}
