//
// Encounter.swift
//
// One person met at a gathering: a glasses photo plus a short spoken note.
// Foundation-only value type so EncounterStore unit-tests standalone.
//

import Foundation

struct Encounter: Codable, Identifiable, Equatable {
    let id: UUID
    /// Transcribed note. May be empty when the note timed out - the photo
    /// alone is still worth keeping, and the note can be typed in later.
    var note: String
    let timestamp: Date
    /// Filename inside the store's photos directory; nil when the camera
    /// capture failed (note-only encounter).
    var photoFilename: String?

    init(
        id: UUID = UUID(),
        note: String,
        timestamp: Date,
        photoFilename: String? = nil
    ) {
        self.id = id
        self.note = note
        self.timestamp = timestamp
        self.photoFilename = photoFilename
    }
}
