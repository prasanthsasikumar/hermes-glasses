//
// MachineGuide.swift
//
// The parts of the machine guide that touch PDFKit, UIKit or the network:
// reading a manual off disk, drawing the identification sheet, and THE seam
// for every guide AI call (same idea as BuildChecker). All of them go to the
// user's direct provider and none of them touch conversation memory.
//

import Foundation
import PDFKit
import UIKit

// MARK: - AI seam

final class MachineGuide: @unchecked Sendable {
    static let identifyTimeout: TimeInterval = 25
    static let answerTimeout: TimeInterval = 60
    static let profileTimeout: TimeInterval = 45

    private let client: DirectClient

    init(client: DirectClient = DirectClient()) { self.client = client }

    /// Vision + a key, asked up front so the guide says why it can't start
    /// instead of failing on the first question.
    static var availability: (ok: Bool, reason: String?) { BuildChecker.canRunVisionChecks }

    /// `sheetJPEG` is the engineer's photo, with labelled reference tiles
    /// under it when any manual has a picture (`MachineGuideComposer`).
    func identify(sheetJPEG: Data, candidates: [MachineIdentifier.Candidate],
                  hasReferenceTiles: Bool) async throws -> MachineIdentifier.Outcome {
        let reply = try await client.askOneShot(
            systemPrompt: MachineIdentifier.systemPrompt,
            userText: MachineIdentifier.userPrompt(candidates: candidates, hasReferenceTiles: hasReferenceTiles),
            photoJPEG: sheetJPEG, timeout: Self.identifyTimeout)
        NSLog("[Hermes] machine guide identify reply: \(reply)")
        return MachineIdentifier.outcome(fromReply: reply, candidates: candidates)
    }

    /// One answer from `pages`. The excerpt is chosen from this question
    /// plus the previous exchange, so "next" stays on the pages the last
    /// answer came from.
    /// Streamed, so the first sentence can be spoken while the rest is
    /// still being written.
    func answer(question: String, machineName: String, pages: [String],
                history: [Turn], photoJPEG: Data?) -> AsyncThrowingStream<String, Error> {
        let recent = history.suffix(2).map(\.text).joined(separator: " ")
        let context = ManualExcerpt.context(pages: pages, query: question + " " + recent)
        return client.askWithHistoryStream(
            systemPrompt: MachineGuidePrompt.system(machineName: machineName, context: context),
            history: history, userText: question, photoJPEG: photoJPEG,
            timeout: Self.answerTimeout)
    }

    /// Import-time: a name and a "what it looks like" from the manual's
    /// opening pages. Nil when the reply was unreadable.
    func profile(pages: [String], filename: String) async throws -> (name: String?, profile: String)? {
        let reply = try await client.askOneShotText(
            systemPrompt: MachineGuidePrompt.profileSystemPrompt,
            userText: MachineGuidePrompt.profileUserPrompt(
                document: pages.joined(separator: "\n"), filename: filename),
            timeout: Self.profileTimeout)
        return MachineGuidePrompt.profile(fromAIReply: reply)
    }
}

// MARK: - Reading a manual

enum ManualImporter {
    struct Imported {
        /// One entry per PDF page (or per chunk of a text file).
        let pages: [String]
        /// The first page as a picture - often shows the machine.
        let cover: UIImage?
    }

    static let textChunkCharacters = 3000

    /// PDF text comes from PDFKit; a page with no text layer (a scan) is
    /// read with on-device OCR. Nothing leaves the phone here.
    static func read(fileAt url: URL) async throws -> Imported {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { throw ProcedureImporter.ImportError.unreadable }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { pages.append(""); continue }
                let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                pages.append(text.isEmpty ? await ProcedureImporter.ocr(page) : text)
            }
            guard pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ProcedureImporter.ImportError.unreadable
            }
            return Imported(pages: pages, cover: document.page(at: 0).map(cover))
        }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcedureImporter.ImportError.unreadable
        }
        return Imported(pages: chunks(of: text), cover: nil)
    }

    private static func cover(_ page: PDFPage) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 1024 / max(bounds.width, bounds.height, 1)
        return page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
    }

    /// A text file has no pages, so it is cut on paragraph boundaries into
    /// page-sized pieces - the excerpter needs something to choose between.
    static func chunks(of text: String) -> [String] {
        var pages: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            if !current.isEmpty, current.count + paragraph.count > textChunkCharacters {
                pages.append(current)
                current = ""
            }
            current += paragraph + "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pages.append(current) }
        return pages
    }
}

// MARK: - The identification sheet

/// askOneShot carries a single image, so the engineer's photo and the
/// reference pictures travel as ONE labelled JPEG (the Build Check trick).
/// The live photo gets the full width - a nameplate has to stay readable -
/// and the references sit under it as small tiles: they only need to show
/// a shape.
enum MachineGuideComposer {
    static let width: CGFloat = 1536
    static let tileColumns = 4

    static func sheet(now: UIImage, references: [(label: String, image: UIImage)]) -> Data? {
        guard !references.isEmpty else {
            return BuildCheckComposer.downscaledJPEG(now, maxSide: 1568, quality: 0.8)
        }
        guard now.size.width > 0, now.size.height > 0 else { return nil }
        let nowHeight = min(width * 0.75, (width * now.size.height / now.size.width).rounded())
        let tile = width / CGFloat(tileColumns)
        let rows = Int(ceil(Double(references.count) / Double(tileColumns)))
        let size = CGSize(width: width, height: nowHeight + CGFloat(rows) * tile)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            draw(now, label: "NOW", in: CGRect(x: 0, y: 0, width: width, height: nowHeight), ctx: ctx)
            for (i, reference) in references.enumerated() {
                let cell = CGRect(x: CGFloat(i % tileColumns) * tile,
                                  y: nowHeight + CGFloat(i / tileColumns) * tile,
                                  width: tile, height: tile)
                draw(reference.image, label: reference.label, in: cell, ctx: ctx)
            }
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    private static func draw(_ image: UIImage, label: String, in cell: CGRect,
                             ctx: UIGraphicsImageRendererContext) {
        let s = image.size
        let k = min(cell.width / max(s.width, 1), cell.height / max(s.height, 1))
        image.draw(in: CGRect(x: cell.midX - s.width * k / 2, y: cell.midY - s.height * k / 2,
                              width: s.width * k, height: s.height * k))
        let bar = CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: 40)
        UIColor.black.withAlphaComponent(0.7).setFill()
        ctx.fill(bar)
        (label as NSString).draw(
            in: bar.insetBy(dx: 10, dy: 5),
            withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.white])
    }
}
