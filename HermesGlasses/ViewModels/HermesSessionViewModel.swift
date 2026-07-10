//
// HermesSessionViewModel.swift
//
// Core view model managing the Hermes voice conversation session.
// Connects to Meta glasses, captures audio, streams to Hermes Agent,
// and plays back responses through the glasses.
//

import MWDATCore
import Observation
import os
import SwiftUI

/// Represents the current state of the Hermes conversation
enum HermesConnectionState: Equatable {
    case disconnected
    case connecting
    case listening
    case recording
    case processing
    case speaking
    case error(String)
}

/// Whether the Hermes bridge on the Mac is reachable, independent of glasses
enum BridgeStatus: Equatable {
    case unknown
    case checking
    case reachable
    case unreachable
}

/// Where voice is captured (and, for glasses, where TTS plays — HFP is
/// bidirectional)
enum MicSource: String, CaseIterable {
    case phone
    case glasses

    var label: String {
        switch self {
        case .phone: return "iPhone Mic"
        case .glasses: return "Glasses Mic"
        }
    }
}

@Observable
@MainActor
final class HermesSessionViewModel {
    // MARK: - Published state

    var connectionState: HermesConnectionState = .disconnected
    var isGlassesConnected: Bool = false
    var bridgeStatus: BridgeStatus = .unknown
    /// Words recognized so far in the current utterance (live)
    var liveTranscript: String = ""
    /// Mic input level 0..~1 for the UI meter
    var micLevel: Float = 0
    /// Test-panel results keyed by test name: nil=never run, ""=pass, else error
    var testResults: [String: String?] = [:]
    var testRunning: Set<String> = []
    /// Glasses camera permission (granted in the Meta AI app); nil = unknown
    var cameraPermissionGranted: Bool? = nil
    /// Preferred microphone source; the banner chip shows the ACTUAL route
    var micSource: MicSource = MicSource(
        rawValue: UserDefaults.standard.string(forKey: "mic_source") ?? ""
    ) ?? .phone
    var lastTranscript: String = ""
    var lastResponse: String = ""
    var conversationHistory: [ConversationTurn] = []
    var showError: Bool = false
    var errorMessage: String = ""

    /// Hermes Agent WebSocket endpoint
    var hermesEndpoint: String {
        (UserDefaults.standard.string(forKey: "hermes_endpoint")
            ?? "ws://localhost:8765/voice")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    @ObservationIgnored private let wearables: WearablesInterface
    @ObservationIgnored private var deviceSelector: AutoDeviceSelector
    @ObservationIgnored private var deviceSession: DeviceSession?
    @ObservationIgnored private let audioManager = HermesAudioManager()
    @ObservationIgnored private var apiClient: HermesAPIClient?
    @ObservationIgnored private var sessionObserverTask: Task<Void, Never>?
    @ObservationIgnored private let cameraManager = HermesCameraManager()
    @ObservationIgnored private let speechRecognizer = HermesSpeechRecognizer()
    @ObservationIgnored private let speechSynthesizer = HermesSpeechSynthesizer()
    @ObservationIgnored private var pendingPhoto: Data?

    /// Exposed for UI to show audio route
    var audio: HermesAudioManager { audioManager }

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    }

    deinit {
        sessionObserverTask?.cancel()
    }

    // MARK: - Public API

    func startSession() async {
        connectionState = .connecting

        // 1. Create and start a device session with the glasses
        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: deviceSelector)
        } catch {
            show("Failed to create session: \(error.localizedDescription)")
            connectionState = .disconnected
            return
        }
        deviceSession = session

        // Single state observer — use a continuation to signal readiness
        do {
            // Boxed flag so both the Task and outer scope can access it
            let done = OSAllocatedUnfairLock(initialState: false)

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let stateStream = session.stateStream()
                let errorStream = session.errorStream()

                sessionObserverTask = Task { [weak self] in
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await state in stateStream {
                                if Task.isCancelled { return }
                                switch state {
                                case .started:
                                    done.withLock { finished in
                                        if !finished {
                                            finished = true
                                            cont.resume()
                                        }
                                    }
                                    await self?.handleSessionState(state)
                                case .stopped, .stopping:
                                    done.withLock { finished in
                                        if !finished {
                                            finished = true
                                            cont.resume(
                                                throwing: DeviceSessionError.unexpectedError(
                                                    description: "Session stopped unexpectedly"
                                                )
                                            )
                                            return
                                        }
                                    }
                                    await self?.handleSessionState(state)
                                    return
                                case .paused:
                                    await self?.handleSessionState(state)
                                case .starting, .idle:
                                    break
                                @unknown default:
                                    break
                                }
                            }
                        }
                        group.addTask {
                            for await error in errorStream {
                                if Task.isCancelled { return }
                                done.withLock { finished in
                                    if !finished {
                                        finished = true
                                        cont.resume(throwing: error)
                                        return
                                    }
                                }
                                await self?.handleSessionError(error)
                                return
                            }
                        }
                    }
                }

                // Now start the session
                do {
                    try session.start()
                } catch {
                    done.withLock { finished in
                        if !finished {
                            finished = true
                            cont.resume(throwing: error)
                        }
                    }
                    return
                }

                // Check if already started (race: started before streams iterate)
                done.withLock { finished in
                    if !finished && session.state == .started {
                        finished = true
                        cont.resume()
                    }
                }
            }
        } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
            show("Glasses app needs update. Please update in Meta AI app.")
            connectionState = .disconnected
            return
        } catch {
            show("Failed to connect glasses: \(error.localizedDescription)")
            connectionState = .disconnected
            return
        }

        // Session is started — set up Hermes and audio
        isGlassesConnected = true
        cameraManager.configure(session: session)
        cameraManager.onDebug = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.apiClient?.sendDebug(message)
            }
        }
        // Surface camera permission state early (non-interactive)
        Task { await ensureCameraPermission(interactive: false) }

        // 2. Connect to Hermes first, with all callbacks wired up before
        // any audio flows, so no chunks are dropped.
        let client = HermesAPIClient(endpoint: hermesEndpoint)
        apiClient = client

        client.onTranscript = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.lastTranscript = text
                self?.connectionState = .processing
            }
        }
        client.onResponse = { [weak self] text, bridgeWillSendAudio in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastResponse = text
                self.addTurn(
                    userText: self.lastTranscript,
                    agentText: text
                )
                // On-device TTS: speak immediately unless the bridge is
                // about to stream its own audio (legacy flag)
                if !bridgeWillSendAudio {
                    self.connectionState = .speaking
                    self.speechSynthesizer.speak(text)
                    if self.audioManager.isUsingBluetoothInput {
                        // Glasses echo-cancel their own speaker: voice
                        // barge-in stays available while Hermes talks
                        self.speechRecognizer.isSuspended = false
                    }
                }
            }
        }
        client.onAudioResponse = { [weak self] audioData in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connectionState = .speaking
                await self.audioManager.playResponse(audioData)
                // Voice barge-in: on the Bluetooth route, the glasses'
                // hardware echo cancellation lets us listen WHILE Hermes
                // speaks. On the phone route the mic would hear the
                // speaker, so recognition stays suspended until playback
                // ends.
                if self.audioManager.isUsingBluetoothInput {
                    self.speechRecognizer.isSuspended = false
                }
            }
        }
        // Fires only when the bridge sent no TTS audio at all
        client.onPlaybackComplete = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connectionState = .listening
                try? await Task.sleep(nanoseconds: 700_000_000)
                self?.speechRecognizer.isSuspended = false
            }
        }
        client.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.show(error)
            }
        }
        client.onSessionReset = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.conversationHistory.removeAll()
                self.lastTranscript = ""
                self.lastResponse = ""
                self.liveTranscript = ""
            }
        }
        client.onCapturePhotoRequested = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Fail fast if the Meta AI camera permission is missing —
                // the interactive grant needs an app switch, which can't
                // happen inside the bridge's photo wait.
                guard await self.ensureCameraPermission(interactive: false) else {
                    self.apiClient?.sendPhotoError(
                        "Camera permission not granted. Tap the Photo test button to grant access via Meta AI."
                    )
                    return
                }
                do {
                    let photo = try await self.cameraManager.capturePhoto()
                    self.pendingPhoto = photo
                    self.apiClient?.sendPhoto(photo)
                } catch {
                    self.apiClient?.sendPhotoError(error.localizedDescription)
                }
            }
        }

        let connected = await client.connect()
        guard connected else {
            show("Failed to connect to Hermes bridge at \(hermesEndpoint)")
            endSession()
            return
        }

        // 3. Start audio capture + on-device recognition.
        // Audio is transcribed ON the phone; only final text goes to the
        // bridge. No mic audio is streamed over WiFi anymore.
        let speechOK = await speechRecognizer.requestAuthorization()
        if !speechOK {
            show(HermesSpeechError.notAuthorized.localizedDescription)
        }

        audioManager.onRawBuffer = { [weak self] buffer in
            self?.speechRecognizer.append(buffer)
        }
        audioManager.onLevel = { [weak self] level in
            self?.micLevel = level
        }
        audioManager.onPlaybackComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .speaking = self.connectionState {
                    self.connectionState = .listening
                }
                // Grace period: let the speaker's tail fade before the mic
                // listens again, or the recognizer hears the end of the TTS
                try? await Task.sleep(nanoseconds: 700_000_000)
                self.speechRecognizer.isSuspended = false
            }
        }

        // On-device TTS finished (or was interrupted) — same completion
        // flow as bridge-audio playback
        speechSynthesizer.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .speaking = self.connectionState {
                    self.connectionState = .listening
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                self.speechRecognizer.isSuspended = false
            }
        }

        speechRecognizer.onPartial = { [weak self] text in
            guard let self else { return }
            if case .speaking = self.connectionState {
                // Words while Hermes talks = barge-in, unless the glasses
                // are hearing Hermes's own voice
                guard !self.isEchoOfResponse(text) else { return }
                self.liveTranscript = text
                if text.split(separator: " ").count >= 2 {
                    self.interruptSpeech()
                }
            } else {
                self.liveTranscript = text
            }
        }
        speechRecognizer.onFinal = { [weak self] text in
            self?.submitQuery(text)
        }

        audioManager.onRouteChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.speechRecognizer.restartCycle()
            }
        }

        do {
            let glassesActive = try await audioManager.startCapture(
                useGlassesMic: micSource == .glasses
            )
            if micSource == .glasses && !glassesActive {
                show("Glasses mic not available — using iPhone mic")
            }
            if speechOK {
                try speechRecognizer.start()
            }
        } catch {
            show("Audio setup failed: \(error.localizedDescription)")
            endSession()
            return
        }

        // Bridge connected, mic live, recognizer running
        connectionState = .listening
    }

    /// Send finalized text to Hermes and move the UI into processing
    func submitQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, apiClient?.isConnected == true else { return }
        liveTranscript = ""
        lastTranscript = trimmed
        connectionState = .processing
        // Pause recognition so the mic doesn't transcribe Hermes's TTS
        speechRecognizer.isSuspended = true
        apiClient?.sendQuery(trimmed)
    }

    /// "Send now" button — don't wait for the pause detection
    func sendNow() {
        speechRecognizer.finalizeNow()
    }

    /// Forget the conversation: bridge clears its same-day Hermes session,
    /// the app clears its history on the session_reset confirmation
    func startNewConversation() {
        apiClient?.sendNewSession()
    }

    /// Cut Hermes off mid-reply (tap on the speaking indicator, or voice
    /// barge-in in glasses mode). stopPlayback fires onPlaybackComplete,
    /// which returns the state machine to listening.
    func interruptSpeech() {
        guard case .speaking = connectionState else { return }
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stop()
        } else {
            audioManager.stopPlayback()
        }
    }

    /// True when a partial heard during .speaking is (part of) Hermes's own
    /// spoken words leaking into the mic, rather than the user talking.
    private func isEchoOfResponse(_ partial: String) -> Bool {
        func normalize(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
                .trimmingCharacters(in: .whitespaces)
        }
        let heard = normalize(partial)
        guard !heard.isEmpty else { return true }
        // Heuristic: if what we heard appears verbatim in the response,
        // assume it's echo. A user genuinely quoting Hermes back loses —
        // acceptable trade-off.
        return normalize(lastResponse).contains(heard)
    }

    /// Flip between iPhone and glasses mic. Persists the preference and,
    /// when a session is live, reconfigures capture and restarts the
    /// recognizer (new route = new buffer format).
    func toggleMicSource() async {
        let target: MicSource = micSource == .phone ? .glasses : .phone
        micSource = target
        UserDefaults.standard.set(target.rawValue, forKey: "mic_source")

        guard connectionState != .disconnected else { return }

        audioManager.stopCapture()
        do {
            let glassesActive = try await audioManager.startCapture(
                useGlassesMic: target == .glasses
            )
            speechRecognizer.restartCycle()
            if target == .glasses && !glassesActive {
                show("Glasses mic not available — using iPhone mic")
            }
        } catch {
            show("Mic switch failed: \(error.localizedDescription)")
            endSession()
        }
    }

    func endSession() {
        sessionObserverTask?.cancel()
        sessionObserverTask = nil
        speechSynthesizer.stop()
        speechRecognizer.stop()
        liveTranscript = ""
        micLevel = 0
        audioManager.stopCapture()
        apiClient?.disconnect()
        apiClient = nil
        cameraManager.reset()
        pendingPhoto = nil
        deviceSession?.stop()
        deviceSession = nil
        isGlassesConnected = false
        connectionState = .disconnected
    }

    func setEndpoint(_ endpoint: String) {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: "hermes_endpoint")
        Task { await checkBridge() }
    }

    // MARK: - Endpoint presets

    /// Named endpoint presets (UserDefaults-backed; tokens stay on-device)
    var endpointPresets: [(name: String, url: String)] {
        let dict = UserDefaults.standard
            .dictionary(forKey: "endpoint_presets") as? [String: String]
            ?? ["Mac (local)": "ws://192.168.1.16:8765/voice"]
        return dict.sorted { $0.key < $1.key }
            .map { (name: $0.key, url: $0.value) }
    }

    func savePreset(name: String, url: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return }
        var dict = UserDefaults.standard
            .dictionary(forKey: "endpoint_presets") as? [String: String]
            ?? ["Mac (local)": "ws://192.168.1.16:8765/voice"]
        dict[trimmedName] = trimmedURL
        UserDefaults.standard.set(dict, forKey: "endpoint_presets")
    }

    func deletePreset(name: String) {
        var dict = UserDefaults.standard
            .dictionary(forKey: "endpoint_presets") as? [String: String] ?? [:]
        dict.removeValue(forKey: name)
        UserDefaults.standard.set(dict, forKey: "endpoint_presets")
    }

    /// Probe the Hermes bridge (connect, await welcome, disconnect) without
    /// touching the glasses — lets the UI show bridge reachability on launch.
    func checkBridge() async {
        guard bridgeStatus != .checking else { return }
        bridgeStatus = .checking
        let probe = HermesAPIClient(endpoint: hermesEndpoint)
        let ok = await probe.connect()
        probe.disconnect()
        bridgeStatus = ok ? .reachable : .unreachable
    }

    func dismissError() {
        showError = false
    }

    // MARK: - Test panel

    /// Explicit bridge test: connect + welcome + disconnect
    func testBridge() async {
        await runTest("Bridge") { [self] in
            let probe = HermesAPIClient(endpoint: hermesEndpoint)
            // Capture the transport-level failure so the test shows WHY
            var underlying = ""
            probe.onError = { message in underlying = message }
            let ok = await probe.connect()
            probe.disconnect()
            if !ok {
                let detail = underlying.isEmpty ? "no welcome received" : underlying
                throw TestFailure("\(hermesEndpoint): \(detail)")
            }
            bridgeStatus = .reachable
        }
    }

    /// Glasses camera alone — no Hermes involved. Runs the interactive
    /// permission flow (opens Meta AI) if camera access was never granted.
    func testPhoto() async {
        await runTest("Photo") { [self] in
            guard isGlassesConnected else {
                throw TestFailure("Start a session first (needs glasses)")
            }
            guard await ensureCameraPermission(interactive: true) else {
                throw TestFailure("Camera permission denied in Meta AI app")
            }
            let photo = try await cameraManager.capturePhoto()
            pendingPhoto = photo
            addTurn(
                userText: "[Test Photo]",
                agentText: "Captured \(photo.count / 1024) KB from glasses camera"
            )
        }
    }

    /// Check (and optionally request via Meta AI) the glasses camera
    /// permission. The interactive request switches to the Meta AI app.
    func ensureCameraPermission(interactive: Bool) async -> Bool {
        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            if status == .granted {
                cameraPermissionGranted = true
                return true
            }
            if interactive {
                let result = try await wearables.requestPermission(.camera)
                cameraPermissionGranted = (result == .granted)
                return result == .granted
            }
            cameraPermissionGranted = false
            return false
        } catch {
            cameraPermissionGranted = false
            return false
        }
    }

    /// Round trip through bridge → Hermes → response text (+TTS)
    func testQuery() async {
        await runTest("Query") { [self] in
            guard apiClient?.isConnected == true else {
                throw TestFailure("Start a session first (needs bridge)")
            }
            submitQuery("Respond with exactly: OK")
        }
    }

    /// Pure output test: play a locally generated tone through the current
    /// audio route (glasses in glasses mode). No bridge or Hermes involved.
    func testSound() async {
        await runTest("Sound") { [self] in
            if connectionState == .disconnected {
                // No session: playback-only mode (phone speaker or whatever
                // route iOS picks)
                try audioManager.preparePlaybackOnly()
            } else {
                connectionState = .speaking
            }
            await audioManager.playResponse(HermesAudioManager.makeTestTone())
        }
    }

    /// Full photo pipeline via a canned visual query
    func testVisualQuery() async {
        await runTest("Visual") { [self] in
            guard apiClient?.isConnected == true else {
                throw TestFailure("Start a session first (needs bridge)")
            }
            guard isGlassesConnected else {
                throw TestFailure("Glasses not connected")
            }
            submitQuery("What am I looking at? Answer in one short sentence.")
        }
    }

    private struct TestFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func runTest(_ name: String, _ body: () async throws -> Void) async {
        testRunning.insert(name)
        defer { testRunning.remove(name) }
        do {
            try await body()
            testResults[name] = ""
        } catch {
            testResults[name] = error.localizedDescription
        }
    }

    // MARK: - Private

    private func handleSessionState(_ state: DeviceSessionState) async {
        switch state {
        case .started:
            isGlassesConnected = true
        case .stopped, .stopping:
            endSession()
        case .paused:
            connectionState = .disconnected
        case .starting, .idle:
            break
        @unknown default:
            break
        }
    }

    private func handleSessionError(_ error: DeviceSessionError) async {
        show(error.localizedDescription)
    }

    private func addTurn(userText: String, agentText: String) {
        let turn = ConversationTurn(
            userText: userText,
            agentText: agentText,
            timestamp: Date(),
            photo: pendingPhoto
        )
        pendingPhoto = nil
        conversationHistory.append(turn)
        if conversationHistory.count > 50 {
            conversationHistory.removeFirst()
        }
        lastTranscript = ""
    }

    private func show(_ message: String) {
        errorMessage = message
        showError = true
    }
}

struct ConversationTurn: Identifiable {
    let id = UUID()
    let userText: String
    let agentText: String
    let timestamp: Date
    var photo: Data? = nil
}
