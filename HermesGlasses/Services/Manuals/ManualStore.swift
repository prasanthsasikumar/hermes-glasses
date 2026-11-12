//
// ManualStore.swift
//
// Machine manuals under Application Support/manuals/: one JSON index, the
// imported documents in sources/, each manual's page texts in texts/, and
// reference pictures in photos/. Same shape as ProcedureStore. Nothing here
// touches the network. Foundation only; tested in tests/manuals.
//

import Foundation

final class ManualStore: @unchecked Sendable {
    private let lock = NSLock()
    private let rootURL: URL
    private let indexURL: URL
    private let photosURL: URL
    private let sourcesURL: URL
    private let textsURL: URL

    init(directory: URL? = nil) {
        rootURL = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("manuals", isDirectory: true)
        indexURL = rootURL.appendingPathComponent("manuals.json")
        photosURL = rootURL.appendingPathComponent("photos", isDirectory: true)
        sourcesURL = rootURL.appendingPathComponent("sources", isDirectory: true)
        textsURL = rootURL.appendingPathComponent("texts", isDirectory: true)
        for dir in [rootURL, photosURL, sourcesURL, textsURL] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func load() -> [MachineManual] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? Self.decoder.decode([MachineManual].self, from: data)) ?? []
    }

    private func store(_ manuals: [MachineManual]) {
        guard let data = try? Self.encoder.encode(manuals) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Alphabetical, so a manual keeps its place (and its A/B/C label in an
    /// identification) however often it is edited.
    func all() -> [MachineManual] {
        lock.withLock { load() }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func manual(id: UUID) -> MachineManual? {
        lock.withLock { load() }.first { $0.id == id }
    }

    func save(_ manual: MachineManual) {
        lock.withLock {
            var list = load()
            if let i = list.firstIndex(where: { $0.id == manual.id }) {
                list[i] = manual
            } else {
                list.append(manual)
            }
            store(list)
        }
    }

    /// Removes the entry, its pages, its pictures and its source document.
    func delete(id: UUID) {
        lock.withLock {
            var list = load()
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            let removed = list.remove(at: i)
            store(list)
            for name in removed.referencePhotoFilenames {
                try? FileManager.default.removeItem(at: photoURL(name))
            }
            if let source = removed.sourceFilename {
                try? FileManager.default.removeItem(at: sourceURL(source))
            }
            try? FileManager.default.removeItem(at: pagesURL(id))
        }
    }

    // MARK: Pages

    private func pagesURL(_ id: UUID) -> URL {
        textsURL.appendingPathComponent("\(id.uuidString).json")
    }

    func savePages(_ pages: [String], for id: UUID) throws {
        let data = try JSONEncoder().encode(pages)
        try data.write(to: pagesURL(id), options: .atomic)
    }

    /// The manual's text, one entry per page. Empty when it was never saved.
    func pages(for id: UUID) -> [String] {
        guard let data = try? Data(contentsOf: pagesURL(id)) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    // MARK: Files

    func addPhoto(_ jpeg: Data) throws -> String {
        let name = "\(UUID().uuidString).jpg"
        try jpeg.write(to: photoURL(name), options: .atomic)
        return name
    }

    func removePhoto(_ filename: String) {
        try? FileManager.default.removeItem(at: photoURL(filename))
    }

    func photoURL(_ filename: String) -> URL { photosURL.appendingPathComponent(filename) }

    func addSource(_ data: Data, fileExtension: String) throws -> String {
        let ext = fileExtension.isEmpty ? "bin" : fileExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        try data.write(to: sourceURL(name), options: .atomic)
        return name
    }

    func sourceURL(_ filename: String) -> URL { sourcesURL.appendingPathComponent(filename) }
}
