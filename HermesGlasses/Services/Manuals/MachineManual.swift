//
// MachineManual.swift
//
// One machine the guide knows: its name, the manual it was imported from,
// what it looks like (the `profile` the identifier reads), and reference
// pictures. The manual's text is NOT in here - pages live in their own file
// (ManualStore.pages) so listing manuals never loads a few hundred pages.
// Foundation only; tested in tests/manuals.
//

import Foundation

struct MachineManual: Codable, Equatable, Identifiable {
    static let maxReferencePhotos = 4

    var id: UUID
    /// What the engineer calls the machine - spoken back to them, and what
    /// they say to pick it by voice ("this is the K9 pump").
    var name: String
    /// How to recognise it: shape, colour, nameplate text, model numbers.
    /// Written by the AI at import, editable. Empty is allowed - then only
    /// the name and reference pictures identify the machine.
    var profile: String
    /// The imported document, kept so it can be re-read later.
    var sourceFilename: String?
    var pageCount: Int
    var characterCount: Int
    /// First entry is the one shown to the identifier.
    var referencePhotoFilenames: [String]
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, profile: String = "",
         sourceFilename: String? = nil, pageCount: Int = 0, characterCount: Int = 0,
         referencePhotoFilenames: [String] = [], now: Date = Date()) {
        self.id = id
        self.name = name
        self.profile = profile
        self.sourceFilename = sourceFilename
        self.pageCount = pageCount
        self.characterCount = characterCount
        self.referencePhotoFilenames = referencePhotoFilenames
        self.updatedAt = now
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        sourceFilename = try c.decodeIfPresent(String.self, forKey: .sourceFilename)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        characterCount = try c.decodeIfPresent(Int.self, forKey: .characterCount) ?? 0
        referencePhotoFilenames = try c.decodeIfPresent([String].self, forKey: .referencePhotoFilenames) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed machine" : trimmed
    }
}
