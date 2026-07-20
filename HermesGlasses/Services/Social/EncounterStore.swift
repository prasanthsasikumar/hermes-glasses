//
// EncounterStore.swift
//
// On-disk store for social encounters: photos as JPEGs in a photos/
// directory, the index as one encounters.json. Plain Foundation - no
// database, no network, nothing leaves the phone.
//
// The whole index is kept in memory and rewritten on every mutation. A
// day of networking is tens of entries, so the simplicity is worth more
// than incremental writes.
//

import Foundation
import os

final class EncounterStore: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "encounters"
    )

    private let rootURL: URL
    private let photosURL: URL
    private let indexURL: URL

    /// Guards `encounters` - saves are kicked off from the main actor but
    /// the disk work runs off it.
    private let lock = NSLock()
    private var encounters: [Encounter] = []

    /// - Parameter directory: root for this store. Defaults to
    ///   Application Support/Encounters; tests pass a temp directory.
    init(directory: URL? = nil) {
        let root = directory ?? Self.defaultDirectory()
        rootURL = root
        photosURL = root.appendingPathComponent("photos", isDirectory: true)
        indexURL = root.appendingPathComponent("encounters.json")
        createDirectories()
        encounters = loadIndex()
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Encounters", isDirectory: true)
    }

    // MARK: - Reads

    /// All encounters, newest first.
    func all() -> [Encounter] {
        lock.withLock { encounters }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func photoData(for encounter: Encounter) -> Data? {
        guard let filename = encounter.photoFilename else { return nil }
        return try? Data(
            contentsOf: photosURL.appendingPathComponent(filename)
        )
    }

    // MARK: - Writes

    /// Save a new encounter. The photo is optional: a failed capture still
    /// produces a note-only entry rather than losing the encounter.
    @discardableResult
    func save(note: String, photo: Data?, timestamp: Date = Date()) -> Encounter {
        let id = UUID()
        var filename: String?
        if let photo {
            let name = "\(id.uuidString).jpg"
            do {
                try photo.write(
                    to: photosURL.appendingPathComponent(name), options: .atomic
                )
                filename = name
            } catch {
                // Keep the note - a missing picture beats a lost encounter.
                logger.error("Photo write failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let encounter = Encounter(
            id: id,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            timestamp: timestamp,
            photoFilename: filename
        )
        lock.withLock { encounters.append(encounter) }
        writeIndex()
        return encounter
    }

    /// Edit a note after the fact (the People detail screen).
    func update(id: UUID, note: String) {
        lock.withLock {
            guard let index = encounters.firstIndex(where: { $0.id == id }) else { return }
            encounters[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        writeIndex()
    }

    func delete(id: UUID) {
        let removed: Encounter? = lock.withLock {
            guard let index = encounters.firstIndex(where: { $0.id == id }) else { return nil }
            return encounters.remove(at: index)
        }
        if let filename = removed?.photoFilename {
            try? FileManager.default.removeItem(
                at: photosURL.appendingPathComponent(filename)
            )
        }
        writeIndex()
    }

    // MARK: - Disk

    private func createDirectories() {
        for url in [rootURL, photosURL] {
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
        }
    }

    private func loadIndex() -> [Encounter] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([Encounter].self, from: data)
        } catch {
            // A corrupt index must not wedge the app on every launch; the
            // photos stay on disk either way.
            logger.error("Index unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func writeIndex() {
        let snapshot = lock.withLock { encounters }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            logger.error("Index write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
