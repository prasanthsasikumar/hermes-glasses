# Glasses Photo + Vision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user asks a visual question ("what am I looking at?"), capture a JPEG from the Meta Ray-Ban glasses camera and have Hermes answer about the image.

**Architecture:** The Python bridge detects visual keywords in the STT transcript and asks the iOS app for a photo over the existing WebSocket (`{"type":"capture_photo"}`). The app captures via the DAT SDK camera stream and returns base64 JPEG in a JSON frame. The bridge writes it to a temp file and runs `hermes chat -q <text> --image <file> -Q`.

**Tech Stack:** Swift/SwiftUI + Meta Wearables DAT SDK 0.8.0 (`MWDATCamera`), Python 3 `websockets` bridge, `hermes` CLI.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-10-glasses-photo-vision-design.md`
- Binary WebSocket frames always mean mic audio; photos travel ONLY as base64 in JSON text frames.
- Photo capture failure must never stall the pipeline: bridge falls back to text-only after `photo_error` or 10 s.
- Bridge venv python: `/Users/prasanthsasikumar/.hermes/hermes-agent/venv/bin/python` (no pytest — use stdlib `unittest`).
- iOS build: `xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build` from the repo root.
- Deploy: `xcrun devicectl device install app --device 00008150-001410210C7A401C <app>` then `... process launch --device 00008150-001410210C7A401C com.flowsxr.hermes-glasses`.
- Bridge restart: `pkill -f hermes_bridge.py; cd bridge && nohup /Users/prasanthsasikumar/.hermes/hermes-agent/venv/bin/python -u hermes_bridge.py >> /tmp/hermes_bridge.log 2>&1 &`

---

### Task 0: Initialize git repository

The project is not under version control; later tasks commit.

**Files:**
- Create: `.gitignore`

**Interfaces:**
- Produces: a git repo at the project root so every later task can commit.

- [ ] **Step 1: Init and add .gitignore**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/hermes-glasses
git init
```

Create `.gitignore`:

```gitignore
.DS_Store
xcuserdata/
DerivedData/
*.xcuserstate
bridge/__pycache__/
*.pyc
nohup.out
```

- [ ] **Step 2: Initial commit**

```bash
git add -A
git commit -m "chore: initial commit — working voice loop (audio, VAD, TTS)"
```

Expected: commit created; `git status` clean.

---

### Task 1: Bridge — visual-query detection and quiet-mode ask_hermes

**Files:**
- Modify: `bridge/hermes_bridge.py` (functions `ask_hermes`, new `is_visual_query`, new `VISUAL_KEYWORDS`)
- Test: `bridge/test_hermes_bridge.py` (new)

**Interfaces:**
- Produces: `is_visual_query(text: str) -> bool`;
  `ask_hermes(text: str, image_path: str | None = None) -> str | None`.
- Consumes: existing `extract_hermes_reply(raw: str) -> str | None`, `HERMES_BIN`, `BOX_CHARS`.

- [ ] **Step 1: Write the failing tests**

Create `bridge/test_hermes_bridge.py`:

```python
import unittest

from hermes_bridge import is_visual_query


class TestIsVisualQuery(unittest.TestCase):
    def test_visual_phrases_match(self):
        for phrase in [
            "What am I looking at?",
            "can you see this",
            "READ THIS for me",
            "what is this thing in front of me",
            "take a picture",
            "describe this photo",
            "use the camera",
        ]:
            self.assertTrue(is_visual_query(phrase), phrase)

    def test_non_visual_phrases_do_not_match(self):
        for phrase in [
            "what's the weather tomorrow",
            "tell me a joke",
            "who wrote hamlet",
        ]:
            self.assertFalse(is_visual_query(phrase), phrase)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd bridge && /Users/prasanthsasikumar/.hermes/hermes-agent/venv/bin/python -m unittest test_hermes_bridge -v`
Expected: FAIL with `ImportError: cannot import name 'is_visual_query'`

- [ ] **Step 3: Implement is_visual_query and extend ask_hermes**

In `bridge/hermes_bridge.py`, add below the `STT_BACKEND` configuration:

```python
# Utterances containing any of these ask about something the user sees;
# the bridge then requests a photo from the glasses.
VISUAL_KEYWORDS = [
    "look", "looking at", "see this", "seeing", "what is this",
    "what's this", "read this", "in front of me", "picture", "photo",
    "camera",
]


def is_visual_query(text: str) -> bool:
    lowered = text.lower()
    return any(keyword in lowered for keyword in VISUAL_KEYWORDS)
```

Replace the body of `ask_hermes` with a quiet-mode invocation that accepts an
optional image (keep `extract_hermes_reply` as a fallback if boxed output
ever reappears):

```python
def ask_hermes(text: str, image_path: str | None = None) -> str | None:
    """Send text (and optionally an image) to Hermes Agent."""
    cmd = [HERMES_BIN, "chat", "-q", text, "-Q", "--cli"]
    if image_path:
        cmd += ["--image", image_path]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120 if image_path else 60,
            env={**os.environ, "HERMES_NO_COLOR": "1"},
        )
        output = result.stdout.strip()
        if output:
            # -Q should print only the reply; if box UI sneaks in, unwrap it
            if BOX_CHARS & set(output):
                reply = extract_hermes_reply(output)
                if reply:
                    return reply
            return output
        if result.stderr.strip():
            return result.stderr.strip()
        return None
    except subprocess.TimeoutExpired:
        return "Sorry, Hermes took too long to respond."
    except Exception as e:
        print(f"[Hermes] Error: {e}")
        return f"Error: {e}"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd bridge && /Users/prasanthsasikumar/.hermes/hermes-agent/venv/bin/python -m unittest test_hermes_bridge -v`
Expected: `OK` (2 tests)

- [ ] **Step 5: Smoke-test quiet mode end-to-end**

Run: `cd bridge && /Users/prasanthsasikumar/.hermes/hermes-agent/venv/bin/python -c "from hermes_bridge import ask_hermes; print(repr(ask_hermes('respond with just the word hello')))"`
Expected: `'hello'`

- [ ] **Step 6: Commit**

```bash
git add bridge/hermes_bridge.py bridge/test_hermes_bridge.py
git commit -m "feat(bridge): visual-query detection and quiet-mode hermes with --image"
```

---

### Task 2: Bridge — photo request/await in the utterance flow

**Files:**
- Modify: `bridge/hermes_bridge.py` (new `await_photo`, changes in `process_utterance`)
- Test: `bridge/test_hermes_bridge.py` (extend)

**Interfaces:**
- Produces: `await_photo(websocket, timeout: float = 10.0) -> bytes | None`.
  Protocol frames sent/consumed: sends `{"type":"capture_photo"}`; consumes
  `{"type":"photo","data":"<base64>"}` and `{"type":"photo_error","message":...}`.
- Consumes: Task 1's `is_visual_query`, `ask_hermes(text, image_path=)`.

- [ ] **Step 1: Write the failing tests**

Append to `bridge/test_hermes_bridge.py`:

```python
import asyncio
import base64

from hermes_bridge import await_photo


class FakeWebSocket:
    """Minimal stand-in exposing recv()/send() like websockets."""

    def __init__(self, messages):
        self._messages = list(messages)
        self.sent = []

    async def recv(self):
        if not self._messages:
            await asyncio.sleep(30)  # simulate silence until timeout
        return self._messages.pop(0)

    async def send(self, message):
        self.sent.append(message)


class TestAwaitPhoto(unittest.TestCase):
    def test_photo_message_returns_decoded_bytes(self):
        jpeg = b"\xff\xd8\xff\xe0fakejpeg"
        ws = FakeWebSocket([
            b"\x00\x01binary-mic-audio-to-skip",
            '{"type":"debug","msg":"ignored"}',
            '{"type":"photo","data":"%s"}' % base64.b64encode(jpeg).decode(),
        ])
        result = asyncio.run(await_photo(ws, timeout=2.0))
        self.assertEqual(result, jpeg)

    def test_photo_error_returns_none(self):
        ws = FakeWebSocket(['{"type":"photo_error","message":"no camera"}'])
        result = asyncio.run(await_photo(ws, timeout=2.0))
        self.assertIsNone(result)

    def test_timeout_returns_none(self):
        ws = FakeWebSocket([])
        result = asyncio.run(await_photo(ws, timeout=0.2))
        self.assertIsNone(result)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd bridge && /Users/prasanthsasikumar/.hermes/hermes-agent/venv/bin/python -m unittest test_hermes_bridge -v`
Expected: FAIL with `ImportError: cannot import name 'await_photo'`

- [ ] **Step 3: Implement await_photo and wire into process_utterance**

Add `import base64` to the imports at the top of `bridge/hermes_bridge.py`.

Add above `process_utterance`:

```python
async def await_photo(websocket, timeout: float = 10.0) -> bytes | None:
    """Wait for the app to answer a capture_photo request.

    Discards mic-audio (binary) frames that arrive meanwhile. Returns the
    decoded JPEG bytes, or None on photo_error or timeout.
    """
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print("[Bridge] Photo wait timed out")
            return None
        try:
            message = await asyncio.wait_for(websocket.recv(), timeout=remaining)
        except asyncio.TimeoutError:
            print("[Bridge] Photo wait timed out")
            return None
        if isinstance(message, bytes):
            continue  # mic audio while waiting — drop it
        data = json.loads(message)
        msg_type = data.get("type")
        if msg_type == "photo":
            try:
                return base64.b64decode(data.get("data", ""))
            except Exception as e:
                print(f"[Bridge] Bad photo payload: {e}")
                return None
        if msg_type == "photo_error":
            print(f"[Bridge] Photo error from app: {data.get('message')}")
            return None
        if msg_type == "debug":
            print(f"[App] {data.get('msg')}")
        # any other message type: keep waiting
```

In `process_utterance`, between the transcript send and "Step 2: Ask Hermes",
insert the capture flow, and pass the image to `ask_hermes`:

```python
    # ── Step 1.5: capture a photo for visual queries ──
    image_path = None
    query_text = transcript
    if is_visual_query(transcript):
        print("[Bridge] Visual query — requesting photo from glasses")
        await websocket.send(json.dumps({"type": "capture_photo"}))
        photo = await await_photo(websocket)
        if photo:
            img_tmp = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
            img_tmp.write(photo)
            img_tmp.close()
            image_path = img_tmp.name
            print(f"[Bridge] Photo received: {len(photo)} bytes")
        else:
            print("[Bridge] No photo — answering text-only")
            query_text = ("(No photo could be captured from the glasses.) "
                          + transcript)
```

Change the existing call `response = await asyncio.to_thread(ask_hermes, transcript)` to:

```python
    response = await asyncio.to_thread(ask_hermes, query_text, image_path)
    if image_path:
        os.unlink(image_path)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd bridge && /Users/prasanthsasikumar/.hermes/hermes-agent/venv/bin/python -m unittest test_hermes_bridge -v`
Expected: `OK` (5 tests)

- [ ] **Step 5: Syntax-check and restart the bridge**

```bash
/Users/prasanthsasikumar/.hermes/hermes-agent/venv/bin/python -m py_compile bridge/hermes_bridge.py
pkill -f hermes_bridge.py; sleep 1
cd bridge && nohup /Users/prasanthsasikumar/.hermes/hermes-agent/venv/bin/python -u hermes_bridge.py >> /tmp/hermes_bridge.log 2>&1 &
sleep 2 && lsof -nP -iTCP:8765 -sTCP:LISTEN
```

Expected: python process listening on 8765.

- [ ] **Step 6: Commit**

```bash
git add bridge/hermes_bridge.py bridge/test_hermes_bridge.py
git commit -m "feat(bridge): request and await glasses photo for visual queries"
```

---

### Task 3: App — HermesCameraManager

**Files:**
- Create: `HermesGlasses/Services/HermesCameraManager.swift`

**Interfaces:**
- Produces: `final class HermesCameraManager` with
  `func configure(session: DeviceSession)` and
  `func capturePhoto() async throws -> Data` (JPEG bytes);
  `enum HermesCameraError: LocalizedError`.
- Consumes: DAT SDK — `DeviceSession.addStream(config:) throws -> Stream?`;
  `Stream.start()`, `.stop()`, `.state`, `.statePublisher`,
  `.photoDataPublisher`, `.capturePhoto(format:) -> Bool`;
  `Announcer.listen(_:) -> AnyListenerToken`; `PhotoData.data`.
  Stream states: `.stopping, .stopped, .waitingForDevice, .starting, .streaming, .paused`.

- [ ] **Step 1: Create HermesCameraManager.swift**

```swift
//
// HermesCameraManager.swift
//
// Captures photos from the Meta Ray-Ban glasses camera via the DAT SDK.
// Owns the camera stream lifecycle: the stream runs only while a photo
// is being captured, so the glasses don't drain battery between shots.
//

import Foundation
import MWDATCamera
import MWDATCore
import os

enum HermesCameraError: LocalizedError {
    case noSession
    case streamUnavailable
    case captureFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .noSession:
            return "Glasses session is not active."
        case .streamUnavailable:
            return "Could not open the glasses camera stream."
        case .captureFailed:
            return "The glasses camera did not accept the capture request."
        case .timeout:
            return "Timed out waiting for the glasses camera."
        }
    }
}

final class HermesCameraManager: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.flowsxr.hermes-glasses", category: "camera")

    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?

    func configure(session: DeviceSession) {
        deviceSession = session
    }

    func reset() {
        stream?.stop()
        stream = nil
        deviceSession = nil
    }

    /// Capture a single JPEG from the glasses camera.
    func capturePhoto() async throws -> Data {
        guard let session = deviceSession else {
            throw HermesCameraError.noSession
        }

        let stream: MWDATCamera.Stream
        if let existing = self.stream {
            stream = existing
        } else {
            guard let created = try session.addStream() else {
                throw HermesCameraError.streamUnavailable
            }
            self.stream = created
            stream = created
        }

        if stream.state != .streaming {
            stream.start()
            try await waitForStreaming(stream, timeout: 6.0)
        }

        defer { stream.stop() }
        logger.info("Camera streaming — capturing photo")
        return try await awaitPhotoData(stream, timeout: 8.0)
    }

    // MARK: - Private

    private func waitForStreaming(
        _ stream: MWDATCamera.Stream,
        timeout: TimeInterval
    ) async throws {
        let done = OSAllocatedUnfairLock(initialState: false)
        var token: AnyListenerToken?

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            token = stream.statePublisher.listen { state in
                if state == .streaming {
                    done.withLock { finished in
                        guard !finished else { return }
                        finished = true
                        cont.resume()
                    }
                }
            }

            // Already streaming before the listener attached?
            if stream.state == .streaming {
                done.withLock { finished in
                    guard !finished else { return }
                    finished = true
                    cont.resume()
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                done.withLock { finished in
                    guard !finished else { return }
                    finished = true
                    cont.resume(throwing: HermesCameraError.timeout)
                }
            }
        }

        if let token { await token.cancel() }
    }

    private func awaitPhotoData(
        _ stream: MWDATCamera.Stream,
        timeout: TimeInterval
    ) async throws -> Data {
        let done = OSAllocatedUnfairLock(initialState: false)
        var token: AnyListenerToken?

        let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            token = stream.photoDataPublisher.listen { photo in
                done.withLock { finished in
                    guard !finished else { return }
                    finished = true
                    cont.resume(returning: photo.data)
                }
            }

            if !stream.capturePhoto(format: .jpeg) {
                done.withLock { finished in
                    guard !finished else { return }
                    finished = true
                    cont.resume(throwing: HermesCameraError.captureFailed)
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                done.withLock { finished in
                    guard !finished else { return }
                    finished = true
                    cont.resume(throwing: HermesCameraError.timeout)
                }
            }
        }

        if let token { await token.cancel() }
        logger.info("Photo captured: \(data.count) bytes")
        return data
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

Note: the Xcode project uses `PBXFileSystemSynchronizedRootGroup`-style or explicit file references — if the new file is not picked up automatically (build fails with "cannot find 'HermesCameraManager'"), add the file to the project: check how `HermesAudioManager.swift` is referenced in `HermesGlasses.xcodeproj/project.pbxproj` and mirror it for `HermesCameraManager.swift`.

- [ ] **Step 3: Commit**

```bash
git add HermesGlasses/Services/HermesCameraManager.swift HermesGlasses.xcodeproj/project.pbxproj
git commit -m "feat(app): HermesCameraManager — glasses photo capture via DAT camera stream"
```

---

### Task 4: App — protocol wiring and photo thumbnail

**Files:**
- Modify: `HermesGlasses/Services/HermesAPIClient.swift`
- Modify: `HermesGlasses/ViewModels/HermesSessionViewModel.swift`
- Modify: `HermesGlasses/Views/ContentView.swift`

**Interfaces:**
- Consumes: Task 3's `HermesCameraManager.configure(session:)` / `capturePhoto() async throws -> Data`.
- Produces: `HermesAPIClient.onCapturePhotoRequested: (() -> Void)?`,
  `sendPhoto(_ data: Data)`, `sendPhotoError(_ message: String)`;
  `ConversationTurn.photo: Data?`.

- [ ] **Step 1: HermesAPIClient — capture_photo message + photo senders**

In `handleTextMessage`'s `switch type`, add before `default:`:

```swift
            case "capture_photo":
                self?.onCapturePhotoRequested?()
```

Add to the callbacks section:

```swift
    /// Bridge asks the app to take a photo with the glasses
    var onCapturePhotoRequested: (() -> Void)?
```

Add next to `sendDebug`:

```swift
    /// Send a captured JPEG as base64 JSON (binary frames are mic audio only)
    func sendPhoto(_ data: Data) {
        guard isConnected, let ws = webSocket else { return }
        let payload: [String: String] = [
            "type": "photo",
            "data": data.base64EncodedString(),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.onError?("Photo send error: \(error.localizedDescription)")
                }
            }
        }
    }

    func sendPhotoError(_ message: String) {
        guard isConnected, let ws = webSocket else { return }
        let payload: [String: String] = ["type": "photo_error", "message": message]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        ws.send(.string(text)) { _ in }
    }
```

- [ ] **Step 2: HermesSessionViewModel — camera manager wiring**

Add to the private properties:

```swift
    @ObservationIgnored private let cameraManager = HermesCameraManager()
    @ObservationIgnored private var pendingPhoto: Data?
```

In `startSession()`, right after `isGlassesConnected = true`, add:

```swift
        cameraManager.configure(session: session)
```

With the other `client.on...` assignments, add:

```swift
        client.onCapturePhotoRequested = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let photo = try await self.cameraManager.capturePhoto()
                    self.pendingPhoto = photo
                    self.apiClient?.sendPhoto(photo)
                } catch {
                    self.apiClient?.sendPhotoError(error.localizedDescription)
                }
            }
        }
```

In `endSession()`, add `cameraManager.reset()` before `deviceSession?.stop()`.

In `addTurn`, attach and clear the pending photo. Replace the `ConversationTurn` construction:

```swift
        let turn = ConversationTurn(
            userText: userText,
            agentText: agentText,
            timestamp: Date(),
            photo: pendingPhoto
        )
        pendingPhoto = nil
```

Update the struct at the bottom of the file:

```swift
struct ConversationTurn: Identifiable {
    let id = UUID()
    let userText: String
    let agentText: String
    let timestamp: Date
    var photo: Data? = nil
}
```

- [ ] **Step 3: ContentView — thumbnail in TurnBubble**

In `TurnBubble.body`, insert between the opening `VStack` and the user-message `HStack`:

```swift
                // Photo the glasses captured for this turn
                if let photoData = turn.photo, let image = UIImage(data: photoData) {
                    HStack {
                        Spacer()
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: 200, maxHeight: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add HermesGlasses/Services/HermesAPIClient.swift HermesGlasses/ViewModels/HermesSessionViewModel.swift HermesGlasses/Views/ContentView.swift
git commit -m "feat(app): photo capture protocol wiring and conversation thumbnail"
```

---

### Task 5: End-to-end device verification

**Files:** none (verification only)

**Interfaces:**
- Consumes: everything above, running together.

- [ ] **Step 1: Deploy app and ensure bridge is running**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/hermes-glasses
xcrun devicectl device install app --device 00008150-001410210C7A401C "$HOME/Library/Developer/Xcode/DerivedData/HermesGlasses-dctuxkiumxnzfqcmvvzdamlksafw/Build/Products/Debug-iphoneos/Hermes Glasses.app"
xcrun devicectl device process launch --device 00008150-001410210C7A401C com.flowsxr.hermes-glasses
lsof -nP -iTCP:8765 -sTCP:LISTEN || (cd bridge && nohup /Users/prasanthsasikumar/.hermes/hermes-agent/venv/bin/python -u hermes_bridge.py >> /tmp/hermes_bridge.log 2>&1 &)
```

- [ ] **Step 2: Non-visual regression check** (user wears glasses, session started)

Ask: "tell me a joke". Watch `tail -f /tmp/hermes_bridge.log`.
Expected: NO `capture_photo` in the log; reply and TTS as before.

- [ ] **Step 3: Visual query check**

Ask: "what am I looking at?" while looking at something distinctive.
Expected log sequence: `Visual query — requesting photo from glasses` →
`Photo received: N bytes` (N > 50000) → Hermes reply describing the scene.
Expected on phone: thumbnail in the conversation turn + spoken answer.

- [ ] **Step 4: Failure fallback check**

End the session on the glasses side only is impractical — instead
temporarily test the timeout path: ask a visual question with the glasses
folded/asleep, or verify from log that a `photo_error` produces
`No photo — answering text-only` and a spoken text-only reply within ~12 s.

- [ ] **Step 5: Commit any fixes found; tag done**

```bash
git add -A && git commit -m "fix: e2e adjustments for photo capture" || true
```

---

## Self-Review Notes

- Spec coverage: keyword detect (T1), request/await + timeout + fallback (T2),
  capture lifecycle (T3), protocol + thumbnail (T4), e2e (T5). Quiet-mode
  cleanup folded into T1 per spec's ride-along item.
- Types cross-checked: `await_photo` returns `bytes | None`;
  `capturePhoto() async throws -> Data`; `ConversationTurn.photo: Data?`
  consistent across T3–T4.
- No placeholders; all code inline.
