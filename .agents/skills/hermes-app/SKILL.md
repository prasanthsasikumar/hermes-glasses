---
name: hermes-app
description: Use when adding a new app/feature to Hermes Glasses - a voice-triggered capability with a lens surface, a phone screen, and/or stored records. Covers the HermesApp descriptor, the store pattern, lens rendering, voice triggers, Xcode project registration, and the hardware-arbitration invariants that this codebase has already been burned by.
---

# Building a Hermes app

Lens, People, Map and Log are the same shape four times: a voice trigger, a
set of hardware capabilities, a lens surface, a phone screen, a store, and
usually an export. A fifth one should reuse that shape rather than invent a
fifth variation of it.

**Read `AGENTS.md` first.** It holds the invariants that cost the most to
learn. The ones below are the subset an app author trips over.

## The checklist

Create a todo per item and work them in order.

1. Describe the app in `Services/HermesApp.swift`
2. Build the pure logic first, with a standalone test
3. Add the store, if it keeps anything
4. Add the lens surface, if it draws on the glasses
5. Add the voice trigger, if it has one
6. Add the phone screen
7. Register every new file in `project.pbxproj` (four edits each)
8. Build for iOS and run all suites
9. Verify on device - the simulator cannot prove the parts that matter

## 1. Describe it

Add a `HermesApp` to `HermesAppRegistry.all`. This is data, not code: the
quick-action row, the drawer, and the capability chips all read from it.

```swift
static let workout = HermesApp(
    id: "workout",                       // lowercase, stable, used as a storage key
    title: "Workout",                    // <= 12 chars, fits a tile
    systemImage: "figure.run",
    summary: "Count sets by looking at the bar.",   // <= 80 chars, one drawer line
    capabilities: [.vision, .storage],
    presentation: .sheet,                // .fullScreen if it holds a live stream
    voiceGroupIDs: ["workout"],          // must exist in VoiceCommandCatalog
    requiresGlasses: false               // keep false; phone mode must not lock users out
)
```

`tests/apps/main.swift` enforces the constraints above. Run it - a blank
tile or a stolen voice trigger is caught there, not at runtime.

## 2. Pure logic first

Everything decidable without hardware goes in a Foundation-only type with a
standalone test. This is the house style and it is why the tricky parts
(dwell, bearing, choices, routing) are trustworthy.

```bash
xcrun swiftc HermesGlasses/Services/YourThing.swift \
  tests/yourthing/main.swift -o /tmp/t && /tmp/t
```

Follow `tests/bearing/` or `tests/choices/` for the format: `expect(...)`,
`PASS`/`FAIL` lines, non-zero exit on failure. No XCTest target exists.

Write the test before the implementation and watch it fail. `ChoiceDetector`
had two real parsing bugs that only the tests caught.

## 3. Store, if it persists

Copy `EncounterStore` / `LensSessionStore`:

- a `Codable` value type, Foundation-only, tested standalone
- JSON index + a `photos/` directory under Application Support
- a decoder that migrates old keys (see `Encounter.photoFilenames`)
- read-through from the view model plus a `revision` counter the view
  observes, so screens re-read after a save

## 4. Lens surface

**Never build a Meta SDK view tree directly from your feature.** Add a case
to `LensContent` and let the two renderers pick it up:

- `HermesDisplayScreens` draws it on the glasses
- `SimulatedLensView` draws it in phone mode

`HermesDisplayManager` assigns `content` **before** its "is a display
attached" guard, so phone mode still shows it with no glasses present.
Extend `tests/lens-content/` when you add a case - the accessors must stay
total.

The lens is a single serialized resource. If your screen owns it for a
while, respect `displaySuppressed` and `idleHandler` the way
`NavigationController` does, and do not schedule a dwell that blanks a
screen the wearer is still deciding on.

## 5. Voice trigger

Triggers live in `IntentDetector`, and `VoiceCommandCatalog` reads its
phrase lists **straight out of the detector** so the "What can I say?" page
cannot drift. Add the trigger to the detector, add a group to the catalog,
put the group id in your `HermesApp`. Never hand-copy phrases into UI.

Whole-utterance commands (not substrings) for anything destructive or
modal - `remember` alone is far too common a word. See
`conversationStartCommands` for the pattern, and add cases to
`tests/intent/`.

## 6. Phone screen

Build from the primitives in `Views/HermesDesign.swift` - `HermesSection`,
`HermesCard`, `HermesRow`, `HermesIconTile`, `HermesChip`,
`HermesScrollPage`. One accent (terracotta), warm neutrals, 22pt cards.
Do not restyle a stock `List`; if you keep a `Form`, call
`hermesFormStyle()`.

Wire it into `ContentView.open(_:)`.

## 7. Register in Xcode

There are no synchronized groups. Each new `.swift` file needs **four**
manual `project.pbxproj` edits: `PBXBuildFile`, `PBXFileReference`, the
parent group's `children`, and the target's `PBXSourcesBuildPhase`. IDs
follow `AAAA0000000000000000<NNNN>`; find the next free with:

```bash
grep -oE 'AAAA0+[0-9]{4}' HermesGlasses.xcodeproj/project.pbxproj | sort -u | tail -3
```

The file is TAB-indented. Verify with `plutil -lint project.pbxproj`.
SourceKit reports false "cannot find X in scope" errors for standalone
files - the real check is `xcodebuild`.

## 8. Hardware invariants

These are the ones that have actually broken this app. Violating any of
them produces a bug that looks like something else entirely.

- **Paired is not reachable.** Use `hermesVM.glassesAvailable`
  (`AutoDeviceSelector.activeDevice`), never registration state or device
  count.
- **Camera permission is two grants.** Glasses = Meta AI companion app;
  iPhone = iOS. Gate on `ensureVisionPermission(interactive:)` and
  `hasVisionSource`, never on `isGlassesConnected`.
- **One camera, one consumer.** In phone mode a session already streams -
  observe via `addVisionFrameObserver(_:_:)` rather than calling
  `startLiveStream`, and never stop a stream you did not start.
- **Never predict hardware without a fallback.** Eligibility can lapse
  between the check and the call. Attempt, then fall back.
- **Mirror SDK state into observable properties.** SwiftUI cannot see
  changes on `@ObservationIgnored` SDK objects; a value read directly will
  render once and go stale.
- **Route through `hermesVM.vision`**, not the glasses camera, so the
  feature works in phone mode for free.

## 9. Verify

```bash
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'generic/platform=iOS' build
```

Then every standalone suite under `tests/`. Then the device - the simulator
has no glasses, no camera, and no compass, so it can prove layout and
nothing else. State plainly which parts you verified on hardware and which
you did not.
