//
// Standalone tests for EncounterStore. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Social/Encounter.swift \
//     HermesGlasses/Services/Social/EncounterStore.swift \
//     tests/encounters/main.swift -o /tmp/encounter-tests && /tmp/encounter-tests
//
import Foundation

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}
func expectTrue(_ got: Bool, _ label: String) { expectEqual(got, true, label) }

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("encounter-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }

let photoBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
let store = EncounterStore(directory: root)

// Empty to start
expectEqual(store.all().count, 0, "empty store")

// Save with a photo
let now = Date()
let withPhoto = store.save(note: "  Sarah from Meta, AR input  ", photo: photoBytes,
                           timestamp: now)
expectEqual(withPhoto.note, "Sarah from Meta, AR input", "note is trimmed")
expectTrue(withPhoto.photoFilename != nil, "photo filename assigned")
expectEqual(store.photoData(for: withPhoto), photoBytes, "photo round-trips")

// Save without a photo (camera failure path)
let noPhoto = store.save(note: "Guy in the red jacket", photo: nil,
                         timestamp: now.addingTimeInterval(60))
expectTrue(noPhoto.photoFilename == nil, "no filename without a photo")
expectTrue(store.photoData(for: noPhoto) == nil, "no photo data")

// Empty note (the silence-timeout path) is still a valid entry
let silent = store.save(note: "", photo: photoBytes,
                        timestamp: now.addingTimeInterval(120))
expectEqual(silent.note, "", "empty note allowed")

// Newest first
expectEqual(store.all().map(\.id), [silent.id, noPhoto.id, withPhoto.id],
            "all() is newest first")

// Edit
store.update(id: withPhoto.id, note: "Sarah - send the demo link")
expectEqual(store.all().first(where: { $0.id == withPhoto.id })?.note,
            "Sarah - send the demo link", "note updated")

// Reload from disk: a fresh store over the same directory sees everything
let reopened = EncounterStore(directory: root)
expectEqual(reopened.all().count, 3, "index persisted")
expectEqual(reopened.all().first(where: { $0.id == withPhoto.id })?.note,
            "Sarah - send the demo link", "edit persisted")
expectEqual(reopened.photoData(for: withPhoto), photoBytes, "photo persisted")

// Delete removes the row and its photo file
let photoPath = root.appendingPathComponent("photos")
    .appendingPathComponent(withPhoto.photoFilename ?? "missing")
expectTrue(FileManager.default.fileExists(atPath: photoPath.path), "photo on disk")
reopened.delete(id: withPhoto.id)
expectEqual(reopened.all().count, 2, "row deleted")
expectTrue(!FileManager.default.fileExists(atPath: photoPath.path), "photo file deleted")
expectEqual(EncounterStore(directory: root).all().count, 2, "delete persisted")

// Unknown ids are no-ops, not crashes
reopened.update(id: UUID(), note: "nobody")
reopened.delete(id: UUID())
expectEqual(reopened.all().count, 2, "unknown id is a no-op")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
