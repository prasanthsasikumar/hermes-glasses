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

/// Which brain answers queries
enum AssistantBackend: String, CaseIterable {
    /// Straight from the phone to the selected AI provider - no server
    case direct
    /// WebSocket bridge on a server (Hermes agent or bridge-side provider)
    case bridge

    var label: String {
        switch self {
        case .direct: return "Direct (your API)"
        case .bridge: return "Bridge (server)"
        }
    }
}

/// Where voice is captured (and, on Bluetooth, where TTS plays - HFP is
/// bidirectional)
enum MicSource: String, CaseIterable {
    case phone
    case glasses
    case headset

    var label: String {
        switch self {
        case .phone: return "iPhone Mic"
        case .glasses: return "Glasses Mic (call screen)"
        case .headset: return "Headset Mic (AirPods etc.)"
        }
    }

    /// Compact form for the settings hub row, where the caveat in `label`
    /// doesn't fit.
    var shortLabel: String {
        switch self {
        case .phone: return "iPhone"
        case .glasses: return "Glasses"
        case .headset: return "Headset"
        }
    }

    var captureRoute: CaptureRoute {
        switch self {
        case .phone: return .phoneMic
        case .glasses: return .glassesMic
        case .headset: return .headsetMic
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
    /// On-device voice (fast, robotic) vs bridge edge-tts (natural, +1-3s).
    /// Default: bridge voice.
    var useDeviceTTS: Bool = UserDefaults.standard.bool(forKey: "use_device_tts") {
        didSet { UserDefaults.standard.set(useDeviceTTS, forKey: "use_device_tts") }
    }
    /// Glasses display HUD (Ray-Ban Display): live transcript, replies,
    /// status on the lens. Default on; harmless on non-display glasses.
    var displayHUDEnabled: Bool =
        (UserDefaults.standard.object(forKey: "display_hud_enabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(displayHUDEnabled, forKey: "display_hud_enabled")
            if !displayHUDEnabled {
                displayManager.stop()
            } else if let session = deviceSession {
                if lensBlockedByCallScreen {
                    // HUD and the glasses' HFP mic are mutually exclusive
                    // (their call screen covers the lens). HUD wins: hop
                    // back to the iPhone mic, which re-attaches the
                    // display when the route settles.
                    Task { @MainActor [weak self] in
                        guard let self, self.micSource == .glasses else { return }
                        await self.setMicSource(.phone)
                        self.show("Switched to the iPhone mic - the lens HUD can't show while the glasses' hands-free mic is active.")
                    }
                } else {
                    displayManager.stop()
                    displayManager.start(session: session)
                }
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
    /// "take me to X" -> map + directions on the lens. Default on.
    var navigationEnabled: Bool =
        (UserDefaults.standard.object(forKey: "navigation_enabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(navigationEnabled, forKey: "navigation_enabled") }
    }
    /// "what is X" -> answer + Wikipedia picture on the lens. Default on.
    var definitionImagesEnabled: Bool =
        (UserDefaults.standard.object(forKey: "definition_images_enabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(definitionImagesEnabled, forKey: "definition_images_enabled") }
    }
    /// "remember this person" -> photo + spoken note saved for follow-ups.
    /// Default on.
    var socialNotesEnabled: Bool =
        (UserDefaults.standard.object(forKey: "social_notes_enabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(socialNotesEnabled, forKey: "social_notes_enabled") }
    }
    /// True between "remember this person" and the note being saved - drives
    /// the "listening for a note" affordance in the phone UI.
    var awaitingEncounterNote: Bool = false
    /// Bumped whenever an encounter is saved/edited/deleted so the People
    /// screen re-reads the store.
    var encounterRevision: Int = 0
    /// Whether a Mapbox token is stored (drives Settings UI + notices).
    var hasMapboxToken: Bool = MapCredentials.hasToken
    /// Attach time/location/status context to every query
    var contextEnabled: Bool =
        (UserDefaults.standard.object(forKey: DeviceContextProvider.enabledKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(contextEnabled, forKey: DeviceContextProvider.enabledKey)
            if contextEnabled, connectionState != .disconnected {
                contextProvider.start()
            } else if !contextEnabled {
                contextProvider.stop()
            }
        }
    }
    /// Include exact coordinates (vs area name only)
    var contextPreciseLocation: Bool =
        (UserDefaults.standard.object(forKey: DeviceContextProvider.preciseKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(
                contextPreciseLocation, forKey: DeviceContextProvider.preciseKey
            )
        }
    }
    /// Live context line for the Settings preview
    var contextPreview: String? {
        contextProvider.contextLine()
    }
    /// Mirror of the display manager's status for SwiftUI
    var displayStatus: DisplayHUDStatus = .off
    /// Bridge server vs direct AI provider from the phone
    var backend: AssistantBackend = {
        let raw = UserDefaults.standard.string(forKey: "assistant_backend") ?? ""
        // Migrate the old "claudeDirect" raw value to "direct".
        if raw == "claudeDirect" { return .direct }
        return AssistantBackend(rawValue: raw) ?? .bridge
    }() {
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "assistant_backend") }
    }
    /// Selected direct-mode provider id (drives Settings + status chip)
    var directProviderID: String = UserDefaults.standard.string(forKey: "direct_provider_id") ?? "anthropic" {
        didSet {
            UserDefaults.standard.set(directProviderID, forKey: "direct_provider_id")
            reloadDirectProviderState()
        }
    }
    /// Model id for the current provider; applies from the next question
    var directModel: String = "" {
        didSet { UserDefaults.standard.set(directModel, forKey: "direct_model_\(directProviderID)") }
    }
    /// Custom base URL for providers that allow one (OpenAI-compatible / Ollama)
    var directBaseURL: String = "" {
        didSet { UserDefaults.standard.set(directBaseURL, forKey: "direct_base_url_\(directProviderID)") }
    }
    /// Whether the current provider has a key stored (drives Settings UI state)
    var hasDirectKey: Bool = false

    /// Reload model / base URL / key status when the provider changes.
    func reloadDirectProviderState() {
        let provider = DirectClient.provider
        directModel = DirectClient.model(for: provider)
        directBaseURL = provider.allowsCustomBaseURL ? DirectClient.baseURL(for: provider) : ""
        hasDirectKey = DirectClient.hasKey(for: provider.id)
    }

    /// The current direct-mode provider (for labels + capability checks)
    var directProvider: AIProvider { DirectClient.provider }
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
    @ObservationIgnored private let directClient = DirectClient()
    @ObservationIgnored private let displayManager = HermesDisplayManager()
    @ObservationIgnored private let contextProvider = DeviceContextProvider()
    @ObservationIgnored private let navigation = NavigationController()
    @ObservationIgnored private let encounterStore = EncounterStore()
    /// In-flight glasses capture for the encounter whose note we're awaiting.
    /// Joined by `finishEncounter`, so the note and the photo can land in
    /// either order.
    @ObservationIgnored private var encounterPhotoTask: Task<Data?, Never>?
    /// Fires if no note arrives - saves the photo with an empty note.
    @ObservationIgnored private var encounterTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPhoto: Data?
    @ObservationIgnored private var lastDirectPhotoAt: Date?
    @ObservationIgnored private var pendingDefinitionSubject: String?
    @ObservationIgnored private var definitionGeneration = 0
    /// Camera-only session owned by the Lens view (nil while the voice
    /// session provides the camera, or when Lens is closed).
    @ObservationIgnored private var lensSession: DeviceSession?

    /// Exposed for UI to show audio route
    var audio: HermesAudioManager { audioManager }

    /// Exposed for the Lens view, which drives the live stream directly
    var camera: HermesCameraManager { cameraManager }

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables)
        reloadDirectProviderState()
    }

    deinit {
        sessionObserverTask?.cancel()
    }

    // MARK: - Public API

    func startSession() async {
        // The voice session owns the glasses from here on - a Lens-created
        // camera session must not compete with it. (UI-wise Lens can't be
        // open when this button is reachable; this is belt-and-braces.)
        releaseCameraSession()

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

        // Single state observer - use a continuation to signal readiness
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

        // Session is started - set up Hermes and audio
        isGlassesConnected = true
        cameraManager.configure(session: session)
        cameraManager.onDebug = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.apiClient?.sendDebug(message)
            }
        }
        // Surface camera permission state early (non-interactive)
        Task { await ensureCameraPermission(interactive: false) }

        // Personal context (time/location/motion/battery/weather) -
        // requests location permission on first use
        contextProvider.start()

        // Display HUD (Ray-Ban Display glasses) - best-effort, shares the
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
        // Navigation: drive the lens + TTS through the existing managers.
        navigation.onShow = { [weak self] mapURL, title, step, eta in
            self?.displayManager.showNavigation(
                mapURL: mapURL, title: title, step: step, eta: eta)
        }
        navigation.onSpeak = { [weak self] text in
            self?.speechSynthesizer.speak(text)
        }
        navigation.onNotice = { [weak self] text in
            self?.show(text)
        }
        navigation.onEnd = { [weak self] in
            guard let self else { return }
            self.displayManager.clear()
            self.connectionState = .listening
            self.speechRecognizer.isSuspended = false
        }
        navigation.onDebug = { [weak self] message in
            Task { @MainActor [weak self] in self?.apiClient?.sendDebug(message) }
        }
        displayManager.onStopNavigation = { [weak self] in
            self?.navigation.stop()
        }
        // When a reply/definition dwell ends: restore the navigation map if
        // still navigating, otherwise blank the lens as usual.
        displayManager.idleHandler = { [weak self] in
            guard let self else { return }
            if self.navigation.isActive {
                self.navigation.displaySuppressed = false
                self.navigation.refreshDisplay()
            } else {
                self.displayManager.clear()
            }
        }
        // NOTE: the display attaches AFTER audio setup (step 3 below) -
        // whether the lens is free depends on the actual mic route: the
        // HFP glasses mic brings up the glasses' call screen over the HUD.

        // 2. Connect the brain. Direct mode needs no server at all -
        // skip the bridge entirely.
        if backend == .direct {
            guard !directProvider.requiresKey || DirectClient.hasKey(for: directProvider.id) else {
                show("No API key set for \(directProvider.displayName). Add one in Settings.")
                endSession()
                return
            }
        } else {
        // Bridge mode: connect with all callbacks wired up first
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
                    self.presentReply(text)
                } else {
                    // Bridge will stream its own TTS - show the card now,
                    // Stop button active while it plays. A definition query
                    // still shows its picture (backend-agnostic).
                    let shown = HermesDisplayLogic.truncateReply(text)
                    if let subject = self.pendingDefinitionSubject {
                        self.pendingDefinitionSubject = nil
                        self.showDefinitionReply(text: shown, subject: subject, speaking: true)
                    } else {
                        self.displayManager.showReply(
                            text: shown, speaking: true, dwellSeconds: nil
                        )
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
                self.displayManager.showNewConversationFlash()
            }
        }
        client.onCapturePhotoRequested = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Fail fast if the Meta AI camera permission is missing -
                // the interactive grant needs an app switch, which can't
                // happen inside the bridge's photo wait.
                guard await self.ensureCameraPermission(interactive: false) else {
                    self.apiClient?.sendPhotoError(
                        "Camera permission not granted. Tap the Photo test button to grant access via Meta AI."
                    )
                    return
                }
                do {
                    self.displayManager.showPhotoCaptured()
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
        }  // end bridge-mode setup

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
                self.displayManager.replySpeakingFinished()
                if case .speaking = self.connectionState {
                    self.connectionState = .listening
                }
                // Grace period: let the speaker's tail fade before the mic
                // listens again, or the recognizer hears the end of the TTS
                try? await Task.sleep(nanoseconds: 700_000_000)
                self.speechRecognizer.isSuspended = false
            }
        }

        // On-device TTS finished (or was interrupted) - same completion
        // flow as bridge-audio playback
        speechSynthesizer.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.displayManager.replySpeakingFinished()
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
                self.displayManager.showListening(partial: text)
                if text.split(separator: " ").count >= 2 {
                    self.interruptSpeech()
                }
            } else {
                self.liveTranscript = text
                // A late partial can trail the finalized utterance - don't
                // let it overwrite the Thinking screen on the lens
                switch self.connectionState {
                case .listening, .recording:
                    self.displayManager.showListening(partial: text)
                default:
                    break
                }
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
            let bluetoothActive = try await audioManager.startCapture(
                route: micSource.captureRoute
            )
            if micSource == .glasses && !bluetoothActive {
                show("Glasses mic not available - using iPhone mic")
            }
            if micSource == .headset && !bluetoothActive {
                show("No headset mic found - using iPhone mic. Connect AirPods or another Bluetooth headset first.")
            }
            if speechOK {
                try speechRecognizer.start()
            }
        } catch {
            show("Audio setup failed: \(error.localizedDescription)")
            endSession()
            return
        }

        // Attach the lens HUD only when the mic route leaves the lens
        // free - the GLASSES' hands-free link brings up their call screen
        // (a headset's hands-free link does not)
        if displayHUDEnabled && !lensBlockedByCallScreen {
            // stop() first: a standalone Display test may still hold an
            // attachment to its temporary session
            displayManager.stop()
            displayManager.start(session: session)
        }

        // Bridge connected, mic live, recognizer running
        connectionState = .listening
    }

    /// Send finalized text to the active brain and move the UI into processing
    func submitQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // A pending encounter claims the next utterance outright: it's a
        // note about a person, not a question, so it must not be
        // re-classified as navigation/define or sent to the AI.
        if awaitingEncounterNote {
            finishEncounter(note: trimmed)
            return
        }

        // Bump so an in-flight definition-image fetch from a prior utterance
        // can't paint over this new query or navigation.
        definitionGeneration &+= 1

        // On-device intents run before the AI brain.
        switch IntentDetector.detect(trimmed) {
        case .rememberPerson where socialNotesEnabled:
            liveTranscript = ""
            lastTranscript = trimmed
            startEncounter()
            return
        case .stopNavigation where navigation.isActive:
            navigation.stop()
            return
        case let .navigate(destination, mode) where navigationEnabled:
            liveTranscript = ""
            lastTranscript = trimmed
            connectionState = .processing
            speechRecognizer.isSuspended = true
            displayManager.clear()
            navigation.start(destination: destination, mode: mode)
            return
        case let .define(subject) where definitionImagesEnabled:
            pendingDefinitionSubject = subject
            // fall through to the normal answer path below
        default:
            pendingDefinitionSubject = nil
        }

        // While navigating, an answer temporarily overlays the map. Hold nav
        // frames off the lens so a GPS tick doesn't cut the answer short; the
        // map is restored when the answer's dwell ends (idleHandler).
        if navigation.isActive {
            navigation.displaySuppressed = true
        }

        let context = contextProvider.contextLine()
        if backend == .direct {
            liveTranscript = ""
            lastTranscript = trimmed
            connectionState = .processing
            displayManager.showThinking(query: trimmed)
            speechRecognizer.isSuspended = true
            Task { await askDirect(trimmed, context: context) }
        } else {
            guard apiClient?.isConnected == true else { return }
            liveTranscript = ""
            lastTranscript = trimmed
            connectionState = .processing
            displayManager.showThinking(query: trimmed)
            // Pause recognition so the mic doesn't transcribe Hermes's TTS
            speechRecognizer.isSuspended = true
            let outgoing = context.map { "[Context: \($0)]\n\n\(trimmed)" } ?? trimmed
            apiClient?.sendQuery(
                outgoing,
                bridgeTTS: !useDeviceTTS && !displaySilentActive
            )
        }
    }

    /// Direct mode: photo decision + capture happen locally, then one
    /// API call - no server round trips.
    private func askDirect(_ text: String, context: String? = nil) async {
        var photo: Data?
        if VisualQueryDetector.shouldCapturePhoto(text, lastPhotoAt: lastDirectPhotoAt),
           isGlassesConnected,
           await ensureCameraPermission(interactive: false) {
            displayManager.showPhotoCaptured()
            photo = try? await cameraManager.capturePhoto()
            if photo != nil {
                lastDirectPhotoAt = Date()
                pendingPhoto = photo
            }
        }

        do {
            let reply = try await directClient.ask(text, photoJPEG: photo, contextLine: context)
            lastResponse = reply
            addTurn(userText: text, agentText: reply)
            presentReply(reply)
        } catch {
            show(error.localizedDescription)
            connectionState = .listening
            speechRecognizer.isSuspended = false
            displayManager.clear()
        }
    }

    /// Store/replace the API key for the current provider (Keychain)
    func setProviderKey(_ key: String) {
        DirectClient.storeKey(key, for: directProviderID)
        hasDirectKey = DirectClient.hasKey(for: directProviderID)
    }

    /// "Send now" button - don't wait for the pause detection
    func sendNow() {
        speechRecognizer.finalizeNow()
    }

    /// Forget the conversation: bridge clears its same-day Hermes session,
    /// the app clears its history on the session_reset confirmation.
    /// Direct mode clears its on-device history immediately.
    func startNewConversation() {
        if backend == .direct {
            DirectClient.clearHistory()
            conversationHistory.removeAll()
            lastTranscript = ""
            lastResponse = ""
            liveTranscript = ""
            displayManager.showNewConversationFlash()
        } else {
            apiClient?.sendNewSession()
        }
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

    /// Silent mode is only honored while the lens can actually show text.
    private var displaySilentActive: Bool {
        displaySilentMode && displayStatus == .connected
    }

    /// Single reply path for both brains: lens card + (unless silent) TTS.
    private func presentReply(_ text: String) {
        let shown = HermesDisplayLogic.truncateReply(text)
        let subject = pendingDefinitionSubject
        pendingDefinitionSubject = nil

        if displaySilentActive {
            // Trade-off: if the BLE send itself fails after this point, the
            // reply is neither spoken nor shown (best-effort display).
            if let subject {
                showDefinitionReply(text: shown, subject: subject, speaking: false)
            } else {
                displayManager.showReply(
                    text: shown,
                    speaking: false,
                    dwellSeconds: HermesDisplayLogic.readingDwellSeconds(
                        charCount: shown.count
                    )
                )
            }
            // Nothing spoken → nothing to echo; listen again immediately
            connectionState = .listening
            speechRecognizer.isSuspended = false
        } else {
            connectionState = .speaking
            if let subject {
                showDefinitionReply(text: shown, subject: subject, speaking: true)
            } else {
                displayManager.showReply(text: shown, speaking: true, dwellSeconds: nil)
            }
            speechSynthesizer.speak(text)
            if audioManager.isUsingBluetoothInput {
                // Glasses echo-cancel their own speaker - barge-in stays on
                speechRecognizer.isSuspended = false
            }
        }
    }

    /// Show the definition text immediately, then fetch the Wikipedia picture
    /// and add it - guarded so a slow fetch can't paint over a newer screen.
    /// Dwell is decided by whether TTS is still going when the image arrives,
    /// not when the fetch started. Falls back to text-only when no image.
    private func showDefinitionReply(text: String, subject: String, speaking: Bool) {
        displayManager.showDefinition(text: text, imageURL: nil, speaking: speaking)
        let generation = definitionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let imageURL = await WikipediaImageClient.image(for: subject)
            guard let imageURL,
                  self.definitionGeneration == generation else { return }
            let stillSpeaking = (self.connectionState == .speaking)
            self.displayManager.showDefinition(
                text: text, imageURL: imageURL, speaking: stillSpeaking
            )
        }
    }

    // MARK: - Social encounters

    /// "remember this person": start the photo capture and immediately begin
    /// waiting for the spoken note. The two run in PARALLEL - the camera can
    /// take several seconds to wake, and the user shouldn't have to stand
    /// there silently while it does. `finishEncounter` joins the two.
    private func startEncounter() {
        encounterTimeoutTask?.cancel()
        awaitingEncounterNote = true
        // Hold nav frames off the lens or a GPS tick repaints over the
        // prompt mid-capture; the dwell's idleHandler restores the map.
        if navigation.isActive {
            navigation.displaySuppressed = true
        }
        displayManager.showEncounterPrompt()

        encounterPhotoTask = Task { @MainActor [weak self] in
            guard let self, self.isGlassesConnected,
                  await self.ensureCameraPermission(interactive: false)
            else { return nil }
            // Note-only is a fine outcome: never lose the encounter over a
            // camera failure.
            return try? await self.cameraManager.capturePhoto()
        }

        // Audible "your turn" cue, unless the lens is doing the talking.
        if displaySilentActive {
            connectionState = .listening
            speechRecognizer.isSuspended = false
        } else {
            connectionState = .speaking
            speechRecognizer.isSuspended = true
            speechSynthesizer.speak("Go ahead")
        }

        encounterTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.encounterNoteTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.awaitingEncounterNote else { return }
            // Silence: keep the picture, leave the note for later.
            self.finishEncounter(note: "")
        }
    }

    /// How long to wait for the spoken note before saving the photo alone.
    private static let encounterNoteTimeout: Double = 30

    /// The note arrived (or timed out): join it with the photo and save.
    private func finishEncounter(note: String) {
        encounterTimeoutTask?.cancel()
        encounterTimeoutTask = nil
        awaitingEncounterNote = false
        liveTranscript = ""

        let photoTask = encounterPhotoTask
        encounterPhotoTask = nil

        if IntentDetector.isEncounterCancellation(note) {
            photoTask?.cancel()
            // Nothing to show, so go straight back to the map (if any)
            // rather than waiting on a dwell that will never be scheduled.
            if navigation.isActive {
                navigation.displaySuppressed = false
                navigation.refreshDisplay()
            } else {
                displayManager.clear()
            }
            connectionState = .listening
            speechRecognizer.isSuspended = false
            return
        }

        connectionState = .processing
        Task { @MainActor [weak self] in
            guard let self else { return }
            let photo = await photoTask?.value ?? nil
            self.encounterStore.save(note: note, photo: photo)
            self.encounterRevision &+= 1

            // Mirror it into the on-phone chat so the capture is visible
            // immediately, photo and all.
            self.pendingPhoto = photo
            self.addTurn(
                userText: note.isEmpty ? "[Person remembered - no note]" : note,
                agentText: photo == nil
                    ? "Saved to People (no photo)"
                    : "Saved to People"
            )

            self.displayManager.showEncounterSaved(
                note: note.isEmpty ? "No note - add one in the app" : note
            )
            if self.displaySilentActive {
                self.connectionState = .listening
                self.speechRecognizer.isSuspended = false
            } else {
                self.connectionState = .speaking
                self.speechRecognizer.isSuspended = true
                self.speechSynthesizer.speak("Saved")
            }
        }
    }

    /// People screen: read-through to the store (the view holds no state of
    /// its own; `encounterRevision` tells it when to re-read).
    func allEncounters() -> [Encounter] { encounterStore.all() }

    func encounterPhoto(_ encounter: Encounter) -> Data? {
        encounterStore.photoData(for: encounter)
    }

    func updateEncounterNote(id: UUID, note: String) {
        encounterStore.update(id: id, note: note)
        encounterRevision &+= 1
    }

    func deleteEncounter(id: UUID) {
        encounterStore.delete(id: id)
        encounterRevision &+= 1
    }

    /// On-lens Repeat button: re-speak (or re-show, in silent mode).
    func repeatLastReply() {
        guard !lastResponse.isEmpty else { return }
        if case .speaking = connectionState { return }
        presentReply(lastResponse)
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
        // assume it's echo. A user genuinely quoting Hermes back loses -
        // acceptable trade-off.
        return normalize(lastResponse).contains(heard)
    }

    /// True when the glasses' call screen owns the lens: their hands-free
    /// link is the active mic route. A headset's hands-free link does NOT
    /// block the lens - that's the whole point of headset mode.
    var lensBlockedByCallScreen: Bool {
        micSource == .glasses && audioManager.isUsingBluetoothInput
    }

    /// Banner chip: cycle iPhone → Glasses → Headset → iPhone.
    func toggleMicSource() async {
        let all = MicSource.allCases
        let index = all.firstIndex(of: micSource) ?? 0
        await setMicSource(all[(index + 1) % all.count])
    }

    /// Select a mic source. Persists the preference and, when a session is
    /// live, reconfigures capture and restarts the recognizer (new route =
    /// new buffer format).
    func setMicSource(_ target: MicSource) async {
        micSource = target
        UserDefaults.standard.set(target.rawValue, forKey: "mic_source")

        guard connectionState != .disconnected else { return }

        audioManager.stopCapture()
        do {
            let bluetoothActive = try await audioManager.startCapture(
                route: target.captureRoute
            )
            speechRecognizer.restartCycle()
            if target == .glasses && !bluetoothActive {
                show("Glasses mic not available - using iPhone mic")
            }
            if target == .headset && !bluetoothActive {
                show("No headset mic found - using iPhone mic. Connect AirPods or another Bluetooth headset first.")
            }
            // HUD ⇄ GLASSES hands-free mic are mutually exclusive: the
            // glasses show their call screen while their hands-free link
            // is active. Headset mode leaves the lens free.
            if displayHUDEnabled, let session = deviceSession {
                if lensBlockedByCallScreen {
                    displayManager.stop()
                    show("Lens HUD paused - the glasses show their call screen while their hands-free mic is on. The iPhone or a headset mic keeps the HUD visible.")
                } else if displayManager.status == .off {
                    displayManager.start(session: session)
                }
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
        displayManager.stop()
        navigation.stop()
        displayStatus = .off
        contextProvider.stop()
        liveTranscript = ""
        micLevel = 0
        audioManager.stopCapture()
        apiClient?.disconnect()
        apiClient = nil
        cameraManager.reset()
        // A half-finished encounter dies with the session; the photo alone
        // isn't worth a note-less entry the user never asked for.
        encounterTimeoutTask?.cancel()
        encounterTimeoutTask = nil
        encounterPhotoTask?.cancel()
        encounterPhotoTask = nil
        awaitingEncounterNote = false
        pendingPhoto = nil
        deviceSession?.stop()
        deviceSession = nil
        isGlassesConnected = false
        connectionState = .disconnected
    }

    // MARK: - Camera-only session (Lens view)

    /// Connect the glasses camera WITHOUT starting the voice loop - no mic,
    /// no speech, no bridge. The Lens view opens straight from the home
    /// screen: it reuses the live voice session when one exists, otherwise
    /// it creates its own DeviceSession, torn down by
    /// `releaseCameraSession()` when the view closes.
    func ensureCameraSession() async throws {
        if deviceSession != nil || lensSession != nil { return }

        let session = try wearables.createSession(deviceSelector: deviceSelector)
        try session.start()

        // Wait until the session actually starts - the camera stream is
        // rejected before that. Polling beats a state-stream subscription
        // here: no replay races, and Lens has no ongoing observer needs.
        let deadline = Date().addingTimeInterval(15)
        while session.state != .started {
            if case .stopped = session.state {
                throw DeviceSessionError.unexpectedError(
                    description: "Glasses session stopped before starting"
                )
            }
            if Date() >= deadline {
                session.stop()
                throw HermesCameraError.timeout
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        lensSession = session
        cameraManager.configure(session: session)
        _ = await ensureCameraPermission(interactive: false)
    }

    /// Tear down the Lens-owned camera session. No-op when the camera is
    /// riding on the voice session (or nothing is connected).
    func releaseCameraSession() {
        guard let session = lensSession else { return }
        lensSession = nil
        if deviceSession == nil { cameraManager.reset() }
        session.stop()
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
            ?? [:]
        return dict.sorted { $0.key < $1.key }
            .map { (name: $0.key, url: $0.value) }
    }

    func savePreset(name: String, url: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return }
        var dict = UserDefaults.standard
            .dictionary(forKey: "endpoint_presets") as? [String: String]
            ?? [:]
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
    /// touching the glasses - lets the UI show bridge reachability on launch.
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

    /// Glasses camera alone - no Hermes involved. Runs the interactive
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

    /// Round trip through the active brain → response text (+TTS)
    func testQuery() async {
        await runTest("Query") { [self] in
            guard backend == .direct || apiClient?.isConnected == true else {
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
            guard backend == .direct || apiClient?.isConnected == true else {
                throw TestFailure("Start a session first (needs bridge)")
            }
            guard isGlassesConnected else {
                throw TestFailure("Glasses not connected")
            }
            submitQuery("What am I looking at? Answer in one short sentence.")
        }
    }

    /// Attach (if needed) and push a static screen to the lens. Works
    /// without a Hermes session: spins up a temporary device session just
    /// for the test and tears it down after a few seconds.
    func testDisplay() async {
        await runTest("Display") { [self] in
            if let session = deviceSession {
                if displayManager.status != .connected {
                    displayManager.stop()
                    displayManager.start(session: session)
                }
                // Attach is async - wait up to 5 s for the capability
                for _ in 0..<50 where displayManager.status != .connected {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try await displayManager.sendTest()
                return
            }

            // No session: temporary one, display only
            let session = try wearables.createSession(deviceSelector: deviceSelector)
            do {
                try session.start()
                for _ in 0..<50 where session.state != .started {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard session.state == .started else {
                    throw TestFailure("Glasses didn't respond (check they're awake and connected in Meta AI)")
                }
                displayManager.stop()
                displayManager.start(session: session)
                for _ in 0..<50 where displayManager.status != .connected {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try await displayManager.sendTest()
            } catch {
                displayManager.stop()
                session.stop()
                throw error
            }
            // Leave the test screen up briefly, then tear down - unless a
            // real session started meanwhile (it re-attaches the display
            // to its own session in startSession)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let self, self.deviceSession == nil {
                    self.displayManager.stop()
                }
                session.stop()
            }
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
