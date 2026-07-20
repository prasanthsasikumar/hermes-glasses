//
// Encounter.swift
//
// One entry on the People screen: a spoken note plus glasses photos.
// Originally one person = one photo; conversation capture saves several
// people into a single entry, so photos are a list. Foundation-only value
// type so EncounterStore unit-tests standalone.
//

import Foundation

struct Encounter: Codable, Identifiable, Equatable {
    let id: UUID
    /// Transcribed note. May be empty when the note timed out - the photo
    /// alone is still worth keeping, and the note can be typed in later.
    var note: String
    let timestamp: Date
    /// Filenames inside the store's photos directory, in capture order.
    /// Empty when every capture failed (note-only encounter).
    var photoFilenames: [String]

    /// The cover photo - what rows and single-photo call sites show.
    var photoFilename: String? { photoFilenames.first }

    init(
        id: UUID = UUID(),
        note: String,
        timestamp: Date,
        photoFilenames: [String] = []
    ) {
        self.id = id
        self.note = note
        self.timestamp = timestamp
        self.photoFilenames = photoFilenames
    }

    // MARK: - Codable (with pre-multi-photo migration)

    private enum CodingKeys: String, CodingKey {
        case id, note, timestamp, photoFilenames, photoFilename
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        note = try c.decode(String.self, forKey: .note)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        if let list = try c.decodeIfPresent([String].self, forKey: .photoFilenames) {
            photoFilenames = list
        } else if let single = try c.decodeIfPresent(String.self, forKey: .photoFilename) {
            // Index written before conversation capture existed.
            photoFilenames = [single]
        } else {
            photoFilenames = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(note, forKey: .note)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(photoFilenames, forKey: .photoFilenames)
    }
}
