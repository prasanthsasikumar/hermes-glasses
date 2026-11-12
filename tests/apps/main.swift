//
// Standalone tests for the app registry. No XCTest target, so build via:
//   xcrun swiftc \
//     HermesGlasses/Services/HermesApp.swift \
//     tests/apps/main.swift -o /tmp/apps-tests && /tmp/apps-tests
//
// These are the invariants a fifth app has to satisfy. They exist so that
// adding one is a matter of filling in a row and running this, rather than
// discovering at runtime that the drawer shows a blank tile or that two
// apps claim the same voice trigger.
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}

let all = HermesAppRegistry.all

// MARK: - The registry is well-formed

expect(!all.isEmpty, "registry is not empty")

let ids = all.map(\.id)
expect(Set(ids).count == ids.count, "app ids are unique (\(ids))")
expect(ids.allSatisfy { !$0.isEmpty }, "no empty ids")
expect(ids.allSatisfy { $0 == $0.lowercased() }, "ids are lowercase, for stable storage keys")

expect(all.allSatisfy { !$0.title.isEmpty }, "every app has a title")
expect(all.allSatisfy { !$0.systemImage.isEmpty }, "every app has an icon")
expect(all.allSatisfy { !$0.summary.isEmpty }, "every app has a one-line summary")

// A summary is shown on one line in the drawer.
expect(all.allSatisfy { $0.summary.count <= 80 },
       "summaries fit a drawer row: \(all.filter { $0.summary.count > 80 }.map(\.id))")

// A title has to fit a quick-action tile.
expect(all.allSatisfy { $0.title.count <= 12 },
       "titles fit a tile: \(all.filter { $0.title.count > 12 }.map(\.id))")

// MARK: - Capabilities are stated, not implied

expect(all.allSatisfy { !$0.capabilities.isEmpty },
       "every app declares at least one capability")

for app in all {
    let unique = Set(app.capabilities).count == app.capabilities.count
    expect(unique, "\(app.id) lists each capability once")
}

// Anything that draws on the glasses must say so - the lens is a single
// serialized resource and the arbitration policy reads this.
expect(HermesAppRegistry.map.capabilities.contains(.lens), "map declares .lens")
expect(HermesAppRegistry.lens.capabilities.contains(.lens), "lens declares .lens")

// Anything holding a live camera goes full screen: a stray drag-dismiss
// would tear the stream down mid-use.
for app in all where app.capabilities.contains(.vision)
    && ["lens", "lookup"].contains(app.id) {
    expect(app.presentation == .fullScreen,
           "\(app.id) is full screen because it holds a live stream")
}

// MARK: - Voice ownership does not collide

let voiceGroups = all.flatMap(\.voiceGroupIDs)
expect(Set(voiceGroups).count == voiceGroups.count,
       "no two apps claim the same voice group (\(voiceGroups))")

expect(HermesAppRegistry.people.isVoiceLaunchable, "People is voice-launchable")
expect(HermesAppRegistry.map.isVoiceLaunchable, "Map is voice-launchable")
expect(!HermesAppRegistry.log.isVoiceLaunchable, "Log is review-only, no trigger")

// MARK: - Phone mode

// Nothing may hard-require glasses: phone mode exists precisely so that a
// user without them is not locked out.
expect(all.allSatisfy { !$0.requiresGlasses },
       "no app locks out phone mode: \(all.filter(\.requiresGlasses).map(\.id))")

// MARK: - Pinned vs drawer

expect(HermesAppRegistry.pinned.count <= HermesAppRegistry.pinnedCount,
       "pinned row holds at most \(HermesAppRegistry.pinnedCount)")
expect(HermesAppRegistry.pinned.allSatisfy { all.contains($0) },
       "pinned apps all come from the registry")
expect(HermesAppRegistry.pinned == Array(all.prefix(HermesAppRegistry.pinnedCount)),
       "pinned preserves registry order")
expect(HermesAppRegistry.hasOverflow == (all.count > HermesAppRegistry.pinnedCount),
       "overflow flag matches the count")

// MARK: - Lookup

expect(HermesAppRegistry.app(id: "lens") == HermesAppRegistry.lens, "lookup by id")
expect(HermesAppRegistry.app(id: "nope") == nil, "unknown id returns nil")

// MARK: - Capability metadata is total

for capability in HermesAppCapability.allCases {
    expect(!capability.label.isEmpty, "\(capability.rawValue) has a label")
    expect(!capability.systemImage.isEmpty, "\(capability.rawValue) has an icon")
}

// MARK: - Lookup app

expect(HermesAppRegistry.lookup.capabilities.contains(.vision),
       "lookup needs a camera and says so")
expect(HermesAppRegistry.lookup.capabilities.contains(.lens),
       "lookup draws on the glasses and says so")
expect(!HermesAppRegistry.lookup.isVoiceLaunchable,
       "lookup is button-only, no voice trigger")
expect(HermesAppRegistry.pinned.contains(HermesAppRegistry.lookup),
       "lookup sits in the (scrollable) quick-action row, next to Log")
// Lookup stopped searching the web when it started matching an imported
// roster on-device. The summary is the one place a user is told which of
// those it does, so it is pinned rather than left to drift back.
expect(!HermesAppRegistry.lookup.summary.lowercased().contains("web"),
       "lookup's summary no longer promises a web search")
expect(HermesAppRegistry.lookup.summary.lowercased().contains("roster"),
       "lookup's summary says where the answer comes from")

expect(HermesAppRegistry.all.contains(HermesAppRegistry.buildCheck), "Build Check is registered")
expect(HermesAppRegistry.buildCheck.isVoiceLaunchable, "Build Check is voice-launchable")
expect(!HermesAppRegistry.buildCheck.requiresGlasses, "Build Check works in phone mode")

// MARK: - Manuals (machine guide)

expect(HermesAppRegistry.all.contains(HermesAppRegistry.manuals), "Manuals is registered")
expect(HermesAppRegistry.manuals.isVoiceLaunchable, "the machine guide starts by voice")
expect(!HermesAppRegistry.manuals.capabilities.contains(.lens),
       "the machine guide claims no lens - it must work on glasses without a display")
expect(HermesAppRegistry.manuals.capabilities.contains(.vision),
       "it photographs the machine and says so")
expect(HermesAppRegistry.newAppIDs.contains("manuals"), "Manuals is announced as new")

// MARK: - What's new

expect(HermesAppRegistry.newAppIDs.allSatisfy { HermesAppRegistry.app(id: $0) != nil },
       "every 'new' id names a registered app")
expect(HermesAppRegistry.newAppIDs.contains("buildcheck"), "Build Check is announced as new")
expect(HermesAppRegistry.unseenNew(opened: []).map(\.id) == HermesAppRegistry.newAppIDs,
       "nothing opened yet → every new app is unseen, in declared order")
expect(HermesAppRegistry.unseenNew(opened: ["buildcheck"]).map(\.id) == ["manuals"],
       "opening an app clears its 'new' state and nobody else's")
expect(HermesAppRegistry.unseenNew(opened: ["buildcheck", "manuals"]).isEmpty,
       "every new app opened → nothing is new")
expect(HermesAppRegistry.whatsNew(opened: [], dismissed: [])?.id == "manuals",
       "the card announces the first unseen new app - the newest is declared first")
expect(HermesAppRegistry.whatsNew(opened: [], dismissed: ["manuals"])?.id == "buildcheck",
       "dismissing one card reveals the next new app")
expect(HermesAppRegistry.whatsNew(opened: [], dismissed: ["buildcheck", "manuals"]) == nil,
       "a dismissed card stays dismissed")
expect(HermesAppRegistry.whatsNew(opened: ["buildcheck", "manuals"], dismissed: []) == nil,
       "no card for an app already opened")
expect(HermesAppRegistry.idSet(from: "") == [], "empty storage → empty set")
expect(HermesAppRegistry.idSet(from: "a,b,,a") == ["a", "b"], "storage parses, drops blanks and duplicates")
expect(HermesAppRegistry.idSet(from: HermesAppRegistry.idString(["lens", "buildcheck"])) == ["lens", "buildcheck"],
       "storage round-trips")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
