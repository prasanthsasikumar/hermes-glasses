# Glasses Display HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the Hermes voice loop on the Ray-Ban Display glasses' in-lens screen: live transcript, thinking status, readable reply with on-lens buttons, photo-capture flash, blank when idle, plus a silent mode where text replaces TTS.

**Architecture:** A `HermesDisplayManager` attaches a `Display` capability to the view model's existing shared `DeviceSession` (same pattern as `HermesCameraManager`). Screens are pure functions in `HermesDisplayScreens`; testable text/timing logic is SDK-free in `HermesDisplayLogic`. The view model drives the manager at its existing state transitions; every display call is best-effort and can never break the voice loop.

**Tech Stack:** Swift / SwiftUI, Meta Wearables DAT SDK 0.8.0 (`MWDATDisplay`, new product dependency), standalone `swiftc` tests for pure logic.

**Spec:** `docs/superpowers/specs/2026-07-11-glasses-display-design.md`

## Global Constraints

- Build from the **repo root**: `xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build` (running from a subdirectory has silently deployed stale binaries before).
- Ignore SourceKit "No such module MWDAT…" / "Cannot find type" diagnostics — xcodebuild is authoritative in this project.
- Display is best-effort: **no display error may propagate into the voice loop**; log via `onDebug` and continue.
- Settings keys, exact: `display_hud_enabled` (Bool, default **true**), `display_silent_mode` (Bool, default **false**).
- Exact values: reply truncation **300** chars; partial-send throttle **0.4 s**; spoken dwell **8 s**; silent-mode reading dwell **max(6, ceil(chars / 15)) s**.
- On-lens buttons: **Stop** (only while speaking), **Repeat**, **New chat** — no icons, plain labels.
- Silent mode only takes effect while the display status is connected; otherwise TTS behaves exactly as today (replies must never be silently dropped).
- Repo is public: no API keys, no tokens in any commit.
- All existing behavior (barge-in, echo suspend/resume, mic toggle, test panel) must keep working unchanged when the display is absent/off.

---

### Task 1: Pure display logic (`HermesDisplayLogic`) with standalone tests

**Files:**
- Create: `HermesGlasses/Services/HermesDisplayLogic.swift`
- Create: `tests/display-logic/main.swift`

**Interfaces:**
- Consumes: nothing (Foundation only — MUST NOT import any MWDAT module, so it compiles standalone with `swiftc`).
- Produces (used by Tasks 3–4):
  - `HermesDisplayLogic.truncateReply(_ text: String, limit: Int = 300) -> String`
  - `HermesDisplayLogic.readingDwellSeconds(charCount: Int) -> Double`
  - `HermesDisplayLogic.spokenDwellSeconds: Double` (= 8)
  - `HermesDisplayLogic.partialMinInterval: TimeInterval` (= 0.4)
  - `struct DisplaySendThrottle { init(minInterval: TimeInterval = 0.4); mutating func shouldSend(at now: Date = Date()) -> Bool }`

- [ ] **Step 1: Write the failing tests**

Create `tests/display-logic/main.swift`:

```swift
//
// Standalone tests for HermesDisplayLogic — no XCTest target in this
// project, so these run via swiftc (see command below).
//

import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

// truncateReply
expect(HermesDisplayLogic.truncateReply("short reply") == "short reply",
       "short reply unchanged")
expect(HermesDisplayLogic.truncateReply("  padded  ") == "padded",
       "reply trimmed")
let exactly300 = String(repeating: "a", count: 300)
expect(HermesDisplayLogic.truncateReply(exactly300) == exactly300,
       "300 chars unchanged")
let long = String(repeating: "b", count: 400)
let truncated = HermesDisplayLogic.truncateReply(long)
expect(truncated.count == 300, "long reply truncated to 300")
expect(truncated.hasSuffix("…"), "truncated reply ends with ellipsis")

// readingDwellSeconds: max(6, ceil(chars / 15))
expect(HermesDisplayLogic.readingDwellSeconds(charCount: 30) == 6,
       "short reply reads for the 6 s floor")
expect(HermesDisplayLogic.readingDwellSeconds(charCount: 300) == 20,
       "300 chars read for 20 s")
expect(HermesDisplayLogic.readingDwellSeconds(charCount: 91) == 7,
       "91 chars round up to 7 s")

// spoken dwell constant
expect(HermesDisplayLogic.spokenDwellSeconds == 8, "spoken dwell is 8 s")

// DisplaySendThrottle: at most one send per 0.4 s
var throttle = DisplaySendThrottle()
let t0 = Date(timeIntervalSince1970: 1_000)
expect(throttle.shouldSend(at: t0), "first send allowed")
expect(!throttle.shouldSend(at: t0.addingTimeInterval(0.2)),
       "send 0.2 s later blocked")
expect(throttle.shouldSend(at: t0.addingTimeInterval(0.5)),
       "send 0.5 s later allowed")
expect(!throttle.shouldSend(at: t0.addingTimeInterval(0.6)),
       "interval measured from last SENT, not last attempt")

if failures > 0 {
    print("\(failures) test(s) FAILED")
    exit(1)
}
print("All display logic tests passed")
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from repo root):
```bash
xcrun swiftc HermesGlasses/Services/HermesDisplayLogic.swift tests/display-logic/main.swift -o /tmp/display-logic-tests && /tmp/display-logic-tests
```
Expected: FAIL to compile — `HermesGlasses/Services/HermesDisplayLogic.swift` does not exist yet (`no such file`).

- [ ] **Step 3: Write the implementation**

Create `HermesGlasses/Services/HermesDisplayLogic.swift`:

```swift
//
// HermesDisplayLogic.swift
//
// Pure logic for the glasses display HUD: reply truncation, dwell
// times, and partial-transcript send throttling. Foundation-only so it
// unit-tests standalone (tests/display-logic/) without the DAT SDK.
//

import Foundation

enum HermesDisplayLogic {
    /// Replies longer than this are cut with an ellipsis — spoken
    /// replies are 1-3 sentences, so truncation is rare.
    static let replyCharLimit = 300

    /// How long a spoken reply stays on the lens after TTS ends.
    static let spokenDwellSeconds: Double = 8

    /// Minimum interval between partial-transcript sends (BLE budget).
    static let partialMinInterval: TimeInterval = 0.4

    static func truncateReply(
        _ text: String, limit: Int = replyCharLimit
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// Silent mode: reading time instead of TTS duration.
    static func readingDwellSeconds(charCount: Int) -> Double {
        max(6, (Double(charCount) / 15).rounded(.up))
    }
}

/// Rate limiter for partial-transcript sends. Callers bypass it for
/// finalized utterances (those always send).
struct DisplaySendThrottle {
    private var lastSent: Date?
    let minInterval: TimeInterval

    init(minInterval: TimeInterval = HermesDisplayLogic.partialMinInterval) {
        self.minInterval = minInterval
    }

    mutating func shouldSend(at now: Date = Date()) -> Bool {
        if let lastSent, now.timeIntervalSince(lastSent) < minInterval {
            return false
        }
        lastSent = now
        return true
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcrun swiftc HermesGlasses/Services/HermesDisplayLogic.swift tests/display-logic/main.swift -o /tmp/display-logic-tests && /tmp/display-logic-tests
```
Expected: every line `PASS …`, final line `All display logic tests passed`, exit code 0.

Note: the new file is NOT in the Xcode project yet — that registration happens in Task 2. This task only needs the standalone compile.

- [ ] **Step 5: Commit**

```bash
git add HermesGlasses/Services/HermesDisplayLogic.swift tests/display-logic/main.swift
git commit -m "feat: display HUD pure logic (truncation, dwell, throttle) with standalone tests"
```

---

### Task 2: Link MWDATDisplay and add the screen builders

**Files:**
- Modify: `HermesGlasses.xcodeproj/project.pbxproj`
- Create: `HermesGlasses/Services/HermesDisplayScreens.swift`

**Interfaces:**
- Consumes: `MWDATDisplay` types `FlexBox`, `Text`, `Icon`, `Button` (SDK 0.8.0, already in the package checkout). Verified signatures:
  - `Text(_ content: String, style: TextStyle = .body, color: TextColor = .primary)` — styles `.heading/.body/.meta`, colors `.primary/.secondary`
  - `Button(label: String, style: ButtonStyle = .primary, iconName: IconName? = nil, onClick: (@Sendable () -> Void)? = nil)`
  - `Icon(name: IconName, style: IconStyle = .filled)`
  - `FlexBox(direction:spacing:alignment:crossAlignment:wrap:padding:content:)` with `@ComponentBuilder` content; modifiers `.padding(CGFloat)`, `.background(.card)`, `.flexGrow(Float)`
  - `ComponentBuilder` supports only `buildBlock`/`buildArray` — **no `if` statements inside the builder**; conditional children must be prebuilt arrays iterated with `for`.
- Produces (used by Task 3):
  - `HermesDisplayScreens.listening(partial: String) -> FlexBox`
  - `HermesDisplayScreens.thinking(query: String) -> FlexBox`
  - `HermesDisplayScreens.photoCaptured() -> FlexBox`
  - `HermesDisplayScreens.reply(text: String, speaking: Bool, onStop: @escaping @Sendable () -> Void, onRepeat: @escaping @Sendable () -> Void, onNewChat: @escaping @Sendable () -> Void) -> FlexBox`
  - `HermesDisplayScreens.newConversation() -> FlexBox`
  - `HermesDisplayScreens.blank() -> FlexBox`
  - `HermesDisplayScreens.testScreen() -> FlexBox`

- [ ] **Step 1: Register the MWDATDisplay product and the three new source files in the pbxproj**

The project uses hand-rolled sequential IDs. Existing pattern: build files `AAAA000000000000000000NN`, file refs `AAAA000000000000000001NN`, package products `AAAA000000000000000007NN`, framework build files `AAAA000000000000000008NN`. Run this script from the repo root:

```bash
python3 - <<'EOF'
path = "HermesGlasses.xcodeproj/project.pbxproj"
s = open(path).read()

def sub(old, new):
    global s
    assert old in s, f"anchor not found: {old[:60]}..."
    assert new not in s, "already applied"
    s = s.replace(old, new, 1)

# 1) PBXBuildFile: sources (after ClaudeDirectClient 0012/0115)
sub(
  "\t\tAAAA00000000000000000012 /* ClaudeDirectClient.swift in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000115 /* ClaudeDirectClient.swift */; };\n",
  "\t\tAAAA00000000000000000012 /* ClaudeDirectClient.swift in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000115 /* ClaudeDirectClient.swift */; };\n"
  "\t\tAAAA00000000000000000013 /* HermesDisplayLogic.swift in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000116 /* HermesDisplayLogic.swift */; };\n"
  "\t\tAAAA00000000000000000014 /* HermesDisplayScreens.swift in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000117 /* HermesDisplayScreens.swift */; };\n"
  "\t\tAAAA00000000000000000015 /* HermesDisplayManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000118 /* HermesDisplayManager.swift */; };\n",
)

# 2) PBXBuildFile: framework product (after MWDATMockDevice 0803/0703)
sub(
  "\t\tAAAA00000000000000000803 /* MWDATMockDevice in Frameworks */ = {isa = PBXBuildFile; productRef = AAAA00000000000000000703 /* MWDATMockDevice */; };\n",
  "\t\tAAAA00000000000000000803 /* MWDATMockDevice in Frameworks */ = {isa = PBXBuildFile; productRef = AAAA00000000000000000703 /* MWDATMockDevice */; };\n"
  "\t\tAAAA00000000000000000804 /* MWDATDisplay in Frameworks */ = {isa = PBXBuildFile; productRef = AAAA00000000000000000704 /* MWDATDisplay */; };\n",
)

# 3) Frameworks build phase
sub(
  "\t\t\t\tAAAA00000000000000000803 /* MWDATMockDevice in Frameworks */,\n",
  "\t\t\t\tAAAA00000000000000000803 /* MWDATMockDevice in Frameworks */,\n"
  "\t\t\t\tAAAA00000000000000000804 /* MWDATDisplay in Frameworks */,\n",
)

# 4) PBXFileReference (after ClaudeDirectClient 0115)
sub(
  "\t\tAAAA00000000000000000115 /* ClaudeDirectClient.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ClaudeDirectClient.swift; sourceTree = \"<group>\"; };\n",
  "\t\tAAAA00000000000000000115 /* ClaudeDirectClient.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ClaudeDirectClient.swift; sourceTree = \"<group>\"; };\n"
  "\t\tAAAA00000000000000000116 /* HermesDisplayLogic.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HermesDisplayLogic.swift; sourceTree = \"<group>\"; };\n"
  "\t\tAAAA00000000000000000117 /* HermesDisplayScreens.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HermesDisplayScreens.swift; sourceTree = \"<group>\"; };\n"
  "\t\tAAAA00000000000000000118 /* HermesDisplayManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HermesDisplayManager.swift; sourceTree = \"<group>\"; };\n",
)

# 5) Services PBXGroup (after ClaudeDirectClient 0115 entry)
sub(
  "\t\t\t\tAAAA00000000000000000115 /* ClaudeDirectClient.swift */,\n",
  "\t\t\t\tAAAA00000000000000000115 /* ClaudeDirectClient.swift */,\n"
  "\t\t\t\tAAAA00000000000000000116 /* HermesDisplayLogic.swift */,\n"
  "\t\t\t\tAAAA00000000000000000117 /* HermesDisplayScreens.swift */,\n"
  "\t\t\t\tAAAA00000000000000000118 /* HermesDisplayManager.swift */,\n",
)

# 6) Sources build phase (after ClaudeDirectClient 0012 entry)
sub(
  "\t\t\t\tAAAA00000000000000000012 /* ClaudeDirectClient.swift in Sources */,\n",
  "\t\t\t\tAAAA00000000000000000012 /* ClaudeDirectClient.swift in Sources */,\n"
  "\t\t\t\tAAAA00000000000000000013 /* HermesDisplayLogic.swift in Sources */,\n"
  "\t\t\t\tAAAA00000000000000000014 /* HermesDisplayScreens.swift in Sources */,\n"
  "\t\t\t\tAAAA00000000000000000015 /* HermesDisplayManager.swift in Sources */,\n",
)

# 7) Target packageProductDependencies
sub(
  "\t\t\t\tAAAA00000000000000000703 /* MWDATMockDevice */,\n\t\t\t);",
  "\t\t\t\tAAAA00000000000000000703 /* MWDATMockDevice */,\n\t\t\t\tAAAA00000000000000000704 /* MWDATDisplay */,\n\t\t\t);",
)

# 8) XCSwiftPackageProductDependency section
sub(
  "\t\tAAAA00000000000000000703 /* MWDATMockDevice */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tpackage = AAAA00000000000000000601 /* XCRemoteSwiftPackageReference \"meta-wearables-dat-ios\" */;\n\t\t\tproductName = MWDATMockDevice;\n\t\t};\n",
  "\t\tAAAA00000000000000000703 /* MWDATMockDevice */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tpackage = AAAA00000000000000000601 /* XCRemoteSwiftPackageReference \"meta-wearables-dat-ios\" */;\n\t\t\tproductName = MWDATMockDevice;\n\t\t};\n"
  "\t\tAAAA00000000000000000704 /* MWDATDisplay */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tpackage = AAAA00000000000000000601 /* XCRemoteSwiftPackageReference \"meta-wearables-dat-ios\" */;\n\t\t\tproductName = MWDATDisplay;\n\t\t};\n",
)

open(path, "w").write(s)
print("pbxproj updated")
EOF
```
Expected output: `pbxproj updated`

Note: Task 3 creates `HermesDisplayManager.swift`; it is registered here so the pbxproj is touched once. Until Task 3's file exists, the build would fail on the missing file — so Step 2 creates a stub for it in this task.

- [ ] **Step 2: Create the screens file and a manager stub**

Create `HermesGlasses/Services/HermesDisplayScreens.swift`:

```swift
//
// HermesDisplayScreens.swift
//
// Pure screen builders for the glasses display HUD: state → view tree.
// No session state lives here.
//

import MWDATDisplay

enum HermesDisplayScreens {
    /// User is speaking — show the partial transcript.
    static func listening(partial: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text("Listening", style: .meta, color: .secondary)
            Text(partial, style: .body)
        }
        .padding(24)
    }

    /// Query submitted, waiting for the brain.
    static func thinking(query: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text(query, style: .body, color: .secondary)
            Text("Thinking…", style: .meta, color: .secondary)
        }
        .padding(24)
    }

    /// Brief flash while a glasses photo is being captured.
    static func photoCaptured() -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            Icon(name: .fourCornerFrame)
            Text("Photo captured", style: .body)
        }
        .padding(24)
    }

    /// The reply card. Stop appears only while TTS is playing.
    /// ComponentBuilder has no buildOptional, so conditional buttons are
    /// prebuilt as an array and emitted with a for-loop (buildArray).
    static func reply(
        text: String,
        speaking: Bool,
        onStop: @escaping @Sendable () -> Void,
        onRepeat: @escaping @Sendable () -> Void,
        onNewChat: @escaping @Sendable () -> Void
    ) -> FlexBox {
        var buttons: [Button] = []
        if speaking {
            buttons.append(Button(label: "Stop", style: .primary, onClick: onStop))
        }
        buttons.append(Button(label: "Repeat", style: .secondary, onClick: onRepeat))
        buttons.append(Button(label: "New chat", style: .secondary, onClick: onNewChat))

        return FlexBox(direction: .column, spacing: 12) {
            FlexBox(direction: .column) {
                Text(text, style: .body)
            }
            .padding(24)
            .background(.card)

            FlexBox(
                direction: .row, spacing: 8,
                alignment: .center, crossAlignment: .center, wrap: true
            ) {
                for button in buttons {
                    button
                }
            }
        }
    }

    /// Confirmation flash after New chat.
    static func newConversation() -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            Icon(name: .checkmarkCircle)
            Text("New conversation", style: .body)
        }
        .padding(24)
    }

    /// Blank the lens (idle state).
    static func blank() -> FlexBox {
        FlexBox(direction: .column) {}
    }

    /// Static screen for the test panel's Display button.
    static func testScreen() -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text("Hermes display", style: .heading)
            Text("Connected — this is a test screen", style: .body, color: .secondary)
        }
        .padding(24)
    }
}
```

Create `HermesGlasses/Services/HermesDisplayManager.swift` as a stub (replaced in Task 3):

```swift
//
// HermesDisplayManager.swift
//
// Display capability lifecycle — implemented in the next task.
//

import MWDATDisplay
```

- [ ] **Step 3: Build**

Run (from repo root):
```bash
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. If the build fails on `Icon(name: .fourCornerFrame)` or `.checkmarkCircle` (icon set differs at runtime version), substitute any case from `MWDATDisplay.IconName` that compiles (e.g. `.eye`, `.checkmark`) — the icon choice is cosmetic.

- [ ] **Step 4: Commit**

```bash
git add HermesGlasses.xcodeproj/project.pbxproj HermesGlasses/Services/HermesDisplayScreens.swift HermesGlasses/Services/HermesDisplayManager.swift
git commit -m "feat: link MWDATDisplay and add display HUD screen builders"
```

---

### Task 3: `HermesDisplayManager` — capability lifecycle and sends

**Files:**
- Modify: `HermesGlasses/Services/HermesDisplayManager.swift` (replace the stub entirely)

**Interfaces:**
- Consumes: `HermesDisplayScreens` (Task 2), `HermesDisplayLogic` / `DisplaySendThrottle` (Task 1), SDK: `DeviceSession.addDisplay() throws(DeviceSessionError) -> Display`, `Display.start()/stop()`, `Display.send(_ view: some DisplayableView) async throws`, `Display.statePublisher: any Announcer<DisplayState>` (`.listen { }` returns `AnyListenerToken`), `DisplayState` cases `.starting/.started/.stopping/.stopped`.
- Produces (used by Tasks 4–5):
  - `enum DisplayHUDStatus: Equatable { case off, connecting, connected, unavailable(String) }`
  - `@MainActor final class HermesDisplayManager` with:
    - `private(set) var status: DisplayHUDStatus`
    - `var onStatusChanged: ((DisplayHUDStatus) -> Void)?`, `var onDebug: ((String) -> Void)?`
    - `var onStop: (() -> Void)?`, `var onRepeat: (() -> Void)?`, `var onNewChat: (() -> Void)?`
    - `func start(session: DeviceSession)`, `func stop()`
    - `func showListening(partial: String)`, `func showThinking(query: String)`, `func showPhotoCaptured()`
    - `func showReply(text: String, speaking: Bool, dwellSeconds: Double?)`
    - `func replySpeakingFinished()`, `func showNewConversationFlash()`, `func clear()`
    - `func sendTest() async throws`

- [ ] **Step 1: Replace the stub with the implementation**

Replace the entire contents of `HermesGlasses/Services/HermesDisplayManager.swift` with:

```swift
//
// HermesDisplayManager.swift
//
// Attaches the Display capability to the shared voice DeviceSession and
// renders HUD screens. Strictly best-effort: every failure is logged and
// swallowed — the voice loop must never notice the display.
//

import Foundation
import MWDATCore
import MWDATDisplay
import os

enum DisplayHUDStatus: Equatable {
    case off                    // toggle disabled or no session
    case connecting
    case connected
    case unavailable(String)    // attach failed / update needed / dropped
}

@MainActor
final class HermesDisplayManager {
    private let logger = Logger(
        subsystem: "com.flowsxr.hermes-glasses", category: "display"
    )

    private(set) var status: DisplayHUDStatus = .off {
        didSet {
            if status != oldValue { onStatusChanged?(status) }
        }
    }

    var onStatusChanged: ((DisplayHUDStatus) -> Void)?
    var onDebug: ((String) -> Void)?
    /// On-lens button callbacks (invoked on the main actor)
    var onStop: (() -> Void)?
    var onRepeat: (() -> Void)?
    var onNewChat: (() -> Void)?

    private var display: Display?
    private var stateListenerToken: AnyListenerToken?
    private var stateTask: Task<Void, Never>?
    private var stateContinuation: AsyncStream<DisplayState>.Continuation?
    /// Latest view queued while the capability is still attaching
    private var pendingView: FlexBox?
    private var dwellTask: Task<Void, Never>?
    private var throttle = DisplaySendThrottle()
    private var lastReplyText: String = ""

    // MARK: - Lifecycle

    /// Attach the display capability on the shared voice session.
    func start(session: DeviceSession) {
        guard display == nil else { return }
        status = .connecting

        do {
            let capability = try session.addDisplay()

            let (stream, continuation) = AsyncStream.makeStream(of: DisplayState.self)
            stateContinuation = continuation
            stateListenerToken = capability.statePublisher.listen { state in
                continuation.yield(state)
            }

            stateTask = Task { [weak self] in
                for await state in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch state {
                    case .starting, .stopping:
                        break
                    case .started:
                        self.status = .connected
                        self.debug("Display attached")
                        if let view = self.pendingView {
                            self.pendingView = nil
                            self.transmit(view)
                        }
                    case .stopped:
                        // Mid-session drop unless stop() already ran
                        if self.status != .off {
                            self.status = .unavailable("Display stopped")
                        }
                        self.cleanup()
                        return
                    }
                }
            }

            capability.start()
            display = capability
        } catch {
            status = .unavailable(error.localizedDescription)
            debug("Display attach failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        cancelDwell()
        pendingView = nil
        lastReplyText = ""
        status = .off
        if let display {
            display.stop()  // .stopped arrives on the stream → cleanup()
        } else {
            cleanup()
        }
    }

    private func cleanup() {
        stateListenerToken = nil
        stateContinuation?.finish()
        stateContinuation = nil
        stateTask?.cancel()
        stateTask = nil
        display = nil
    }

    // MARK: - Screens

    func showListening(partial: String) {
        guard throttle.shouldSend() else { return }
        cancelDwell()
        send(HermesDisplayScreens.listening(partial: partial))
    }

    func showThinking(query: String) {
        cancelDwell()
        send(HermesDisplayScreens.thinking(query: query))
    }

    func showPhotoCaptured() {
        cancelDwell()
        send(HermesDisplayScreens.photoCaptured())
    }

    /// speaking=true keeps the card up (Stop button shown, no dwell);
    /// dwellSeconds non-nil blanks the lens after that many seconds.
    func showReply(text: String, speaking: Bool, dwellSeconds: Double?) {
        cancelDwell()
        lastReplyText = text
        send(HermesDisplayScreens.reply(
            text: text,
            speaking: speaking,
            onStop: { [weak self] in
                Task { @MainActor in self?.onStop?() }
            },
            onRepeat: { [weak self] in
                Task { @MainActor in self?.onRepeat?() }
            },
            onNewChat: { [weak self] in
                Task { @MainActor in self?.onNewChat?() }
            }
        ))
        if let dwellSeconds {
            scheduleDwell(seconds: dwellSeconds)
        }
    }

    /// TTS ended or was interrupted: re-render without Stop, start the
    /// spoken dwell, then blank.
    func replySpeakingFinished() {
        guard !lastReplyText.isEmpty else { return }
        showReply(
            text: lastReplyText,
            speaking: false,
            dwellSeconds: HermesDisplayLogic.spokenDwellSeconds
        )
    }

    func showNewConversationFlash() {
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.newConversation())
        scheduleDwell(seconds: 2)
    }

    func clear() {
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.blank())
    }

    /// Test panel: throws so the button can show WHY it failed.
    func sendTest() async throws {
        guard let display, status == .connected else {
            throw NSError(
                domain: "HermesDisplay", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Display not attached (status: \(status))"]
            )
        }
        try await display.send(HermesDisplayScreens.testScreen())
    }

    // MARK: - Plumbing

    private func send(_ view: FlexBox) {
        switch status {
        case .connected:
            transmit(view)
        case .connecting:
            pendingView = view  // latest wins; flushed on .started
        case .off, .unavailable:
            break
        }
    }

    private func transmit(_ view: FlexBox) {
        guard let display else { return }
        Task {
            do {
                try await display.send(view)
            } catch {
                self.debug("Display send failed: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleDwell(seconds: Double) {
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    private func debug(_ message: String) {
        logger.info("\(message, privacy: .public)")
        onDebug?(message)
    }
}
```

- [ ] **Step 2: Build**

Run (from repo root):
```bash
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. Known wrinkle: `addDisplay()` uses typed throws (`throws(DeviceSessionError)`) — the plain `catch` above is valid. If `AsyncStream.makeStream` is unavailable at the deployment target, replace with the continuation-capture form:
```swift
var continuation: AsyncStream<DisplayState>.Continuation!
let stream = AsyncStream<DisplayState> { continuation = $0 }
```

- [ ] **Step 3: Commit**

```bash
git add HermesGlasses/Services/HermesDisplayManager.swift
git commit -m "feat: display manager — capability lifecycle, pending-send, dwell"
```

---

### Task 4: View model integration (hooks, silent mode, Display test)

**Files:**
- Modify: `HermesGlasses/ViewModels/HermesSessionViewModel.swift`

**Interfaces:**
- Consumes: `HermesDisplayManager` (Task 3), `HermesDisplayLogic` (Task 1).
- Produces (used by Task 5):
  - `var displayHUDEnabled: Bool` (persisted, default true)
  - `var displaySilentMode: Bool` (persisted, default false)
  - `var displayStatus: DisplayHUDStatus` (observable mirror)
  - `func testDisplay() async` (test panel)
  - `func repeatLastReply()`

- [ ] **Step 1: Add state + manager**

In the "Published state" section, directly after the `useDeviceTTS` property (its closing `}`), add:

```swift
    /// Glasses display HUD (Ray-Ban Display): live transcript, replies,
    /// status on the lens. Default on; harmless on non-display glasses.
    var displayHUDEnabled: Bool =
        (UserDefaults.standard.object(forKey: "display_hud_enabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(displayHUDEnabled, forKey: "display_hud_enabled")
            if !displayHUDEnabled {
                displayManager.stop()
            } else if let session = deviceSession {
                displayManager.start(session: session)
            }
        }
    }
    /// Silent mode: when the display is attached, show the reply as text
    /// instead of speaking it. No effect while the display is unavailable.
    var displaySilentMode: Bool =
        UserDefaults.standard.bool(forKey: "display_silent_mode") {
        didSet {
            UserDefaults.standard.set(displaySilentMode, forKey: "display_silent_mode")
        }
    }
    /// Mirror of the display manager's status for SwiftUI
    var displayStatus: DisplayHUDStatus = .off
```

In the "Private" section, after `@ObservationIgnored private let claudeClient = ClaudeDirectClient()`, add:

```swift
    @ObservationIgnored private let displayManager = HermesDisplayManager()
```

And add these helpers after `interruptSpeech()`:

```swift
    /// Silent mode is only honored while the lens can actually show text.
    private var displaySilentActive: Bool {
        displaySilentMode && displayStatus == .connected
    }

    /// Single reply path for both brains: lens card + (unless silent) TTS.
    private func presentReply(_ text: String) {
        let shown = HermesDisplayLogic.truncateReply(text)
        if displaySilentActive {
            displayManager.showReply(
                text: shown,
                speaking: false,
                dwellSeconds: HermesDisplayLogic.readingDwellSeconds(
                    charCount: shown.count
                )
            )
            // Nothing spoken → nothing to echo; listen again immediately
            connectionState = .listening
            speechRecognizer.isSuspended = false
        } else {
            connectionState = .speaking
            displayManager.showReply(text: shown, speaking: true, dwellSeconds: nil)
            speechSynthesizer.speak(text)
            if audioManager.isUsingBluetoothInput {
                // Glasses echo-cancel their own speaker — barge-in stays on
                speechRecognizer.isSuspended = false
            }
        }
    }

    /// On-lens Repeat button: re-speak (or re-show, in silent mode).
    func repeatLastReply() {
        guard !lastResponse.isEmpty else { return }
        if case .speaking = connectionState { return }
        presentReply(lastResponse)
    }
```

- [ ] **Step 2: Wire the manager in `startSession`**

Directly after the line `Task { await ensureCameraPermission(interactive: false) }` (the camera-permission probe that follows `cameraManager.configure(session: session)`), add:

```swift
        // Display HUD (Ray-Ban Display glasses) — best-effort, shares the
        // same device session as the camera
        displayManager.onDebug = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.apiClient?.sendDebug(message)
            }
        }
        displayManager.onStatusChanged = { [weak self] newStatus in
            self?.displayStatus = newStatus
        }
        displayManager.onStop = { [weak self] in
            self?.interruptSpeech()
        }
        displayManager.onRepeat = { [weak self] in
            self?.repeatLastReply()
        }
        displayManager.onNewChat = { [weak self] in
            guard let self else { return }
            self.startNewConversation()
            self.displayManager.showNewConversationFlash()
        }
        if displayHUDEnabled {
            displayManager.start(session: session)
        }
```

- [ ] **Step 3: Drive screens from the existing transitions**

Five small edits:

a) In `speechRecognizer.onPartial`, add a display call in BOTH branches after `self.liveTranscript = text`:

```swift
        speechRecognizer.onPartial = { [weak self] text in
            guard let self else { return }
            if case .speaking = self.connectionState {
                // Words while Hermes talks = barge-in, unless the glasses
                // are hearing Hermes's own voice
                guard !self.isEchoOfResponse(text) else { return }
                self.liveTranscript = text
                self.displayManager.showListening(partial: text)
                if text.split(separator: " ").count >= 2 {
                    self.interruptSpeech()
                }
            } else {
                self.liveTranscript = text
                self.displayManager.showListening(partial: text)
            }
        }
```

b) In `submitQuery(_:)`, add `displayManager.showThinking(query: trimmed)` right after `connectionState = .processing` in BOTH branches, and in the bridge branch change the TTS flag so silent mode also suppresses bridge audio:

```swift
        if backend == .claudeDirect {
            liveTranscript = ""
            lastTranscript = trimmed
            connectionState = .processing
            displayManager.showThinking(query: trimmed)
            speechRecognizer.isSuspended = true
            Task { await askClaudeDirect(trimmed) }
        } else {
            guard apiClient?.isConnected == true else { return }
            liveTranscript = ""
            lastTranscript = trimmed
            connectionState = .processing
            displayManager.showThinking(query: trimmed)
            // Pause recognition so the mic doesn't transcribe Hermes's TTS
            speechRecognizer.isSuspended = true
            apiClient?.sendQuery(
                trimmed,
                bridgeTTS: !useDeviceTTS && !displaySilentActive
            )
        }
```

c) In `client.onResponse`, replace the reply/TTS block. Old:

```swift
                if !bridgeWillSendAudio {
                    self.connectionState = .speaking
                    self.speechSynthesizer.speak(text)
                    if self.audioManager.isUsingBluetoothInput {
                        // Glasses echo-cancel their own speaker: voice
                        // barge-in stays available while Hermes talks
                        self.speechRecognizer.isSuspended = false
                    }
                }
```

New:

```swift
                if !bridgeWillSendAudio {
                    self.presentReply(text)
                } else {
                    // Bridge will stream its own TTS — show the card now,
                    // Stop button active while it plays
                    self.displayManager.showReply(
                        text: HermesDisplayLogic.truncateReply(text),
                        speaking: true,
                        dwellSeconds: nil
                    )
                }
```

d) In `askClaudeDirect(_:)`: add `displayManager.showPhotoCaptured()` immediately before `photo = try? await cameraManager.capturePhoto()`, and replace the success block. Old:

```swift
            lastResponse = reply
            addTurn(userText: text, agentText: reply)
            connectionState = .speaking
            speechSynthesizer.speak(reply)
            if audioManager.isUsingBluetoothInput {
                // Glasses echo-cancel their own speaker — barge-in stays on
                speechRecognizer.isSuspended = false
            }
```

New:

```swift
            lastResponse = reply
            addTurn(userText: text, agentText: reply)
            presentReply(reply)
```

Also in the `catch` block, after `speechRecognizer.isSuspended = false`, add `displayManager.clear()`.

e) In `client.onCapturePhotoRequested`, add `self.displayManager.showPhotoCaptured()` immediately before `let photo = try await self.cameraManager.capturePhoto()`.

- [ ] **Step 4: Dwell on TTS completion, teardown, new chat**

a) In `speechSynthesizer.onFinished` and in `audioManager.onPlaybackComplete`, add `self.displayManager.replySpeakingFinished()` as the first line inside the `Task { @MainActor ... }` body (before the `if case .speaking` check).

b) In `endSession()`, after `speechRecognizer.stop()`, add:

```swift
        displayManager.stop()
        displayStatus = .off
```

c) In `startNewConversation()`, at the end of the `if backend == .claudeDirect` block (after `liveTranscript = ""`), add `displayManager.showNewConversationFlash()`. In the bridge `else` branch it is NOT added here — the flash for the phone's New Chat button fires on `onSessionReset`; add `self.displayManager.showNewConversationFlash()` inside `client.onSessionReset` after `self.liveTranscript = ""`. (The on-lens New chat button's flash is already handled in the `onNewChat` closure from Step 2 — for Claude Direct this yields a flash from both paths; the second send is idempotent and harmless.)

- [ ] **Step 5: Display test button backend**

After `testVisualQuery()`, add:

```swift
    /// Attach (if needed) and push a static screen to the lens
    func testDisplay() async {
        await runTest("Display") { [self] in
            guard let session = deviceSession else {
                throw TestFailure("Start a session first (needs glasses)")
            }
            if displayManager.status != .connected {
                displayManager.stop()
                displayManager.start(session: session)
            }
            // Attach is async — wait up to 5 s for the capability
            for _ in 0..<50 where displayManager.status != .connected {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await displayManager.sendTest()
        }
    }
```

- [ ] **Step 6: Build**

Run (from repo root):
```bash
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Re-run logic tests (regression)**

```bash
xcrun swiftc HermesGlasses/Services/HermesDisplayLogic.swift tests/display-logic/main.swift -o /tmp/display-logic-tests && /tmp/display-logic-tests
```
Expected: `All display logic tests passed`

- [ ] **Step 8: Commit**

```bash
git add HermesGlasses/ViewModels/HermesSessionViewModel.swift
git commit -m "feat: drive glasses display HUD from voice-loop transitions; silent mode"
```

---

### Task 5: Settings UI, diagnostics row, test button; deploy

**Files:**
- Modify: `HermesGlasses/Views/ContentView.swift`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `hermesVM.displayHUDEnabled`, `hermesVM.displaySilentMode`, `hermesVM.displayStatus`, `hermesVM.testDisplay()` (Task 4), `DisplayHUDStatus` (Task 3).
- Produces: user-facing controls; nothing downstream.

- [ ] **Step 1: Add the Display test button**

In `ContentView`'s `testPanel`, the button row currently reads:

```swift
            HStack(spacing: 8) {
                testButton("Bridge") { await hermesVM.testBridge() }
                testButton("Sound") { await hermesVM.testSound() }
                testButton("Photo") { await hermesVM.testPhoto() }
                testButton("Query") { await hermesVM.testQuery() }
                testButton("Visual") { await hermesVM.testVisualQuery() }
            }
```

Replace with:

```swift
            HStack(spacing: 8) {
                testButton("Bridge") { await hermesVM.testBridge() }
                testButton("Sound") { await hermesVM.testSound() }
                testButton("Photo") { await hermesVM.testPhoto() }
                testButton("Query") { await hermesVM.testQuery() }
                testButton("Visual") { await hermesVM.testVisualQuery() }
                testButton("Display") { await hermesVM.testDisplay() }
            }
```

- [ ] **Step 2: Settings — Glasses display section**

In `SettingsView`'s `Form`, insert a new section between the "Microphone" section and the "Glasses" section:

```swift
                Section {
                    Toggle("Show HUD on glasses", isOn: Binding(
                        get: { hermesVM.displayHUDEnabled },
                        set: { hermesVM.displayHUDEnabled = $0 }
                    ))
                    Toggle("Silent mode (read, don't speak)", isOn: Binding(
                        get: { hermesVM.displaySilentMode },
                        set: { hermesVM.displaySilentMode = $0 }
                    ))
                    .disabled(!hermesVM.displayHUDEnabled)
                } header: {
                    Text("Glasses Display")
                } footer: {
                    Text("Ray-Ban Display glasses only: live transcript, replies, and controls on the lens. Silent mode shows the reply as text instead of speaking it — handy in meetings.")
                }
```

- [ ] **Step 3: Diagnostics row**

In the "Glasses" section of `SettingsView`, after the `LabeledContent("Camera permission", ...)` row, add:

```swift
                    LabeledContent("Display", value: displayStatusText)
```

And add this computed property next to `cameraPermissionText`:

```swift
    private var displayStatusText: String {
        switch hermesVM.displayStatus {
        case .off: return hermesVM.displayHUDEnabled ? "Off (no session)" : "Disabled"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .unavailable(let reason): return "Unavailable — \(reason)"
        }
    }
```

- [ ] **Step 4: Update CLAUDE.md**

In `CLAUDE.md`, under "Next milestones", remove any line about the display if present and ensure the list reflects reality; add to "Key facts that are easy to get wrong":

```markdown
- **Display HUD (Ray-Ban Display):** `HermesDisplayManager` attaches
  `addDisplay()` to the SAME DeviceSession as the camera. Every display
  call is best-effort — errors are logged, never surfaced. Settings keys:
  `display_hud_enabled` (default true), `display_silent_mode`.
```

- [ ] **Step 5: Build and deploy to the phone**

Run (from repo root):
```bash
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build 2>&1 | tail -3
xcrun devicectl device install app --device 00008150-001410210C7A401C "$HOME/Library/Developer/Xcode/DerivedData/HermesGlasses-dctuxkiumxnzfqcmvvzdamlksafw/Build/Products/Debug-iphoneos/Hermes Glasses.app"
xcrun devicectl device process launch --device 00008150-001410210C7A401C com.flowsxr.hermes-glasses
```
Expected: `** BUILD SUCCEEDED **`, install completes, app launches.

- [ ] **Step 6: Commit**

```bash
git add HermesGlasses/Views/ContentView.swift CLAUDE.md
git commit -m "feat: display HUD settings, diagnostics row, and test button"
```

---

### On-device verification (user-run, after Task 5)

Not a task for the implementer — this is the acceptance checklist the user walks with glasses on (Developer Mode enabled in the Meta AI app):

1. Start a session → Settings shows Display "Connected"; lens is blank.
2. Test panel → Display button → test screen appears on the lens.
3. Speak → partial transcript appears on the lens; then "Thinking…"; then the reply card with Repeat / New chat (and Stop while speaking); 8 s after TTS ends the lens blanks.
4. "What am I looking at?" → "Photo captured" flash before Thinking.
5. Tap Stop on the lens mid-reply → TTS stops (same as tapping the phone).
6. Tap Repeat → reply is spoken and shown again.
7. Tap New chat → "New conversation" flash; history cleared on the phone.
8. Settings → Silent mode ON → ask something → no TTS, reply stays on lens for the reading dwell, mic listens immediately.
9. Settings → Show HUD OFF → lens goes dark, voice loop unaffected.
10. Regression: Photo test, Visual query, barge-in, mic-source toggle all still work with the display attached.
