//
// HermesSessionViewModel.swift
//
// Core view model managing the Hermes voice conversation session.
// Connects to Meta glasses, captures audio, streams to Hermes Agent,
// and plays back responses through the glasses.
//

import CoreMedia
import MapKit
import MWDATCamera
import MWDATCore
import Observation
import os
import Photos
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
    /// The microphone on your AiSee glasses. Closed briefly around each photo.
    case aiseeGlasses

    /// The call-screen caveat only applies to glasses with a lens (Ray-Ban
    /// Display); on display-less glasses it is simply untrue.
    func label(glassesHaveDisplay: Bool) -> String {
        if self == .glasses && !glassesHaveDisplay { return "Glasses Mic" }
        return label
    }

    var label: String {
        switch self {
        case .phone: return "iPhone Mic"
        case .glasses: return "Glasses Mic (call screen)"
        case .headset: return "Headset Mic (AirPods etc.)"
        case .aiseeGlasses: return "AiSee glasses"
        }
    }

    /// Compact form for the settings hub row, where the caveat in `label`
    /// doesn't fit.
    var shortLabel: String {
        switch self {
        case .phone: return "iPhone"
        case .glasses: return "Glasses"
        case .headset: return "Headset"
        case .aiseeGlasses: return "AiSee"
        }
    }

    var captureRoute: CaptureRoute {
        switch self {
        case .phone: return .phoneMic
        case .glasses: return .glassesMic
        case .headset: return .headsetMic
        // The AiSee mic arrives as PCM over the kit, not as an iOS input
        // route, so the audio session stays on the phone's own route.
        case .aiseeGlasses: return .phoneMic
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
    /// The failure message from the most recently completed test, cleared on
    /// a pass. `testResults` is a dictionary, so scanning its `.values` for
    /// "the" failure returns whichever one the dictionary enumerates first -
    /// this is set explicitly by `runTest` so the Developer panel always
    /// shows the outcome of the test that was just run.
    var lastTestFailure: String? = nil
    /// Outputs of the last Developer-panel Photo / Sound tests, so the panel
    /// can show what actually happened instead of burying it in the chat.
    var lastTestPhoto: UIImage? = nil
    var lastTestPhotoSource: String? = nil
    var lastTestAudioRoute: String? = nil
    var lastTestMicSummary: String? = nil
    /// AiSee video clip in progress. `clipStarting` covers the stream open,
    /// which takes seconds - a second press then is ignored rather than
    /// queued, so a quick double press can't leave a clip running unseen.
    static let clipWifiHintKey = "aisee_clip_wifi_hint_shown"
    var clipRecording = false
    var clipStarting = false
    var clipStartedAt: Date? = nil

    // MARK: Build Check hooks (set by BuildCheckViewModel)

    /// During a run, every finalized utterance is offered here first; true =
    /// claimed (command or narration), and nothing reaches the brain.
    @ObservationIgnored var buildRunClaimer: (@MainActor (String) -> Bool)?
    /// "start build check" was heard.
    @ObservationIgnored var onStartBuildCheck: (@MainActor () -> Void)?
    /// A glasses button mapped to a Build Check action.
    @ObservationIgnored var onBuildKey: (@MainActor (GlassesKeyAction) -> Void)?
    /// The session is being torn down; a run must save itself.
    @ObservationIgnored var onSessionEnding: (@MainActor () -> Void)?
    // MARK: Machine guide hooks (set by MachineGuideViewModel)

    /// Offered every utterance that reaches the brain stage. True = the
    /// guide took it (it is on, or the utterance turned it on) and will
    /// answer through `finishExternalQuery`.
    @ObservationIgnored var machineGuideClaimer: (@MainActor (String) -> Bool)?
    /// The session is going away; the guide switches itself off. Unlike
    /// `onSessionEnding` this is NOT cleared after firing - the guide view
    /// model lives as long as the app does.
    @ObservationIgnored var onMachineGuideSessionEnding: (@MainActor () -> Void)?
    @ObservationIgnored private var chimePlayer: AVAudioPlayer?
    /// Queued cues (`speakCue(_:queued: true)`) waiting for the current one
    /// to finish; drained one at a time by `speechSynthesizer.onFinished`.
    @ObservationIgnored private var cueQueue: [String] = []

    /// Last physical key press on the AiSee glasses ("Key 1 · 10:07:32"); nil until one arrives.
    var lastAiSeeKeyPress: String? = nil
    /// Button → action mapping for the AiSee glasses (Settings › Devices › Buttons).
    var glassesKeyMap: GlassesKeyMap = GlassesKeyMap.load() {
        didSet { glassesKeyMap.save() }
    }
    /// Glasses camera permission (granted in the Meta AI app); nil = unknown
    var cameraPermissionGranted: Bool? = nil
    /// Preferred microphone source; the banner chip shows the ACTUAL route
    var micSource: MicSource = MicSource(
        rawValue: UserDefaults.standard.string(
            forKey: HermesSessionViewModel.micSourceKey
        ) ?? ""
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
                if lensBlockedByCallScreen && activeGlassesHaveDisplay {
                    // HUD and the glasses' HFP mic are mutually exclusive
                    // (their call screen covers the lens). HUD wins: hop
                    // back to the iPhone mic, which re-attaches the
                    // display when the route settles.
                    Task { @MainActor [weak self] in
                        guard let self, self.micSource == .glasses else { return }
                        await self.setMicSource(.phone)
                        // News, not a fault: `show(_:)` is the error channel
                        // and also fails any pending Developer-panel test.
                        self.show(notice: "Switched to the iPhone mic - the lens HUD can't show while the glasses' hands-free mic is active.")
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
    /// Read name tags off the people snapped during a conversation capture.
    /// On-device Vision only - nothing leaves the phone. Default on.
    var badgeOCREnabled: Bool =
        (UserDefaults.standard.object(forKey: "badge_ocr_enabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(badgeOCREnabled, forKey: "badge_ocr_enabled")
            // Assist exists to catch what on-device OCR missed. With OCR off
            // every sighting is "missed", so leaving assist on would send the
            // MOST photos off-device - the opposite of what turning OCR off
            // suggests the user wants.
            if !badgeOCREnabled { badgeAssistEnabled = false }
        }
    }
    /// Keep the photograph printed on an ID card, cropped off the badge.
    ///
    /// Its own setting, and off by default, because it is the one payload
    /// here a person would object to on sight. Everything else in badge
    /// reading works without it, and the saved FILE never leaves the phone -
    /// but badge assist sends a crop of the badge itself, and a printed
    /// portrait is part of that badge, so its pixels are not exempt there.
    var badgePortraitsEnabled: Bool =
        (UserDefaults.standard.object(forKey: "badge_portraits_enabled") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(badgePortraitsEnabled, forKey: "badge_portraits_enabled")
        }
    }
    /// After a recording ends, ask the configured AI provider to read the
    /// badges Vision could not. This is the ONLY part of the People feature
    /// that leaves the phone, so it is off until the user turns it on.
    var badgeAssistEnabled: Bool =
        (UserDefaults.standard.object(forKey: "badge_assist_enabled") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(badgeAssistEnabled, forKey: "badge_assist_enabled") }
    }
    /// True between "remember this person" and the note being saved - drives
    /// the "listening for a note" affordance in the phone UI.
    var awaitingEncounterNote: Bool = false
    /// True while a conversation capture runs ("record this conversation"):
    /// every utterance becomes transcript, a 2 s person dwell snaps a photo,
    /// and nothing reaches the AI until the stop command saves one note.
    var conversationCaptureActive: Bool = false
    /// Photos kept so far in the running capture (drives the UI chip).
    var conversationCaptureSnapCount: Int = 0
    /// True while a hand-triggered badge-assist pass runs, so the button that
    /// started it can show progress and refuse to start a second one.
    var badgeAssistIsRunning: Bool = false
    /// True while a saved capture is being re-transcribed from its recording.
    /// The entry is already readable throughout; this only tells the People
    /// screen that a better transcript is on its way.
    var transcriptionIsRunning: Bool = false
    /// True when the session exists only to record (started from the Record
    /// action with nothing else running). No brain is connected, so speech
    /// that is not claimed by a capture is discarded rather than sent to a
    /// provider that was never set up.
    private(set) var recordingOnlySession: Bool = false
    /// Bumped whenever an encounter is saved/edited/deleted so the People
    /// screen re-reads the store.
    var encounterRevision: Int = 0
    var lensSessionRevision: Int = 0
    /// Whether a Mapbox token is stored (drives Settings UI + notices).
    var hasMapboxToken: Bool = MapCredentials.hasToken
    /// The running route, mirrored for the in-app map screen (design 4f).
    /// Nil whenever nothing is being navigated to.
    var activeRoute: NavigationController.RouteSnapshot?
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
        return AssistantBackend(rawValue: raw) ?? .direct
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
    /// Advisories that are NOT failures: a fallback that worked, a HUD that
    /// had to step aside. They went through `showError`, whose alert is
    /// titled "Hermes Error" - which told the user that using the iPhone mic
    /// instead of an absent headset was something that had gone wrong.
    var showNotice: Bool = false
    var noticeMessage: String = ""

    /// Hermes Agent WebSocket endpoint
    var hermesEndpoint: String {
        (UserDefaults.standard.string(forKey: "hermes_endpoint")
            ?? "ws://localhost:8765/voice")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Constants

    /// How long the speaker's tail is given to fade before the recognizer
    /// listens again. There is no echo cancellation on the phone route (the
    /// audio session runs in `.default`, not `.voiceChat`), so a shorter
    /// wait means transcribing the end of Hermes's own reply.
    private static let speechResumeGraceNanos: UInt64 = 700_000_000

    /// Both mic fallbacks are announced from two places - session start and
    /// a mid-session switch - and must say the same thing in both.
    private static let glassesMicFallbackNotice =
        "Glasses mic not available - using iPhone mic"
    private static let headsetMicFallbackNotice =
        "No headset mic found - using iPhone mic. Connect AirPods or another Bluetooth headset first."
    /// Said from three places - session start, a mid-session switch, and the
    /// kit failing to bring its mic back after a still - so it lives here too.
    private static let aiseeMicFallbackNotice =
        "AiSee glasses mic unavailable — using iPhone mic"

    /// How many times a mic reopen may be deferred because the kit is mid-still
    /// before the session gives up and takes the iPhone mic. 3 × 1.5 s.
    private static let aiseeMicRecoveryAttempts = 3

    private static let micSourceKey = "mic_source"
    private static let endpointPresetsKey = "endpoint_presets"

    // MARK: - Private

    @ObservationIgnored private let wearables: WearablesInterface
    @ObservationIgnored private var deviceSelector: AutoDeviceSelector
    @ObservationIgnored private var deviceSession: DeviceSession?
    @ObservationIgnored private let audioManager = HermesAudioManager()
    @ObservationIgnored private var apiClient: HermesAPIClient?
    @ObservationIgnored private var sessionObserverTask: Task<Void, Never>?
    @ObservationIgnored private let cameraManager = HermesCameraManager()
    @ObservationIgnored private let phoneCameraManager = PhoneCameraManager()
    /// AiSee glasses (second vendor). Owned here like the Meta managers; the
    /// Devices page reads `aisee` for connect/scan/battery.
    let aisee: AiSeeConnectionService
    @ObservationIgnored private let aiseeCoordinator: AiSeeDeviceCoordinator
    @ObservationIgnored private let aiseeCamera: AiSeeCameraSource
    /// Last seen "is the kit connected" - the handler must react to the
    /// TRANSITION, not to the state it finds. A real link drop runs
    /// `.disconnected` -> `startScan()` -> `.scanning` synchronously inside
    /// the kit, so by the time the observer's main-actor hop runs, the
    /// absolute state is `.scanning` and the drop would go unnoticed.
    @ObservationIgnored private var aiseeWasConnected = false
    /// True after `AiSeeError.deviceWedged` until the kit reconnects - only a
    /// power cycle clears the camera wedge, so the route stays out of service.
    var aiseeWedged = false
    /// Whether the RUNNING session is actually listening through the kit's mic.
    /// `usingAiSeeMic` describes what is selectable right now and reads
    /// `aisee.state`, which is already `.disconnected` by the time a drop is
    /// handled - so the teardown decision needs this remembered fact instead.
    @ObservationIgnored private var sessionUsesAiSeeMic = false
    /// Pending "did the kit's mic actually come back?" check. At most one:
    /// a newer coordinator state supersedes whatever the last one queued.
    @ObservationIgnored private var aiseeMicRecoveryTask: Task<Void, Never>?
    /// Bumped by every schedule and every cancel. A check that is already past
    /// its `Task.isCancelled` gate when a newer state arrives still stands
    /// down on this, and only the check whose generation is current may clear
    /// `aiseeMicRecoveryTask` - otherwise a late one nils a newer one's handle
    /// and that check can no longer be cancelled at all.
    @ObservationIgnored private var aiseeMicRecoveryGeneration = 0
    @ObservationIgnored private let speechRecognizer = HermesSpeechRecognizer()
    @ObservationIgnored private let speechSynthesizer = HermesSpeechSynthesizer()
    @ObservationIgnored private let directClient = DirectClient()
    @ObservationIgnored private let displayManager = HermesDisplayManager()
    @ObservationIgnored private let contextProvider = DeviceContextProvider()
    @ObservationIgnored private let navigation = NavigationController()
    @ObservationIgnored private let encounterStore = EncounterStore()
    @ObservationIgnored private let lensSessionStore = LensSessionStore()
    /// In-flight glasses capture for the encounter whose note we're awaiting.
    /// Joined by `finishEncounter`, so the note and the photo can land in
    /// either order.
    @ObservationIgnored private var encounterPhotoTask: Task<Data?, Never>?
    /// Fires if no note arrives - saves the photo with an empty note.
    @ObservationIgnored private var encounterTimeoutTask: Task<Void, Never>?
    // Conversation capture ("record this conversation"): pure state plus
    // the vision pipeline (live stream → person detections → dwell) that
    // feeds it. All torn down by `stopCaptureVision()`.
    @ObservationIgnored private var captureModel = ConversationCaptureModel()
    @ObservationIgnored private var capturePhotos: [Data] = []
    /// Portraits cropped off badges during the running capture. Parallel to
    /// capturePhotos and deliberately NOT merged into it - see
    /// EncounterStore.save.
    @ObservationIgnored private var capturePortraits: [Data] = []
    @ObservationIgnored private var captureDetector: ObjectDetector?
    @ObservationIgnored private var captureDwell: DwellTracker?
    @ObservationIgnored private var captureLatestFrame: UIImage?
    /// Writes the capture's audio to disk. The transcript is made from this
    /// file afterwards, not from the live recogniser - see
    /// `ConversationRecorder` for why.
    @ObservationIgnored private let recorder = ConversationRecorder()
    /// Where the running capture is recording, before the encounter exists to
    /// name the file after.
    @ObservationIgnored private var captureRecordingURL: URL?
    /// The post-capture transcription pass. Outlives the capture: the
    /// encounter is already saved and this only improves its transcript.
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var captureStreamRunning = false
    @ObservationIgnored private var captureSetupTask: Task<Void, Never>?
    /// The deferred badge-assist pass. Outlives the capture on purpose - the
    /// encounter is already saved and this only fills in names.
    @ObservationIgnored private var badgeAssistTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPhoto: Data?
    /// Last photo sent in Direct mode, reused only when a fresh capture fails.
    @ObservationIgnored private var lastDirectPhoto: Data?
    @ObservationIgnored private var lastDirectPhotoAt: Date?
    @ObservationIgnored private var pendingDefinitionSubject: String?
    @ObservationIgnored private var definitionGeneration = 0
    /// Camera-only session owned by the Lens view (nil while the voice
    /// session provides the camera, or when Lens is closed).
    @ObservationIgnored private var lensSession: DeviceSession?

    /// Exposed for UI to show audio route
    var audio: HermesAudioManager { audioManager }

    /// The glasses camera specifically - only for code that needs the DAT
    /// lifecycle (session configure/reset). Everything that just wants to
    /// SEE should use `vision`.
    var camera: HermesCameraManager { cameraManager }

    /// The iPhone camera, for the phone-mode screen's status tiles.
    var phoneCamera: PhoneCameraManager { phoneCameraManager }

    /// Whichever eye is active. Every camera feature goes through this, so
    /// phone mode reaches all of them without per-call-site branching.
    var vision: VisionSource {
        if visionRoute == .phone { return phoneCameraManager }
        return glassesVendor == .aisee ? aiseeCamera : cameraManager
    }

    /// Pinned once a session (or the Lens view) commits to an eye, so a
    /// momentary SDK flap cannot redirect a capture to a camera that isn't
    /// running - the bug behind "remember this person" saving a note with no
    /// photo.
    @ObservationIgnored private var pinnedVisionRoute: VisionRoute?

    /// Which eye is in use, or would be if a session started now.
    var visionRoute: VisionRoute {
        pinnedVisionRoute ?? VisionRouting.route(
            glassesEligible: glassesAvailable, preference: phoneModePreference
        )
    }

    /// False only when the fallback is off and no glasses are reachable.
    var canStartSession: Bool {
        VisionRouting.canStartSession(
            glassesEligible: glassesAvailable, preference: phoneModePreference
        )
    }

    /// Is there an eye at all right now? The iPhone camera is always
    /// present; the glasses need a live session.
    var hasVisionSource: Bool {
        visionRoute == .phone || isGlassesConnected
    }

    /// Permission for whichever eye is active. These are two different
    /// grants from two different places - the glasses camera is authorised
    /// through the Meta AI companion app, the iPhone camera through iOS - so
    /// asking the glasses authority about a phone-mode capture always said
    /// no. That is why "remember this person" saved a note with no photo.
    func ensureVisionPermission(interactive: Bool) async -> Bool {
        switch visionRoute {
        case .glasses:
            return await ensureCameraPermission(interactive: interactive)
        case .phone:
            return interactive
                ? await PhoneCameraManager.ensurePermission()
                : PhoneCameraManager.isAuthorized
        }
    }

    /// A still from the active eye, falling back to the other one rather
    /// than returning nothing. "remember this person" saved a note with no
    /// photo because a transient route flip sent the capture to a camera
    /// that wasn't running; a photo from the wrong-but-working camera beats
    /// no photo at all.
    func captureVisionPhoto() async throws -> Data {
        do {
            return try await vision.capturePhoto()
        } catch {
            NSLog("[Hermes] \(visionRoute) capture failed: \(error.localizedDescription)")
            guard VisionRouting.mayFallBackToPhone(preference: phoneModePreference)
            else { throw error }
            switch visionRoute {
            case .glasses:
                NSLog("[Hermes] falling back to the iPhone camera for this photo")
                do {
                    return try await phoneCameraManager.capturePhoto()
                } catch {
                    NSLog("[Hermes] iPhone fallback photo ALSO failed - \(error.localizedDescription)")
                    throw error
                }
            case .phone:
                // The phone was the route and it failed; the glasses can only
                // help if a session is actually up.
                guard deviceSession != nil || lensSession != nil else { throw error }
                return try await cameraManager.capturePhoto()
            }
        }
    }

    /// Commit to an eye and hold it until `unpinVisionRoute()`.
    func pinVisionRoute(_ route: VisionRoute) { pinnedVisionRoute = route }

    func unpinVisionRoute() { pinnedVisionRoute = nil }

    /// Mirrors `AutoDeviceSelector.activeDevice`, which lives on an SDK
    /// object and is therefore invisible to SwiftUI's observation. Reading
    /// it directly meant the launch screen rendered once while the SDK was
    /// still discovering, saw nil, and never re-read - so the glasses looked
    /// unreachable until some *other* state change forced a redraw (toggling
    /// the eye to Phone and back, which is exactly how this was spotted).
    private(set) var activeGlassesDevice: DeviceIdentifier?

    /// Meta glasses in range and session-able right now, or already held by
    /// a session. Status UI only - "paired" is not this (see
    /// `glassesAvailable`), and neither is `isGlassesConnected`, which stays
    /// false until a session claims the glasses.
    var metaGlassesReachable: Bool {
        activeGlassesDevice != nil || isGlassesConnected
    }

    @ObservationIgnored private var activeDeviceTask: Task<Void, Never>?

    /// Can a glasses session actually be created right now?
    ///
    /// This asks the SDK's OWN selector - the same object `createSession`
    /// resolves a device through - rather than inferring from pairing state.
    /// `registrationState == .registered && !devices.isEmpty` was the first
    /// attempt and it is wrong: glasses that are paired but out of range
    /// satisfy it while `createSession` throws `noEligibleDevice`, which is
    /// why Auto never fell back.
    var glassesAvailable: Bool {
        GlassesVendor.glassesEligible(
            vendor: glassesVendor,
            metaDeviceActive: activeGlassesDevice != nil,
            aiseeConnected: aisee.state.isConnected,
            aiseeWedged: aiseeWedged)
    }

    /// Everything the SDK will tell us about eligibility, in one line, so a
    /// device log shows WHY a route was chosen. Diagnostic only.
    var visionDiagnostics: String {
        let links = wearables.devices.map { id -> String in
            guard let device = wearables.deviceForIdentifier(id) else { return "?" }
            return "\(device.nameOrId())=\(device.linkState)"
        }.joined(separator: ",")
        return """
        VISIONDIAG registration=\(wearables.registrationState) \
        devices=\(wearables.devices.count) [\(links)] \
        activeDevice=\(activeGlassesDevice ?? "nil") \
        glassesAvailable=\(glassesAvailable) route=\(visionRoute) \
        pref=\(phoneModePreference.rawValue) phoneModeActive=\(phoneModeActive) \
        voiceSession=\(deviceSession != nil) lensSession=\(lensSession != nil) \
        connection=\(connectionState) mic=\(micSource.rawValue) \
        display=\(displayStatus) hudEnabled=\(displayHUDEnabled) \
        glassesStreaming=\(cameraManager.isStreaming) \
        captureStream=\(captureStreamRunning) recording=\(conversationCaptureActive)
        """
    }

    func logVisionDiagnostics(_ context: String) {
        NSLog("[Hermes] \(context) \(visionDiagnostics)")
    }

    /// True while a phone-mode session is running - drives the 5b screen.
    var phoneModeActive: Bool = false

    /// Set when the phone camera could not start (permission, hardware).
    /// The session still runs; only visual queries are affected.
    var phoneCameraError: String?

    /// Latest phone-camera frame, for the 5b feed.
    var phoneFeedImage: UIImage?

    /// Extra consumers of the running phone-mode stream, keyed so the Lens
    /// screen and conversation capture can both watch without clobbering
    /// each other. iOS gives one AVCaptureSession per camera, so a second
    /// consumer must share rather than start its own.
    @ObservationIgnored private var visionFrameObservers:
        [String: (VisionFrame) -> Void] = [:]

    func addVisionFrameObserver(
        _ key: String, _ handler: @escaping (VisionFrame) -> Void
    ) {
        visionFrameObservers[key] = handler
    }

    func removeVisionFrameObserver(_ key: String) {
        visionFrameObservers.removeValue(forKey: key)
    }

    /// True when a shared stream is already running, so a would-be consumer
    /// should observe it instead of calling `startLiveStream`.
    var visionStreamIsShared: Bool {
        visionRoute == .phone && phoneModeActive
    }

    /// Mirrors `displayManager.content` so SwiftUI can render the simulated
    /// lens. Updated even with no glasses attached.
    var lensContent: LensContent = .blank

    /// Auto / Always / Off (design 5a). Auto is the fallback the session
    /// screen relies on.
    var phoneModePreference: PhoneModePreference = PhoneModePreference(
        rawValue: UserDefaults.standard.string(forKey: PhoneModePreference.storageKey) ?? ""
    ) ?? .auto {
        didSet {
            UserDefaults.standard.set(
                phoneModePreference.rawValue, forKey: PhoneModePreference.storageKey
            )
        }
    }

    /// Which glasses the glasses route means. Switching tears down any live
    /// session - the two vendors have nothing in common below VisionSource.
    var glassesVendor: GlassesVendor = GlassesVendor.load() {
        didSet {
            guard oldValue != glassesVendor else { return }
            UserDefaults.standard.set(glassesVendor.rawValue, forKey: GlassesVendor.storageKey)
            // The teardown stays SYNCHRONOUS. `vision`, `glassesAvailable` and
            // the eligibility helpers all report the new vendor the instant
            // this setter returns, so any hop here opens a window in which the
            // OLD vendor's session is live under the NEW vendor's rules.
            if isGlassesConnected || connectionState != .disconnected { endSession() }
            // Lens can be streaming with no session at all, and `endSession()`
            // is where that stream is normally stopped - so a Lens-only stream
            // survives a vendor switch unless it is stopped here too. It
            // belongs to the vendor just left either way, and is a no-op
            // under Meta.
            aiseeCamera.stopLiveStream()
            // Only the genuinely async tail defers: both mic hops already had
            // to, and neither they nor the reconnect race the teardown above.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.micSource == .aiseeGlasses && self.glassesVendor != .aisee {
                    await self.setMicSource(.phone)
                }
                if self.micSource == .glasses && self.glassesVendor == .aisee {
                    await self.setMicSource(.phone)
                }
                if self.glassesVendor == .aisee { self.aisee.reconnectLastDevice() }
            }
        }
    }

    var glassesSupportsDisplay: Bool { glassesVendor.supportsDisplay }

    /// Does the pair in use actually have a lens? `glassesSupportsDisplay` is
    /// the VENDOR answer (Meta can); this is the DEVICE answer - Ray-Ban Meta
    /// without Display has no HUD for the hands-free call screen to cover, so
    /// the glasses mic must neither pause a HUD nor be switched away from.
    /// Unknown device counts as Display, so the HUD rule is never skipped
    /// for glasses it applies to.
    var activeGlassesHaveDisplay: Bool {
        guard glassesVendor.supportsDisplay else { return false }
        guard let id = activeGlassesDevice,
              let device = wearables.deviceForIdentifier(id) else { return true }
        return device.supportsDisplay()
    }

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables)
        self.activeGlassesDevice = self.deviceSelector.activeDevice
        // os_log, not NSLog: this is what shows up in the device syslog.
        let aiseeLogger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "aisee")
        let aiseeLog: AiSeeLog = { line in aiseeLogger.notice("\(line, privacy: .public)") }
        let coordinator = AiSeeDeviceCoordinator(log: aiseeLog)
        self.aisee = AiSeeConnectionService(log: aiseeLog)
        self.aiseeCoordinator = coordinator
        self.aiseeCamera = AiSeeCameraSource(coordinator: coordinator)
        self.aiseeWasConnected = self.aisee.state.isConnected
        reloadDirectProviderState()
        observeActiveDevice()
        // Wired at init, NOT at session start: the map screen can start a
        // route with no session running, and with these nil the route
        // computed fine but nothing received it - the banner just sat on
        // "No route running" and failures were silent.
        wireDisplayAndNavigation()
        aiseeCamera.onWedged = { [weak self] in
            Task { @MainActor in
                self?.aiseeWedged = true
                self?.show(AiSeeError.deviceWedged.localizedDescription)
            }
        }
        // The kit is the only thing that knows whether its mic is really open:
        // it closes and reopens it around every still, and that reopen can
        // fail. Mirror the transitions so a mic that does not come back is
        // noticed instead of leaving a session that listens to nothing.
        // `coordinator` (not `self.aiseeCoordinator`) so the setup Task holds
        // nothing; the observer itself is weak.
        Task {
            await coordinator.setStateObserver { [weak self] micOpen, streaming in
                Task { @MainActor in
                    self?.handleAiSeeCoordinatorState(
                        micOpen: micOpen, streaming: streaming
                    )
                }
            }
        }
        observeAiSeeConnection()
        Task { [weak self] in
            await self?.aiseeCoordinator.setKeyPressObserver { index in
                Task { @MainActor [weak self] in self?.handleGlassesKeyPress(index) }
            }
            // Every clip end arrives here - the stop button, the length cap,
            // the stream dying, a disconnect - so saving has one path.
            await self?.aiseeCoordinator.setClipObserver { file, interruption in
                Task { @MainActor [weak self] in
                    self?.clipDidEnd(file: file, interruption: interruption)
                }
            }
        }
        // The stored mic source outlives the app, the vendor setting can be
        // changed while it is closed, and `glassesVendor.didSet` only fires on
        // a live switch - so a launch can come up with a mic source that's
        // unroutable under the loaded vendor (AiSee mic under Meta, or Meta's
        // HFP call screen under AiSee). Reconcile both here, once, at load.
        if micSource == .aiseeGlasses && glassesVendor != .aisee {
            micSource = .phone
            UserDefaults.standard.set(
                MicSource.phone.rawValue, forKey: Self.micSourceKey
            )
        }
        if micSource == .glasses && glassesVendor == .aisee {
            micSource = .phone
            UserDefaults.standard.set(
                MicSource.phone.rawValue, forKey: Self.micSourceKey
            )
        }
        if glassesVendor == .aisee { aisee.reconnectLastDevice() }
    }

    deinit {
        sessionObserverTask?.cancel()
        activeDeviceTask?.cancel()
        aiseeMicRecoveryTask?.cancel()
    }

    /// Keep `activeGlassesDevice` live. Eligibility changes whenever the
    /// glasses wake, sleep, or wander out of Bluetooth range, and every one
    /// of those must reach the UI without the user poking something.
    private func observeActiveDevice() {
        let stream = deviceSelector.activeDeviceStream()
        activeDeviceTask = Task { [weak self] in
            for await device in stream {
                guard let self, !Task.isCancelled else { return }
                if self.activeGlassesDevice != device {
                    self.activeGlassesDevice = device
                    NSLog("[Hermes] activeDevice → \(device ?? "nil")")
                    // Glasses just became usable - re-check the camera grant
                    // so the warning under the toggle is true rather than
                    // whatever was cached at launch.
                    if device != nil {
                        await self.refreshGlassesCameraStatus()
                    }
                }
            }
        }
    }

    /// Keeps the coordinator attached to the live AiSee connection and mirrors
    /// drops into session state. `withObservationTracking` fires once per
    /// change, so it re-arms itself.
    private func observeAiSeeConnection() {
        withObservationTracking {
            _ = aisee.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleAiSeeStateChange()
                self.observeAiSeeConnection()
            }
        }
    }

    private func handleAiSeeStateChange() {
        let nowConnected = aisee.state.isConnected
        defer { aiseeWasConnected = nowConnected }
        guard nowConnected != aiseeWasConnected else { return }
        if nowConnected {
            aiseeWedged = false
            #if canImport(RTKAIDeviceConnection)
            let connection = aisee.connection
            Task { await aiseeCoordinator.attach(connection) }
            #endif
        } else {
            Task { await aiseeCoordinator.detach() }
            // The mic counts as much as the camera. On the phone-camera route
            // (or after a wedge) `isGlassesConnected` is false while the kit's
            // mic is still the session's ONLY input, so gating on the camera
            // alone left `HermesAudioManager` in external mode with nothing
            // feeding it: a "Listening" session that cannot hear.
            if glassesVendor == .aisee && (isGlassesConnected || sessionUsesAiSeeMic) {
                endSession()
            }
        }
    }

    /// The kit's own view of its mic and stream, including changes nobody
    /// asked for. A `false` here is not automatically a fault: the still-photo
    /// plan closes and reopens the mic around every shot, and the reopen path
    /// is the kit's job, not ours. So wait out its reopen before concluding
    /// the session has gone deaf - and re-check with the coordinator rather
    /// than trusting the value this callback carried.
    private func handleAiSeeCoordinatorState(micOpen: Bool, streaming: Bool) {
        // Whatever the previous state queued is stale now.
        cancelAiSeeMicRecovery()
        guard sessionUsesAiSeeMic, connectionState != .disconnected,
              !micOpen else { return }
        scheduleAiSeeMicRecovery(attempt: 1)
    }

    /// Stand down any pending reopen check. Bumping the generation matters as
    /// much as the cancel: a check that has already cleared its
    /// `Task.isCancelled` gate can only be stopped by the generation.
    private func cancelAiSeeMicRecovery() {
        aiseeMicRecoveryTask?.cancel()
        aiseeMicRecoveryTask = nil
        aiseeMicRecoveryGeneration &+= 1
    }

    private func scheduleAiSeeMicRecovery(attempt: Int) {
        aiseeMicRecoveryGeneration &+= 1
        let generation = aiseeMicRecoveryGeneration
        aiseeMicRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.recoverAiSeeMicrophone(
                attempt: attempt, generation: generation
            )
        }
    }

    /// The kit did not bring its mic back on its own. Try again, and put the
    /// session on the iPhone mic rather than leave it listening to nothing.
    /// Idempotent: a mic that reopened meanwhile is left alone.
    private func recoverAiSeeMicrophone(attempt: Int, generation: Int) async {
        // `Task.sleep` returns on cancellation too, and the caller's
        // `isCancelled` check is a hop old by now - re-check both here, where
        // the decision is actually taken.
        guard !Task.isCancelled,
              generation == aiseeMicRecoveryGeneration else { return }
        // Ours to clear, precisely because the generation is still current.
        aiseeMicRecoveryTask = nil
        guard sessionUsesAiSeeMic, connectionState != .disconnected else { return }
        if await aiseeCoordinator.micOpen { return }
        do {
            try await startAiSeeMicrophone()
        } catch AiSeeError.captureInProgress
                    where attempt < Self.aiseeMicRecoveryAttempts {
            // A still is mid-plan. The kit closes the mic around every shot
            // and reopens it itself, so this refusal means "not yet", not
            // "never" - demoting on it would take the glasses mic away for
            // the length of a photo.
            Logger(subsystem: "com.flowsxr.hermesglasses", category: "aisee").notice("AiSee mic reopen deferred, capture in progress (attempt \(attempt))")
            scheduleAiSeeMicRecovery(attempt: attempt + 1)
        } catch {
            Logger(subsystem: "com.flowsxr.hermesglasses", category: "aisee").notice("AiSee mic did not reopen: \(error.localizedDescription)")
            do {
                try await fallBackToPhoneMic(
                    notice: Self.aiseeMicFallbackNotice, stoppingCapture: true
                )
                speechRecognizer.restartCycle()
            } catch {
                show("Audio setup failed: \(error.localizedDescription)")
                endSession()
            }
        }
    }

    // MARK: - Public API

    /// Bring up mic + camera + lens for recording ONLY - no bridge, no
    /// provider, no TTS answers.
    ///
    /// Recording a conversation uses none of the query path, so demanding a
    /// full voice session first (which is what the Record chip's
    /// `connectionState != .disconnected` gate amounted to) made the feature
    /// unreachable until the user had connected a brain they were not going
    /// to use. Same lesson as the test panel: a thing that works standalone
    /// must start standalone.
    func startSessionForRecording() async {
        recordingOnlySession = true
        await startSession(engagingBrain: false)
        if connectionState == .disconnected { recordingOnlySession = false }
    }

    func startSession() async {
        recordingOnlySession = false
        await startSession(engagingBrain: true)
    }

    private func startSession(engagingBrain: Bool) async {
        // The voice session owns the glasses from here on - a Lens-created
        // camera session must not compete with it. (UI-wise Lens can't be
        // open when this button is reachable; this is belt-and-braces.)
        releaseCameraSession()

        connectionState = .connecting

        logVisionDiagnostics("startSession")
        var route = visionRoute

        if route == .glasses, await connectGlassesSession() == false {
            // Eligibility can lapse between the check and the start, and the
            // SDK is the only one who knows. Rather than leaving the user at
            // "No eligible device available" with no way forward, drop to the
            // phone - unless they explicitly turned that off.
            guard VisionRouting.mayFallBackToPhone(preference: phoneModePreference) else {
                connectionState = .disconnected
                return
            }
            show(notice: "Glasses unreachable - using this iPhone as the eye.")
            route = .phone
        }

        pinVisionRoute(route)
        phoneModeActive = route == .phone

        if route == .phone {
            // No DeviceSession, no display attach - the phone is the eye and
            // the lens is simulated on screen (design 5b).
            await startPhoneVision()
        }

        // Personal context (time/location/motion/battery/weather) -
        // requests location permission on first use
        contextProvider.start()

        // 2. Connect the brain. Direct mode needs no server at all -
        // skip the bridge entirely. A recording-only session skips both:
        // nothing it captures is ever sent anywhere.
        if !engagingBrain {
            // nothing to connect
        } else if backend == .direct {
            guard !directProvider.requiresKey || DirectClient.hasKey(for: directProvider.id) else {
                show("No API key set for \(directProvider.displayName). Add one in Settings.")
                endSession()
                return
            }
        } else {
            // Bridge mode: connect with all callbacks wired up first
            let client = makeBridgeClient()
            apiClient = client

            let connected = await client.connect()
            guard connected else {
                show("Failed to connect to Hermes bridge at \(hermesEndpoint)")
                endSession()
                return
            }

            // Wired only once the socket is up. `connect()` calls
            // `disconnect()` on its own failure path, and the guard above
            // already reports that - wiring earlier would report it twice.
            client.onDisconnected = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.connectionState != .disconnected else { return }
                    // Without this the UI sat on "Listening" forever while
                    // every utterance was dropped at submitQuery's
                    // isConnected guard - silence indistinguishable from
                    // Hermes having nothing to say.
                    self.liveTranscript = ""
                    self.endSession()
                    self.show("Lost the connection to the Hermes bridge. Start listening again to reconnect.")
                }
            }
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
                self.displayManager.replySpeakingFinished()
                if case .speaking = self.connectionState {
                    self.connectionState = .listening
                }
                // Grace period: let the speaker's tail fade before the mic
                // listens again, or the recognizer hears the end of the TTS
                try? await Task.sleep(nanoseconds: Self.speechResumeGraceNanos)
                self.speechRecognizer.isSuspended = false
            }
        }

        // On-device TTS finished (or was interrupted) - same completion
        // flow as bridge-audio playback
        speechSynthesizer.onVoiceFallback = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.show(notice: "ElevenLabs voice is off, using the iPhone voice instead: \(message)")
            }
        }
        speechSynthesizer.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A queued cue speaks next with the recognizer still
                // suspended: state stays .speaking, no grace gap in between.
                if case .speaking = self.connectionState, !self.cueQueue.isEmpty {
                    self.speechSynthesizer.speak(self.cueQueue.removeFirst())
                    return
                }
                self.displayManager.replySpeakingFinished()
                if case .speaking = self.connectionState {
                    self.connectionState = .listening
                }
                try? await Task.sleep(nanoseconds: Self.speechResumeGraceNanos)
                // A cue that started during the grace owns the suspension.
                if case .speaking = self.connectionState { return }
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
            if glassesVendor == .aisee && micSource == .aiseeGlasses {
                // The AiSee mic is not an iOS input route: the kit streams
                // PCM over its own link. Open the audio session for
                // playback+record (so TTS still plays), then let the kit push
                // buffers into the same pipeline the engine tap feeds.
                //
                // Glasses that are absent, wedged or busy demote the session
                // to the iPhone mic - they NEVER take the voice loop down with
                // them. Ending the session here made "AiSee mic selected, no
                // glasses on the table" an app that refuses to listen at all.
                if usingAiSeeMic {
                    do {
                        try await audioManager.startExternalCapture()
                        try await startAiSeeMicrophone()
                        sessionUsesAiSeeMic = true
                    } catch {
                        Logger(subsystem: "com.flowsxr.hermesglasses", category: "aisee").notice("AiSee mic unavailable: \(error.localizedDescription)")
                        try await fallBackToPhoneMic(
                            notice: Self.aiseeMicFallbackNotice,
                            stoppingCapture: true
                        )
                    }
                } else {
                    // The glasses are simply not there. Take the phone route
                    // up front - opening external capture first would only
                    // arm `ingest` for a mic that is never going to send.
                    try await fallBackToPhoneMic(
                        notice: Self.aiseeMicFallbackNotice,
                        stoppingCapture: false
                    )
                }
            } else {
                let bluetoothActive = try await audioManager.startCapture(
                    route: micSource.captureRoute
                )
                if micSource == .glasses && !bluetoothActive {
                    show(notice: Self.glassesMicFallbackNotice)
                }
                if micSource == .headset && !bluetoothActive {
                    show(notice: Self.headsetMicFallbackNotice)
                }
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
        // (a headset's hands-free link does not). In phone mode there is no
        // DeviceSession to attach to; the simulated lens reads
        // `displayManager.content` instead, which updates either way.
        if glassesVendor.supportsDisplay, let session = deviceSession,
           displayHUDEnabled, !lensBlockedByCallScreen {
            // stop() first: a standalone Display test may still hold an
            // attachment to its temporary session
            displayManager.stop()
            displayManager.start(session: session)
        }

        // Bridge connected, mic live, recognizer running
        connectionState = .listening
    }

    /// Every bridge callback in one place, so `startSession` reads as the
    /// sequence of steps it is. Returns the client ready to `connect()`.
    private func makeBridgeClient() -> HermesAPIClient {
        let client = HermesAPIClient(endpoint: hermesEndpoint)

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
                self.completeTestOutcome(.success(()))
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
                try? await Task.sleep(nanoseconds: Self.speechResumeGraceNanos)
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
                // Fail fast if the camera permission is missing - the
                // interactive grant needs an app switch, which can't happen
                // inside the bridge's photo wait.
                guard await self.ensureVisionPermission(interactive: false) else {
                    self.apiClient?.sendPhotoError(
                        self.visionRoute == .phone
                            ? "Camera access is off for Hermes. Turn it on in iOS Settings."
                            : "Camera permission not granted. Tap the Photo test button to grant access via Meta AI."
                    )
                    return
                }
                do {
                    self.displayManager.showPhotoCaptured()
                    let photo = try await self.captureVisionPhoto()
                    self.pendingPhoto = photo
                    self.apiClient?.sendPhoto(photo)
                } catch {
                    self.apiClient?.sendPhotoError(error.localizedDescription)
                }
            }
        }

        return client
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

        // A running conversation capture claims every utterance next: it is
        // all transcript until the stop command - nothing reaches the AI.
        if conversationCaptureActive {
            if IntentDetector.isConversationStop(trimmed) {
                finishConversationCapture()
            } else {
                captureModel.addLine(trimmed, at: Date())
                liveTranscript = ""
            }
            // No brain will answer this, so a Developer-panel test waiting on
            // a reply would sit out its full timeout. Tell it now.
            completeTestOutcome(.failure(TestFailure(
                "A conversation recording is claiming every utterance - stop the recording before running this test."
            )))
            return
        }

        // A Build Check run claims every utterance, like a capture.
        if let claim = buildRunClaimer, claim(trimmed) {
            liveTranscript = ""
            completeTestOutcome(.failure(TestFailure(
                "A Build Check run is claiming every utterance - end the run before running this test."
            )))
            return
        }

        // "start build check" needs no brain, so it must work in a
        // recording-only session too (Build Check starts one itself).
        if case .startBuildCheck = IntentDetector.detect(trimmed) {
            liveTranscript = ""
            lastTranscript = trimmed
            onStartBuildCheck?()
            return
        }

        // A recording-only session has no brain wired up. Anything not
        // claimed by the capture above (an utterance in the gap before
        // recording starts, or after it stops) is dropped here rather than
        // dispatched to a provider this session never connected.
        guard !recordingOnlySession else {
            liveTranscript = ""
            completeTestOutcome(.failure(TestFailure(
                "This session was started for recording only - no brain is connected to answer."
            )))
            return
        }

        // Bump so an in-flight definition-image fetch from a prior utterance
        // can't paint over this new query or navigation.
        definitionGeneration &+= 1

        // The machine guide answers from an imported manual instead of the
        // brain. While it is on it takes EVERY utterance ("go to step five"
        // must not start a navigation); from cold it takes only its own
        // start phrases.
        if let claim = machineGuideClaimer, claim(trimmed) {
            return
        }

        // On-device intents run before the AI brain.
        switch IntentDetector.detect(trimmed) {
        case .rememberPerson where socialNotesEnabled:
            liveTranscript = ""
            lastTranscript = trimmed
            startEncounter()
            return
        case .startConversationCapture where socialNotesEnabled:
            liveTranscript = ""
            lastTranscript = trimmed
            startConversationCapture()
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
            ElevenLabsVoice.warmUp()
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
                // With the ElevenLabs voice on, the PHONE speaks the reply -
                // asking the bridge for audio too would say it twice.
                bridgeTTS: !useDeviceTTS && !ElevenLabsVoice.isActive && !displaySilentActive
            )
        }
    }

    /// Direct mode: photo decision + capture happen locally, then one
    /// API call - no server round trips.
    private func askDirect(_ text: String, context: String? = nil) async {
        var photo: Data?
        // A visual query always gets a FRESH photo: the model's history is
        // text-only, so the memory window that skipped a re-shoot left the
        // model blind ("I can't see a photo") for any deictic question asked
        // within two minutes of the last one. The window now only decides
        // whether a failed capture may fall back to the previous photo.
        if VisualQueryDetector.shouldCapturePhoto(text, lastPhotoAt: nil),
           hasVisionSource,
           await ensureVisionPermission(interactive: false) {
            displayManager.showPhotoCaptured()
            photo = try? await captureVisionPhoto()
            if photo != nil {
                lastDirectPhotoAt = Date()
                lastDirectPhoto = photo
                pendingPhoto = photo
            } else if let recent = lastDirectPhoto, let at = lastDirectPhotoAt,
                      Date().timeIntervalSince(at) <= VisualQueryDetector.photoMemoryWindow {
                photo = recent
            }
        }

        do {
            let reply = try await speakStreaming(
                directClient.askStream(text, photoJPEG: photo, contextLine: context))
            completeReply(userText: text, reply)
        } catch {
            show(error.localizedDescription)
            connectionState = .listening
            speechRecognizer.isSuspended = false
            displayManager.clear()
        }
    }

    // MARK: External brains (the machine guide)

    /// A feature that answers a spoken question ITSELF - not through the
    /// bridge or `askDirect` - enters and leaves the voice loop through
    /// these three, so the state machine, the chat, the lens and TTS behave
    /// exactly as they do for an ordinary answer.
    func beginExternalQuery(_ text: String) {
        ElevenLabsVoice.warmUp()
        pendingDefinitionSubject = nil
        if navigation.isActive { navigation.displaySuppressed = true }
        liveTranscript = ""
        lastTranscript = text
        connectionState = .processing
        displayManager.showThinking(query: text)
        speechRecognizer.isSuspended = true
    }

    /// Speak and show `reply`. A no-op if the session ended (or moved on)
    /// while the answer was being fetched - a reply must never be spoken
    /// into a session that is no longer waiting for one.
    func finishExternalQuery(userText: String, reply: String, photo: Data?) {
        guard connectionState == .processing else { return }
        pendingPhoto = photo
        lastResponse = reply
        addTurn(userText: userText, agentText: reply)
        completeTestOutcome(.success(()))
        presentReply(reply)
    }

    /// The streamed form: the reply went through `speakStreaming`, which
    /// has usually started speaking it already.
    func finishExternalQuery(userText: String, streamed reply: StreamedReply, photo: Data?) {
        pendingPhoto = photo
        completeReply(userText: userText, reply)
    }

    // MARK: Streamed replies

    /// What `speakStreaming` produced.
    struct StreamedReply {
        /// Everything said: prefix + the model's words (+ a failure line).
        let text: String
        /// The model's words alone - what belongs in a conversation history.
        let body: String
        /// False = nothing was spoken (silent mode, or the session moved
        /// on); the caller still has to present `text`.
        let spoken: Bool
        /// The stream broke after speech had begun; `text` ends in an apology.
        let failed: Bool
    }

    /// Speak a reply WHILE it arrives: each sentence goes to the voice the
    /// moment it is complete, so the wait is for the first sentence, not
    /// the whole answer. `prefix` is spoken at once, before the model has
    /// produced anything ("This is the K9 pump.").
    ///
    /// Throws only if the stream fails before anything was said - the
    /// caller then reports the error its usual way. Once speech has begun a
    /// failure is spoken instead, because the state machine has moved on.
    func speakStreaming(
        prefix: String = "", _ deltas: AsyncThrowingStream<String, Error>
    ) async throws -> StreamedReply {
        let audible = !displaySilentActive
        var chunker = SentenceChunker()
        var body = ""
        var token: Int?

        func say(_ piece: String) {
            guard audible else { return }
            if token == nil {
                // The session ended or moved on while we waited: stay quiet.
                guard connectionState == .processing else { return }
                connectionState = .speaking
                token = speechSynthesizer.beginStream()
                if audioManager.isUsingBluetoothInput {
                    // Glasses echo-cancel their own speaker - barge-in stays on
                    speechRecognizer.isSuspended = false
                }
            }
            speechSynthesizer.enqueue(piece, stream: token)
        }

        if !prefix.isEmpty { chunker.feed(prefix + " ").forEach(say) }
        do {
            for try await delta in deltas {
                body += delta
                chunker.feed(delta).forEach(say)
            }
        } catch {
            guard token != nil else { throw error }
            let line = "I couldn't finish that answer. \(error.localizedDescription)"
            chunker.flush().forEach(say)
            say(line)
            speechSynthesizer.endStream(stream: token)
            return StreamedReply(text: (prefix + body + " " + line).trimmingCharacters(in: .whitespaces),
                                 body: body, spoken: true, failed: true)
        }
        chunker.flush().forEach(say)
        if token != nil { speechSynthesizer.endStream(stream: token) }
        return StreamedReply(text: prefix + body, body: body, spoken: token != nil, failed: false)
    }

    /// Chat, lens and bookkeeping for a reply that came through
    /// `speakStreaming`. The speech itself is already under way.
    private func completeReply(userText: String, _ reply: StreamedReply) {
        lastResponse = reply.text
        addTurn(userText: userText, agentText: reply.text)
        completeTestOutcome(.success(()))
        guard reply.spoken else {
            // Silent mode shows it; a session that moved on gets nothing.
            if connectionState == .processing { presentReply(reply.text) }
            return
        }
        let shown = HermesDisplayLogic.truncateReply(reply.text)
        let speaking = connectionState == .speaking
        let subject = pendingDefinitionSubject
        pendingDefinitionSubject = nil
        if let subject {
            showDefinitionReply(text: shown, subject: subject, speaking: speaking)
        } else {
            displayManager.showReply(
                text: shown, speaking: speaking,
                dwellSeconds: speaking ? nil : HermesDisplayLogic.readingDwellSeconds(charCount: shown.count)
            )
        }
    }

    /// Store/replace the API key for the current provider (Keychain)
    func setProviderKey(_ key: String) {
        let stored = DirectClient.storeKey(key, for: directProviderID)
        // hasKey re-reads the Keychain, so the badge reflects what is
        // actually there - but a silent failure needs saying out loud.
        hasDirectKey = DirectClient.hasKey(for: directProviderID)
        if !stored, !hasDirectKey {
            show("Could not save the API key to the Keychain.")
        }
    }

    /// "Send now" button - don't wait for the pause detection
    func sendNow() {
        speechRecognizer.finalizeNow()
    }

    /// Stop the running route. Same effect as saying "stop navigation" -
    /// the in-app map screen's End route button calls it.
    func endNavigation() {
        navigation.stop()
    }

    /// Start a route to a place picked from search. Unlike the voice path
    /// this needs no resolution step - the user already chose which "Blue
    /// Bottle" they meant.
    func startNavigation(to place: MKMapItem, mode: TransportMode = .walking) {
        guard navigationEnabled else {
            show("Navigation is switched off in Settings.")
            return
        }
        NSLog("[Hermes] startNavigation to \(place.name ?? "?") mode=\(mode)")
        routeIsBuilding = true
        // announce: false - the route was started by tapping a map, so a
        // spoken "navigating to..." is noise. The lens still shows it.
        navigation.start(place: place, mode: mode, announce: false)
    }

    /// Answer a multiple-choice reply by picking one of its options. Sent
    /// as the option's words, so the transcript reads like a conversation
    /// rather than a row of letters.
    func chooseReplyOption(_ choice: ReplyChoice) {
        interruptSpeech()
        submitQuery(choice.reply)
    }

    /// The options offered by the most recent reply, if any - drives the
    /// chips under the last bubble.
    var replyChoices: [ReplyChoice] {
        guard case .reply(_, _, let choices) = lensContent else { return [] }
        return choices
    }

    /// Switch the running route between walking and driving.
    func setTransportMode(_ mode: TransportMode) {
        navigation.setMode(mode)
    }

    /// True between "route requested" and the first frame (or failure).
    /// Without it a slow geocode is indistinguishable from a dead tap.
    var routeIsBuilding: Bool = false

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

    /// Step 1 for the glasses route: create the DeviceSession, hand the
    /// camera its session, and surface camera permission. Returns false
    /// (having already shown the reason) if the glasses can't be reached.
    private func connectGlassesSession() async -> Bool {
        // AiSee has no DeviceSession: the kit's own connection IS the session,
        // so the glasses route is "connected" the moment the kit is.
        if glassesVendor == .aisee {
            guard aisee.state.isConnected, !aiseeWedged else { return false }
            #if canImport(RTKAIDeviceConnection)
            await aiseeCoordinator.attach(aisee.connection)
            #endif
            isGlassesConnected = true
            return true
        }

        // 1. Create and start a device session with the glasses
        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: deviceSelector)
        } catch {
            NSLog("[Hermes] createSession failed: \(error.localizedDescription)")
            return false
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
            return false
        } catch {
            // Caller decides whether this is fatal or a cue to use the phone,
            // so no alert here - just the breadcrumb.
            NSLog("[Hermes] glasses session failed: \(error.localizedDescription)")
            deviceSession = nil
            return false
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

        return true
    }

    /// Step 1 for the phone route: start the iPhone camera stream that both
    /// the 5b feed and every visual query read from. A failure here is not
    /// fatal - the voice loop is the valuable half.
    private func startPhoneVision() async {
        phoneCameraError = nil
        // One AVCaptureSession, possibly two consumers: the 5b feed always,
        // plus the Lens screen while it is open (see onVisionFrame). Starting
        // a second capture session for Lens would fail - the camera is taken.
        phoneCameraManager.onDebug = { [weak self] message in
            Task { @MainActor [weak self] in self?.apiClient?.sendDebug(message) }
        }
        do {
            try await phoneCameraManager.startLiveStream(
                onFrame: { [weak self] frame in
                    Task { @MainActor [weak self] in
                        guard let self, self.phoneModeActive else { return }
                        if let image = frame.image { self.phoneFeedImage = image }
                        for observe in self.visionFrameObservers.values {
                            observe(frame)
                        }
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.phoneCameraError = message
                    }
                }
            )
        } catch {
            phoneCameraError = error.localizedDescription
        }
    }

    /// Display-HUD and navigation callbacks. Wired for BOTH routes: in phone
    /// mode nothing goes out over BLE, but `displayManager.content` still
    /// updates, which is what the simulated lens renders.
    private func wireDisplayAndNavigation() {
        displayManager.onContentChanged = { [weak self] content in
            self?.lensContent = content
        }
        lensContent = displayManager.content
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
        navigation.onShow = { [weak self] mapURL, title, step, eta, mode in
            self?.displayManager.showNavigation(
                mapURL: mapURL, title: title, step: step, eta: eta, mode: mode)
        }
        // Walk/Drive on the lens re-routes to the same place.
        displayManager.onSetTransportMode = { [weak self] mode in
            self?.navigation.setMode(mode)
        }
        // Tapping an option answers as if it had been spoken.
        displayManager.onChooseReplyOption = { [weak self] choice in
            self?.chooseReplyOption(choice)
        }
        navigation.onRoute = { [weak self] snapshot in
            self?.routeIsBuilding = false
            self?.activeRoute = snapshot
        }
        navigation.onSpeak = { [weak self] text in
            self?.speechSynthesizer.speak(text)
        }
        navigation.onNotice = { [weak self] text in
            self?.show(text)
        }
        navigation.onEnd = { [weak self] in
            guard let self else { return }
            self.activeRoute = nil
            self.routeIsBuilding = false
            self.displayManager.clear()
            // Only hand the mic back if there was a session to hand it back
            // to - a map-screen route can run with nothing else going on.
            guard self.connectionState != .disconnected else { return }
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
            guard let self else { return nil }
            self.logVisionDiagnostics("encounter-photo")
            guard self.hasVisionSource else {
                NSLog("[Hermes] encounter: no vision source - photo skipped")
                return nil
            }
            guard await self.ensureVisionPermission(interactive: false) else {
                NSLog("[Hermes] encounter: \(self.visionRoute) camera permission denied - photo skipped")
                if self.visionRoute == .glasses {
                    self.show(
                        "Saved the note, but the glasses camera isn't allowed yet. "
                        + "Grant it in Settings → Devices → Glasses camera."
                    )
                }
                return nil
            }
            // Note-only is a fine outcome: never lose the encounter over a
            // camera failure.
            return try? await self.captureVisionPhoto()
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

    // MARK: - Conversation capture

    /// "record this conversation": from here until the stop command, every
    /// finalized utterance is appended to one note and a 2 s dwell on a
    /// person snaps their photo into it. The camera side is best-effort -
    /// a transcript-only capture still saves if the stream won't start.
    func startConversationCapture() {
        guard !conversationCaptureActive,
              connectionState != .disconnected else { return }
        guard buildRunClaimer == nil else {
            show(notice: "End the build check before recording a conversation.")
            return
        }
        conversationCaptureActive = true
        captureModel = ConversationCaptureModel()
        capturePhotos = []
        capturePortraits = []
        conversationCaptureSnapCount = 0

        // Audio first: everything below is best-effort decoration around the
        // recording, and the recording is what the transcript is made from.
        let staged = encounterStore.stagingRecordingURL()
        if recorder.start(url: staged) {
            captureRecordingURL = staged
            audioManager.onRecordChunk = { [weak recorder] data in
                // Audio thread. The recorder only enqueues.
                recorder?.append(data)
            }
        } else {
            captureRecordingURL = nil
        }

        if navigation.isActive {
            navigation.displaySuppressed = true
        }
        displayManager.showRecordingStarted()

        // Audible "it's on" cue, unless the lens is doing the talking.
        if displaySilentActive {
            connectionState = .listening
            speechRecognizer.isSuspended = false
        } else {
            connectionState = .speaking
            speechRecognizer.isSuspended = true
            speechSynthesizer.speak("Recording. Say stop recording to save.")
        }

        captureSetupTask = Task { @MainActor [weak self] in
            await self?.startCaptureVision()
        }
    }

    /// UI toggle (the Record chip and the Record quick action) - same paths
    /// as the voice commands, but usable from a cold start.
    ///
    /// Recording a conversation needs the microphone and (optionally) the
    /// camera. It does NOT need the bridge, a provider, TTS or the query
    /// path, so requiring a live voice session first was backwards - the same
    /// mistake the test panel used to make. When nothing is running this
    /// brings up just the mic and starts.
    func toggleConversationCapture() {
        if conversationCaptureActive {
            finishConversationCapture()
            return
        }
        // A running Build Check claims every utterance and owns the session;
        // a capture would steal its utterances and could end the session.
        guard buildRunClaimer == nil else {
            show(notice: "End the build check before recording a conversation.")
            return
        }
        guard connectionState == .disconnected else {
            startConversationCapture()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startSessionForRecording()
            guard self.connectionState != .disconnected else { return }
            self.startConversationCapture()
        }
    }

    /// Spin up the person-snap pipeline: YOLO detector + a persistent live
    /// stream (the same machinery as the Lens view, sharing
    /// HermesCameraManager's single-live-stream slot).
    private func startCaptureVision() async {
        guard hasVisionSource,
              await ensureVisionPermission(interactive: false) else { return }

        let detector = ObjectDetector()
        do {
            try await detector.load()
        } catch {
            return  // transcript-only capture
        }
        guard conversationCaptureActive else { return }

        captureDetector = detector
        captureDwell = DwellTracker()
        detector.onDetections = { [weak self] detections in
            // ObjectDetector calls this on the main queue.
            MainActor.assumeIsolated {
                self?.handleCaptureDetections(detections)
            }
        }

        // Phone mode already streams for the 5b feed, and the camera cannot
        // be opened twice - observe those frames instead of competing.
        if visionStreamIsShared {
            addVisionFrameObserver(Self.captureObserverKey) { [weak self] frame in
                MainActor.assumeIsolated {
                    guard let self, self.conversationCaptureActive else { return }
                    if let image = frame.image { self.captureLatestFrame = image }
                    if let buffer = frame.pixelBuffer {
                        self.captureDetector?.process(buffer)
                    }
                }
            }
            return
        }

        do {
            try await vision.startLiveStream(
                onFrame: { [weak self] frame in
                    // Capture thread - hop to main before touching state.
                    Task { @MainActor [weak self] in
                        guard let self, self.conversationCaptureActive else { return }
                        if let image = frame.image { self.captureLatestFrame = image }
                        if let buffer = frame.pixelBuffer {
                            self.captureDetector?.process(buffer)
                        }
                    }
                },
                onError: { _ in }  // stream death degrades to transcript-only
            )
            captureStreamRunning = true
            // The capture may have been stopped while the camera was waking
            // up - stopCaptureVision saw captureStreamRunning == false then,
            // so the just-started stream is ours to tear down.
            if !conversationCaptureActive {
                vision.stopLiveStream()
                captureStreamRunning = false
            }
        } catch {
            // Lens view may own the stream, or the camera is asleep - the
            // transcript is the valuable half; keep going without photos.
            captureDetector?.onDetections = nil
            captureDetector = nil
            captureDwell = nil
        }
    }

    /// A detection batch during capture: person boxes only → dwell → snap.
    private func handleCaptureDetections(_ detections: [Detection]) {
        guard conversationCaptureActive, let dwell = captureDwell else { return }
        let now = CACurrentMediaTime()
        let update = dwell.update(
            detections: ConversationCaptureModel.people(detections), at: now
        )
        guard let snap = update.snap, let frame = captureLatestFrame,
              captureModel.recordSnap(at: now) else { return }

        let cropped = LensViewModel.crop(frame, to: snap.rect, padding: 0.25)
        let personImage = cropped ?? frame
        guard let jpeg = personImage.jpegData(
            compressionQuality: HermesCameraManager.jpegQuality
        ) else { return }
        capturePhotos.append(jpeg)
        conversationCaptureSnapCount = capturePhotos.count

        let eventID = captureModel.addSighting(photoIndex: capturePhotos.count - 1)
        displayManager.showPersonSighted(name: nil, subtitle: nil)

        guard badgeOCREnabled else { return }
        // OCR runs off the main actor and lands whenever it lands - the
        // sighting is already recorded, so a slow read costs nothing.
        Task { @MainActor [weak self] in
            let badge = await BadgeReader.readBadge(from: personImage)
            // conversationCaptureActive alone isn't enough: if this task is
            // still in flight when one capture ends and a new one starts
            // before it resumes, the flag is true again but eventID belongs
            // to the OLD captureModel. Without the membership check the
            // portrait would be appended to the NEW capture's array while
            // updateBadge silently no-ops on the stale id - a photo written
            // to disk that nothing ever references. The check is repeated
            // AGAIN below, not merged into this one: `BadgeReader.portrait`
            // is its own suspension point, so a capture can just as well end
            // and restart during that second await. Guard once per await,
            // immediately before the state each one feeds - never "guard
            // once at the top and trust it downstream" across a suspend.
            guard let self, let badge, self.conversationCaptureActive,
                  self.captureModel.events.contains(where: { $0.id == eventID })
            else { return }

            var portraitData: Data?
            if self.badgePortraitsEnabled, let rect = badge.badgeRect {
                portraitData = await BadgeReader.portrait(
                    from: personImage, badgeRect: rect
                )
            }

            // Re-validated after the portrait await resumes - see the
            // comment above. Everything from here on (the append and the
            // updateBadge call) runs with no further suspension point, so
            // this guard covers both.
            guard self.conversationCaptureActive,
                  self.captureModel.events.contains(where: { $0.id == eventID })
            else { return }

            var portraitIndex: Int?
            if let portraitData {
                self.capturePortraits.append(portraitData)
                portraitIndex = self.capturePortraits.count - 1
            }

            self.captureModel.updateBadge(
                eventID: eventID, badge: badge, portraitIndex: portraitIndex
            )
            self.displayManager.showPersonSighted(
                name: badge.name, subtitle: badge.subtitle
            )
        }
    }

    /// Stop command (or UI toggle): save the whole capture as ONE encounter -
    /// full transcript as the note, every snapped person attached.
    func finishConversationCapture() {
        guard conversationCaptureActive else { return }
        stopCaptureVision()
        conversationCaptureActive = false
        liveTranscript = ""

        // Stop feeding the recorder before closing it, or buffers still in
        // flight write into a closed handle.
        audioManager.onRecordChunk = nil
        let recording = recorder.finish()
        captureRecordingURL = nil

        let photos = capturePhotos
        capturePhotos = []
        let portraits = capturePortraits
        capturePortraits = []
        conversationCaptureSnapCount = 0

        // A recording on its own IS content: the live recogniser hearing
        // nothing is exactly the failure this feature exists to survive, so
        // "nothing was said" must be judged from the audio, not from it.
        guard captureModel.hasContent || recording != nil else {
            // Nothing said, no one snapped, nothing recorded - no entry.
            displayManager.clear()
            guard !recordingOnlySession else { endSession(); return }
            connectionState = .listening
            speechRecognizer.isSuspended = false
            return
        }

        let saved = encounterStore.save(
            events: captureModel.events, photos: photos, portraits: portraits
        )
        encounterRevision &+= 1

        if let recording {
            encounterStore.attachRecording(encounterID: saved.id, from: recording)
        }

        // Mirror into the on-phone chat, cover photo and all.
        pendingPhoto = photos.first
        addTurn(
            userText: "[Conversation recorded]",
            agentText: photos.isEmpty
                ? "Saved to People (no photos)"
                : "Saved to People (\(photos.count) photo\(photos.count == 1 ? "" : "s"))"
        )

        displayManager.showEncounterSaved(note: "Conversation saved")

        // A session that exists only to record is FINISHED when the recording
        // is. Returning it to .listening left the mic up with no brain to
        // talk to, so the only way out was the End button - "stop recording"
        // stopped the recording but not the thing it started.
        //
        // Teardown comes BEFORE the deferred passes because endSession()
        // cancels badgeAssistTask; started after, they outlive the session,
        // which is right - both work off the saved encounter and neither
        // needs the mic, the camera or a socket. No spoken confirmation
        // here: the audio stack is going away and cutting off "Saved"
        // mid-word is worse than the lens card that already said it.
        if recordingOnlySession {
            endSession()
            startBadgeAssist(for: saved)
            startTranscription(for: saved.id)
            return
        }

        // Only now, with the encounter safely on disk, may anything touch
        // the network.
        startBadgeAssist(for: saved)
        startTranscription(for: saved.id)

        if displaySilentActive {
            connectionState = .listening
            speechRecognizer.isSuspended = false
        } else {
            connectionState = .speaking
            speechRecognizer.isSuspended = true
            speechSynthesizer.speak("Saved")
        }
    }

    private func stopCaptureVision() {
        captureSetupTask?.cancel()
        captureSetupTask = nil
        captureDetector?.onDetections = nil
        captureDetector = nil
        captureDwell = nil
        captureLatestFrame = nil
        // Only tear down a stream this capture started. In phone mode it is
        // the session's stream feeding the 5b view - stopping it would blank
        // the screen the user is looking at.
        removeVisionFrameObserver(Self.captureObserverKey)
        if captureStreamRunning {
            vision.stopLiveStream()
            captureStreamRunning = false
        }
    }

    /// Re-transcribe a saved capture from its recording, replacing the live
    /// transcript.
    ///
    /// Deferred like badge assist, and for the same reason: the encounter is
    /// already on disk, so a slow or failed pass costs nothing that was
    /// already earned. The live transcript stays exactly as it was until a
    /// better one exists to swap in - `replaceTranscript` ignores an empty
    /// result rather than blanking the note.
    ///
    /// Entirely on-device (`TranscriptionService` requires it), so this is
    /// not a second grant of trust the way badge assist is, and needs no
    /// opt-in.
    func startTranscription(for encounterID: UUID) {
        guard let encounter = encounterStore.all().first(where: { $0.id == encounterID }),
              let url = encounterStore.recordingURL(for: encounter)
        else { return }

        transcriptionTask?.cancel()
        transcriptionIsRunning = true
        transcriptionTask = Task { @MainActor [weak self] in
            defer { self?.transcriptionIsRunning = false }
            do {
                let lines = try await TranscriptionService.transcribe(fileAt: url)
                guard let self, !Task.isCancelled else { return }
                self.encounterStore.replaceTranscript(
                    encounterID: encounterID, lines: lines
                )
                self.encounterRevision &+= 1
            } catch {
                NSLog("[Hermes] transcription failed - \(error.localizedDescription)")
            }
        }
    }

    /// Deferred, opt-in: name the sightings on-device OCR left blank.
    ///
    /// Runs AFTER the encounter is saved, sequentially, capped, and gives up
    /// on the whole pass the moment the provider says the key is bad. Each
    /// result is written to the store and bumps `encounterRevision`; the
    /// name shows up the next time that entry is opened, NOT live under a
    /// reader's hands - a screen that rebuilds itself mid-read would lose an
    /// in-progress name edit.
    private func startBadgeAssist(for encounter: Encounter) {
        // The guarantee belongs here, not at the call site: assist only
        // makes sense as a top-up on sightings on-device OCR genuinely
        // could not read. With OCR off every sighting has badge == nil, so
        // without this guard the pass would run at its full cap on every
        // recording instead of only the sightings Vision missed - the UI
        // toggle clearing assist when OCR goes off is a courtesy, not the
        // enforcement.
        guard badgeOCREnabled, badgeAssistEnabled else { return }
        runBadgeAssist(for: encounter.id)
    }

    /// The same pass, asked for by hand on one encounter.
    ///
    /// This deliberately does NOT consult `badgeAssistEnabled` or
    /// `badgeOCREnabled`. Those flags govern the pass that fires by itself on
    /// every recording, where the danger is unnoticed spend; a person tapping
    /// "Read badges with AI" on one entry has already decided. Without this
    /// the only way to name a sighting Vision missed was to flip a global
    /// setting and record the conversation again - which is not a thing
    /// anyone can do.
    ///
    /// Still capped by `BadgeAssist.maxReads` and still abandoned on the
    /// first auth failure: explicit is not unlimited.
    func readBadgesWithAI(for encounterID: UUID) {
        guard !badgeAssistIsRunning else { return }
        badgeAssistIsRunning = true
        runBadgeAssist(for: encounterID) { [weak self] in
            self?.badgeAssistIsRunning = false
        }
    }

    /// Shared body of both paths. Re-reads the encounter from the store
    /// rather than taking a snapshot, so a manual run started minutes later
    /// sees any names the deferred pass already filled in.
    private func runBadgeAssist(
        for encounterID: UUID, completion: (() -> Void)? = nil
    ) {
        guard let encounter = encounterStore.all().first(where: { $0.id == encounterID })
        else { completion?(); return }

        // `badge?.name == nil`, NOT `badge == nil`. Once the detector can
        // localise a badge it could not read, that sighting has a badge
        // object (kind, box, maybe a barcode) with no name - and it is
        // precisely the sighting assist exists to rescue. Selecting on
        // `badge == nil` would skip it. PeopleView's own "unnamed" filter
        // already uses this predicate; this brings assist in line.
        let unnamed = encounter.events.filter {
            $0.kind == .sighting && $0.badge?.name == nil
                && !$0.photoFilenames.isEmpty
        }
        guard !unnamed.isEmpty else { completion?(); return }

        let targets = Array(unnamed.prefix(BadgeAssist.maxReads))
        if unnamed.count > targets.count {
            NSLog("[Hermes] badge assist: reading \(targets.count) of \(unnamed.count) sightings (capped)")
        }

        badgeAssistTask?.cancel()
        badgeAssistTask = Task { @MainActor [weak self] in
            defer { completion?() }
            guard let self else { return }
            for event in targets {
                if Task.isCancelled { return }
                guard let filename = event.photoFilenames.first,
                      let photo = self.encounterStore.photoData(filename: filename)
                else { continue }
                let toSend = await BadgeReader.assistCrop(
                    photoJPEG: photo, badgeRect: event.badge?.badgeRect
                )
                do {
                    guard let badge = try await BadgeAssist.read(
                        photoJPEG: toSend, client: self.directClient
                    ) else { continue }
                    self.encounterStore.update(
                        encounterID: encounterID, eventID: event.id, badge: badge
                    )
                    self.encounterRevision &+= 1
                } catch {
                    if BadgeAssist.isFatal(error) {
                        NSLog("[Hermes] badge assist: abandoning pass - \(error.localizedDescription)")
                        return
                    }
                    NSLog("[Hermes] badge assist: one read failed - \(error.localizedDescription)")
                }
            }
        }
    }

    private static let captureObserverKey = "conversation-capture"

    /// People screen: read-through to the store (the view holds no state of
    /// its own; `encounterRevision` tells it when to re-read).
    func allEncounters() -> [Encounter] { encounterStore.all() }

    func encounterPhoto(_ encounter: Encounter) -> Data? {
        encounterStore.photoData(for: encounter)
    }

    /// One photo by filename - the timeline addresses photos per event.
    func encounterPhotoData(filename: String) -> Data? {
        encounterStore.photoData(filename: filename)
    }

    /// Rename a whole timeline row (every event it was merged from).
    func renameEncounterSighting(
        encounterID: UUID, eventIDs: [UUID], name: String?
    ) {
        encounterStore.updateBadgeName(
            encounterID: encounterID, eventIDs: eventIDs, name: name
        )
        encounterRevision &+= 1
    }

    func updateEncounterNote(id: UUID, note: String) {
        encounterStore.update(id: id, note: note)
        encounterRevision &+= 1
    }

    func deleteEncounter(id: UUID) {
        encounterStore.delete(id: id)
        encounterRevision &+= 1
    }

    // MARK: - Lens object log (read-through, like People)

    func saveLensSession(
        startedAt: Date, endedAt: Date, entries: [LensSessionInput]
    ) {
        lensSessionStore.save(startedAt: startedAt, endedAt: endedAt, entries: entries)
        lensSessionRevision &+= 1
    }

    func allLensSessions() -> [LensSession] { lensSessionStore.all() }

    func lensSessionPhoto(_ entry: LensSession.Entry) -> Data? {
        lensSessionStore.photoData(for: entry)
    }

    func deleteLensSession(id: UUID) {
        lensSessionStore.delete(id: id)
        lensSessionRevision &+= 1
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

    /// The AiSee mic is only ever the live source when the AiSee glasses are
    /// also the selected vendor - the setting can outlive a vendor switch -
    /// AND the glasses are actually reachable. Without the connection terms a
    /// caller "chose" a mic that could only ever throw, so the phone route was
    /// never picked up front and the session died on the throw instead.
    private var usingAiSeeMic: Bool {
        glassesVendor == .aisee && micSource == .aiseeGlasses
            && aisee.state.isConnected && !aiseeWedged
    }

    /// Open the kit's microphone and pump its buffers into the audio manager.
    /// `audioManager` is captured directly: the kit calls back on its own
    /// audio thread, and `ingest` is written for exactly that.
    private func startAiSeeMicrophone() async throws {
        let manager = audioManager
        // `endSession()` stops the kit's mic from an unstructured `Task`, so a
        // restart can arrive with that stop still queued on the actor - and
        // `startMicrophone` honours a stop that lands mid-start by abandoning
        // the mic it just opened. Draining it first (idempotent in the kit)
        // orders the two, exactly as the mic-switch path already does.
        await aiseeCoordinator.stopMicrophone()
        try await aiseeCoordinator.startMicrophone { buffer in
            manager.ingest(buffer)
        }
    }

    /// Put a live session on the iPhone mic after the chosen source refused.
    /// Persists the demotion - the chip must not keep claiming a mic that is
    /// not there - and announces it as news. Throws only when the iPhone mic
    /// itself cannot be opened, the one case with no session left to save.
    private func fallBackToPhoneMic(notice: String, stoppingCapture: Bool) async throws {
        sessionUsesAiSeeMic = false
        cancelAiSeeMicRecovery()
        await aiseeCoordinator.stopMicrophone()
        if stoppingCapture {
            // `startExternalCapture()` may already have flipped the manager
            // into external mode before the kit refused; left set, `ingest`
            // stays armed and `startCapture` would build an engine tap
            // alongside it.
            audioManager.stopCapture()
        }
        micSource = .phone
        UserDefaults.standard.set(
            MicSource.phone.rawValue, forKey: Self.micSourceKey
        )
        try await audioManager.startCapture(route: .phoneMic)
        show(notice: notice)
    }

    /// Mic sources offerable right now. The AiSee entry is meaningless (and
    /// unroutable) unless the AiSee glasses are the selected vendor, and
    /// symmetrically the Meta HFP "call screen" entry only routes anywhere
    /// when Meta Ray-Ban is the selected vendor.
    var availableMicSources: [MicSource] {
        MicSource.allCases.filter {
            switch $0 {
            case .aiseeGlasses: return glassesVendor == .aisee
            case .glasses: return glassesVendor == .meta
            default: return true
            }
        }
    }

    /// Banner chip: cycle iPhone → Glasses → Headset → iPhone.
    /// Tap-to-switch walks to the next route that ACTUALLY takes, silently
    /// skipping past any that don't.
    ///
    /// It cannot pre-filter by asking which devices exist: HFP ports only
    /// appear in `availableInputs` once the audio category allows Bluetooth,
    /// and the iPhone-mic path deliberately does not allow it (otherwise iOS
    /// re-routes input to the glasses and kills the tap). Asking anyway is
    /// what made connected glasses report "not available". So it tries, and
    /// keeps walking until something sticks - no popup either way.
    func toggleMicSource() async {
        let all = availableMicSources
        guard !all.isEmpty else { return }
        let start = all.firstIndex(of: micSource) ?? 0
        for step in 1...all.count {
            let candidate = all[(start + step) % all.count]
            switch await switchMicSource(candidate, announceFallback: false) {
            case .took:
                return
            case .failedOverToPhone, .sessionEnded:
                // The source did not merely fail to materialise - it threw,
                // and the state it left behind has already been reconciled.
                // Walking on from here is how a later candidate came back
                // "true" on a session that was no longer running.
                return
            case .routeUnavailable:
                // The Bluetooth port never appeared. That is the case this
                // walk exists for: silently try the next one.
                continue
            }
        }
    }

    /// What a mic switch actually did. `toggleMicSource` has to tell "that
    /// route didn't materialise, try the next" from "that route failed and
    /// the iPhone mic is now live" - only the first is worth walking past.
    private enum MicSwitchOutcome {
        /// The requested source is live.
        case took
        /// The Bluetooth route never appeared; the iPhone mic is live.
        case routeUnavailable
        /// Starting the source threw; the iPhone mic is live instead.
        case failedOverToPhone
        /// Not even the iPhone mic came up - the session was ended.
        case sessionEnded
    }

    /// Select a mic source. Persists the preference and, when a session is
    /// live, reconfigures capture and restarts the recognizer (new route =
    /// new buffer format).
    /// - Returns: true when the requested route is the one now in use.
    ///   False means it didn't materialise and the iPhone mic is live.
    @discardableResult
    func setMicSource(_ target: MicSource, announceFallback: Bool = true) async -> Bool {
        await switchMicSource(target, announceFallback: announceFallback) == .took
    }

    /// The body of `setMicSource`, reporting WHICH way a switch went rather
    /// than just whether it took - see `MicSwitchOutcome`.
    private func switchMicSource(
        _ target: MicSource, announceFallback: Bool
    ) async -> MicSwitchOutcome {
        micSource = target
        UserDefaults.standard.set(target.rawValue, forKey: Self.micSourceKey)

        // Nothing to route yet - the choice is remembered for next session.
        guard connectionState != .disconnected else { return .took }

        audioManager.stopCapture()
        // Set before the first await: whatever the session was listening
        // through, it is not that any more, and the coordinator's own state
        // observer must not read the stale value while this runs.
        sessionUsesAiSeeMic = false
        do {
            // Whichever way this switch goes, the kit's mic must not stay
            // open: it is the source only on the AiSee branch below.
            await aiseeCoordinator.stopMicrophone()
            let bluetoothActive: Bool
            let outcome: MicSwitchOutcome
            if glassesVendor == .aisee && target == .aiseeGlasses {
                // Absent or wedged glasses take the fallback path below rather
                // than opening external capture for a mic that cannot answer.
                guard usingAiSeeMic else { throw AiSeeError.notConnected }
                try await audioManager.startExternalCapture()
                try await startAiSeeMicrophone()
                sessionUsesAiSeeMic = true
                bluetoothActive = false
                // The AiSee mic has no iOS route to report on - reaching here
                // means `startMicrophone` didn't throw, which IS the requested
                // source being live.
                outcome = .took
            } else {
                bluetoothActive = try await audioManager.startCapture(
                    route: target.captureRoute
                )
                // The route can differ from what was asked for; keep the label
                // honest rather than claiming a device that didn't answer.
                outcome = (bluetoothActive || target == .phone)
                    ? .took : .routeUnavailable
            }
            speechRecognizer.restartCycle()
            if announceFallback, target == .glasses, !bluetoothActive {
                show(notice: Self.glassesMicFallbackNotice)
            }
            if announceFallback, target == .headset, !bluetoothActive {
                show(notice: Self.headsetMicFallbackNotice)
            }
            if outcome == .routeUnavailable {
                micSource = .phone
                UserDefaults.standard.set(
                    MicSource.phone.rawValue, forKey: Self.micSourceKey
                )
            }
            reconcileLensHUD()
            return outcome
        } catch {
            // Demoting instead of tearing down is an AiSee affordance, not a
            // general one: its mic can be absent for reasons the user never
            // chose (glasses on the table, a camera wedge) and the iPhone mic
            // is a real substitute. Every other route is an explicit iOS
            // choice, so a failure there stays the fault it has always been -
            // the Meta paths keep exactly the teardown they had.
            guard target == .aiseeGlasses, glassesVendor == .aisee else {
                show("Mic switch failed: \(error.localizedDescription)")
                endSession()
                return .sessionEnded
            }
            Logger(subsystem: "com.flowsxr.hermesglasses", category: "aisee").notice("AiSee mic switch failed: \(error.localizedDescription)")
            do {
                try await fallBackToPhoneMic(
                    notice: Self.aiseeMicFallbackNotice, stoppingCapture: true
                )
                speechRecognizer.restartCycle()
                reconcileLensHUD()
                return .failedOverToPhone
            } catch {
                show("Mic switch failed: \(error.localizedDescription)")
                endSession()
                return .sessionEnded
            }
        }
    }

    /// HUD ⇄ GLASSES hands-free mic are mutually exclusive: the glasses show
    /// their call screen while their hands-free link is active. Headset mode
    /// leaves the lens free.
    ///
    /// Runs on EVERY exit from a mic switch, and reads `micSource` AFTER any
    /// fallback - a failed switch away from the glasses mic leaves the iPhone
    /// mic live, and the HUD must come back with it. Skipping it once stranded
    /// the lens off with no recovery but toggling the HUD setting.
    private func reconcileLensHUD() {
        guard displayHUDEnabled, let session = deviceSession else { return }
        if lensBlockedByCallScreen {
            displayManager.stop()
            // Glasses without a lens have no HUD to pause - the notice would
            // be news about a screen that doesn't exist.
            guard activeGlassesHaveDisplay else { return }
            show(notice: "Lens HUD paused - the glasses show their call screen while their hands-free mic is on. The iPhone or a headset mic keeps the HUD visible.")
        } else if displayManager.status == .off {
            displayManager.start(session: session)
        }
    }

    // MARK: - Glasses buttons

    /// Key index from the kit (the glasses detect tap / double / triple in
    /// firmware and report 1 / 2 / 3) → mapped action.
    private func handleGlassesKeyPress(_ index: Int) {
        let action = glassesKeyMap.action(forKey: index)
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        lastAiSeeKeyPress = "\(GlassesKeyMap.label(forKey: index)) (key \(index)) → \(action.label) · \(f.string(from: Date()))"
        Task { await perform(action) }
    }

    /// Actions reachable from a button. Anything that needs the voice loop
    /// starts it first; the user hears the usual start cue.
    func perform(_ action: GlassesKeyAction) async {
        switch action {
        case .none:
            return
        case .toggleListening:
            if connectionState == .disconnected { await startSession() } else { endSession() }
        case .visualQuery:
            await ensureSessionThen { self.submitQuery("What am I looking at?") }
        case .rememberPerson:
            await ensureSessionThen { self.submitQuery("Remember this person") }
        case .snapPhoto:
            await testPhoto()
        case .recordClip:
            await toggleClipRecording()
        case .buildStepDone, .buildRepeatWarning:
            onBuildKey?(action)
        }
    }

    // MARK: - Video clips (AiSee)

    /// Whether a clip can be recorded right now: AiSee glasses, connected,
    /// camera not wedged. The glasses have no storage, so a clip is the
    /// livestream written to a file on the phone.
    var canRecordClip: Bool {
        glassesVendor == .aisee && aisee.state.isConnected && !aiseeWedged
    }

    func toggleClipRecording() async {
        guard !clipStarting else { return }
        if clipRecording {
            // The file arrives through the clip observer (clipDidEnd).
            await aiseeCoordinator.stopClip()
            return
        }
        guard canRecordClip else {
            show(glassesVendor == .aisee
                 ? "Connect your AiSee glasses to record a clip."
                 : "Video clips need AiSee glasses.")
            return
        }
        clipStarting = true
        defer { clipStarting = false }
        // Opening the stream takes seconds (and, the first time, an iOS
        // "join Wi-Fi" prompt). Say so at once: with no feedback the wearer
        // presses again - which stops the clip they just started.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        speakCue(UserDefaults.standard.bool(forKey: Self.clipWifiHintKey)
                 ? "Starting video"
                 : "Starting video. Your phone may ask to join the glasses' Wi-Fi.")
        UserDefaults.standard.set(true, forKey: Self.clipWifiHintKey)
        do {
            try await aiseeCoordinator.startClip()
            clipRecording = true
            clipStartedAt = Date()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            speakCue("Recording", queued: true)
        } catch {
            show("Could not start the clip: \(error.localizedDescription)")
        }
    }

    private func clipDidEnd(file: URL?, interruption: String?) {
        clipRecording = false
        clipStartedAt = nil
        guard let file else {
            // The kit appends what the stream delivered, so this says WHY.
            show("The clip was not saved - no video was written (\(interruption ?? "no details")).")
            return
        }
        Task { await saveClipToPhotos(file, interruption: interruption) }
    }

    /// Add-only access: Hermes never reads the library. The temp file is
    /// deleted once Photos has it, and kept (with the path logged) if not.
    private func saveClipToPhotos(_ file: URL, interruption: String?) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            show("Allow Hermes to add to Photos (Settings › Privacy › Photos) to save clips.")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: file)
            }
            try? FileManager.default.removeItem(at: file)
            let why = interruption.map { " (stopped: \($0))" } ?? ""
            show(notice: "Clip saved to Photos\(why).")
            speakCue("Clip saved")
        } catch {
            NSLog("[Hermes] clip save failed, kept at \(file.path): \(error)")
            show("Could not save the clip to Photos: \(error.localizedDescription)")
        }
    }

    /// A short spoken confirmation. With the voice loop listening, the
    /// recognizer is suspended first (onFinished resumes it) so Hermes
    /// doesn't transcribe its own cue; mid-answer, the cue is skipped.
    func speakCue(_ text: String) {
        switch connectionState {
        case .listening:
            connectionState = .speaking
            speechRecognizer.isSuspended = true
            speechSynthesizer.speak(text)
        case .disconnected:
            speechSynthesizer.speak(text)
        default:
            break
        }
    }

    /// Build Check's form: while another cue is speaking the line waits its
    /// turn (FIFO, drained by onFinished) instead of being dropped - a run's
    /// warnings and step prompts must all be heard.
    func speakCue(_ text: String, queued: Bool) {
        if queued, case .speaking = connectionState {
            cueQueue.append(text)
            return
        }
        speakCue(text)
    }

    /// A notice on the main screen (the non-fault banner).
    func showNoticeMessage(_ message: String) {
        show(notice: message)
    }

    /// Soft "note for later" cue (ChimeTone). Plays over whatever route
    /// speech uses; never suspends the recognizer (it's 0.35 s of tone).
    func playChime() {
        guard let player = try? AVAudioPlayer(data: ChimeTone.wav()) else { return }
        player.volume = 0.6
        chimePlayer = player
        player.play()
    }

    /// Build Check on the lens (Ray-Ban Display) and the simulated lens.
    /// Best-effort, like every display call.
    func showBuildCheckOnLens(step: Int, total: Int, text: String, flag: String?) {
        displayManager.showBuildCheck(step: step, total: total, text: text, flag: flag)
    }

    private func ensureSessionThen(_ body: @escaping @MainActor () -> Void) async {
        if connectionState == .disconnected {
            await startSession()
            guard connectionState != .disconnected else { return }
        }
        body()
    }

    func endSession() {
        // Take the hook first: the run's own teardown may call endSession().
        let ending = onSessionEnding
        onSessionEnding = nil
        ending?()
        onMachineGuideSessionEnding?()
        // Unlike a half-finished "remember this person", a running
        // conversation capture is saved, not discarded - an hour of notes
        // must not vanish because the session dropped. Silent: the audio
        // stack is going away anyway.
        if conversationCaptureActive {
            stopCaptureVision()
            conversationCaptureActive = false
            audioManager.onRecordChunk = nil
            let recording = recorder.finish()
            captureRecordingURL = nil
            if captureModel.hasContent || recording != nil {
                // Same event stream the stop command saves - this is one of
                // only two ways a capture ends, and both must produce a
                // timeline. The badge-assist pass is deliberately NOT started
                // here: the session is being torn down (badgeAssistTask is
                // cancelled a few lines below), so a network pass into a
                // dying session would be wrong.
                let saved = encounterStore.save(
                    events: captureModel.events, photos: capturePhotos,
                    portraits: capturePortraits
                )
                encounterRevision &+= 1
                if let recording {
                    encounterStore.attachRecording(
                        encounterID: saved.id, from: recording
                    )
                }
                // Transcription, unlike badge assist, IS started here and is
                // deliberately NOT cancelled with the session: it never
                // touches the network, and the session going away is no
                // reason to leave an hour of recorded audio untranscribed.
                startTranscription(for: saved.id)
            }
            capturePhotos = []
            capturePortraits = []
            conversationCaptureSnapCount = 0
        }
        recordingOnlySession = false
        badgeAssistTask?.cancel()
        badgeAssistTask = nil
        sessionObserverTask?.cancel()
        sessionObserverTask = nil
        cueQueue.removeAll()
        speechSynthesizer.stop()
        speechRecognizer.stop()
        displayManager.stop()
        navigation.stop()
        displayStatus = .off
        contextProvider.stop()
        liveTranscript = ""
        micLevel = 0
        audioManager.stopCapture()
        // Clear the drop handler first: this teardown is deliberate, and the
        // handler exists to report the socket going away UNDER us.
        apiClient?.onDisconnected = nil
        apiClient?.disconnect()
        apiClient = nil
        cameraManager.reset()
        // Phone mode: the camera runs for the whole session, so it stops
        // with it. Leaving it live would keep the torch-hot preview going
        // behind a screen that is no longer showing it.
        phoneCameraManager.stopLiveStream()
        unpinVisionRoute()
        phoneModeActive = false
        phoneFeedImage = nil
        phoneCameraError = nil
        lensContent = .blank
        // A half-finished encounter dies with the session; the photo alone
        // isn't worth a note-less entry the user never asked for.
        encounterTimeoutTask?.cancel()
        encounterTimeoutTask = nil
        encounterPhotoTask?.cancel()
        encounterPhotoTask = nil
        awaitingEncounterNote = false
        pendingPhoto = nil
        // Deliberately NOT gated on the vendor: `glassesVendor.didSet` calls
        // endSession() AFTER storing the new vendor, so a switch away from
        // AiSee would leave its stream and mic running. Both are no-ops on the
        // Meta path. Via the adapter, so its own `isStreaming` latch clears
        // too - otherwise the next stream is refused as already in use.
        // Together with `cameraManager.reset()` and
        // `phoneCameraManager.stopLiveStream()` above, all three sources are
        // stopped explicitly, which also covers `stopCaptureVision()` having
        // resolved `vision` through the already-switched vendor.
        aiseeCamera.stopLiveStream()
        // Cleared BEFORE the stop below: the coordinator's state observer hops
        // to the main actor, so it must find "no session uses the kit's mic"
        // already true and leave this deliberate close alone.
        sessionUsesAiSeeMic = false
        cancelAiSeeMicRecovery()
        Task { await aiseeCoordinator.stopMicrophone() }
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
        // Nothing to create for AiSee - the kit's connection is the session.
        if glassesVendor == .aisee {
            guard aisee.state.isConnected, !aiseeWedged else { throw AiSeeError.notConnected }
            #if canImport(RTKAIDeviceConnection)
            // Lens can open without a voice session ever having run, and
            // `connectGlassesSession()` is the only other place the coordinator
            // is handed its connection - without this the camera source shot
            // into a detached coordinator. Idempotent: `attach` resets state
            // only when the connection identity actually changes.
            await aiseeCoordinator.attach(aisee.connection)
            #endif
            return
        }
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
        if await ensureCameraPermission(interactive: false) == false {
            NSLog("[Hermes] glasses camera grant MISSING - streams will fail")
        }
    }

    /// Tear down the Lens-owned camera session. No-op when the camera is
    /// riding on the voice session (or nothing is connected).
    func releaseCameraSession() {
        // The kit owns AiSee stream teardown (via `stopLiveStream`); there is
        // no per-view session to release. A DeviceSession left over from a
        // vendor switch mid-Lens still has to be stopped, hence the nil check.
        if glassesVendor == .aisee && lensSession == nil { return }
        guard let session = lensSession else { return }
        lensSession = nil
        if deviceSession == nil { cameraManager.reset() }
        session.stop()
    }

    // MARK: - Lookup app lens surface

    /// Attach the display HUD to a camera-only session, so Lookup can put
    /// its result on the real lens without a voice session running. No-op
    /// when a voice session exists (its display is already attached) or
    /// the HUD is off. Best-effort like every display call.
    func attachDisplayToCameraSession() {
        guard glassesVendor.supportsDisplay, displayHUDEnabled, deviceSession == nil,
              let session = lensSession else { return }
        displayManager.start(session: session)
    }

    /// Undo `attachDisplayToCameraSession()`. Call BEFORE
    /// `releaseCameraSession()` - the capability dies with the session.
    /// No-op when the display belongs to a voice session.
    func detachDisplayFromCameraSession() {
        guard deviceSession == nil else { return }
        displayManager.stop()
    }

    /// Lookup is searching the web for a badge name - show it on the lens.
    /// Lookup matches a face against the roster - there is no name to show
    /// until it resolves, and nothing is being searched for.
    func showLookupSearchingOnLens() {
        displayManager.showThinking(query: "Matching…")
    }

    /// Lookup's finished card: name + roster details.
    func showPersonLookupOnLens(name: String, info: String) {
        displayManager.showPersonLookup(name: name, info: info)
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
            .dictionary(forKey: Self.endpointPresetsKey) as? [String: String]
            ?? [:]
        return dict.sorted { $0.key < $1.key }
            .map { (name: $0.key, url: $0.value) }
    }

    func savePreset(name: String, url: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return }
        var dict = UserDefaults.standard
            .dictionary(forKey: Self.endpointPresetsKey) as? [String: String]
            ?? [:]
        dict[trimmedName] = trimmedURL
        UserDefaults.standard.set(dict, forKey: Self.endpointPresetsKey)
    }

    func deletePreset(name: String) {
        var dict = UserDefaults.standard
            .dictionary(forKey: Self.endpointPresetsKey) as? [String: String] ?? [:]
        dict.removeValue(forKey: name)
        UserDefaults.standard.set(dict, forKey: Self.endpointPresetsKey)
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

    func dismissNotice() {
        showNotice = false
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

    /// Run `body` with a camera session available, creating a temporary
    /// camera-only one if nothing is running and tearing it down after.
    /// The test panel is for diagnosing a broken setup - insisting on a
    /// working session first is exactly backwards.
    private func withCameraSession<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        let borrowed = deviceSession == nil && lensSession == nil
        try await ensureCameraSession()
        defer { if borrowed { releaseCameraSession() } }
        return try await body()
    }

    /// Camera alone - no Hermes involved. Runs the interactive permission
    /// flow (opens Meta AI) if camera access was never granted, and brings
    /// its own session so it works from a cold start.
    func testPhoto() async {
        await runTest("Photo") { [self] in
            if visionRoute == .glasses {
                guard await ensureCameraPermission(interactive: true) else {
                    throw TestFailure("Camera permission denied in Meta AI app")
                }
            }
            if glassesVendor == .aisee && visionRoute == .phone {
                let reason: String
                if !aisee.state.isConnected {
                    reason = "AiSee glasses are not connected"
                } else if aiseeWedged {
                    reason = "AiSee camera is wedged - restart the glasses"
                } else {
                    reason = "phone mode is set to Always (Settings > Devices)"
                }
                throw TestFailure("Glasses camera not in use: \(reason)")
            }
            let source = vision.sourceLabel
            let photo = try await withCameraSession {
                try await captureVisionPhoto()
            }
            pendingPhoto = photo
            lastTestPhoto = UIImage(data: photo)
            lastTestPhotoSource = "\(photo.count / 1024) KB from the \(source)"
            addTurn(
                userText: "[Test Photo]",
                agentText: "Captured \(photo.count / 1024) KB from the \(source)"
            )
        }
    }

    /// Check (and optionally request via Meta AI) the glasses camera
    /// permission. The interactive request switches to the Meta AI app.
    /// The Meta AI glasses-camera grant, requested interactively (it
    /// app-switches to Meta AI). Nothing in the normal flow ever asked for
    /// this - only the Photo test button did - so a user who never pressed
    /// that button had every glasses camera feature fail: Lens with "camera
    /// unavailable", "remember this person" with a note and no photo.
    @discardableResult
    func requestGlassesCameraAccess() async -> Bool {
        await ensureCameraPermission(interactive: true)
    }

    /// Asked once, the moment glasses finish pairing. This grant is what
    /// makes the glasses camera work at all, and leaving it to be discovered
    /// via a failure was the single worst bug in this app: Lens said "camera
    /// unavailable" and "remember this person" saved notes with no photo,
    /// with nothing anywhere explaining why.
    func ensureGlassesCameraAfterPairing() async {
        guard !askedForCameraGrant else { return }
        askedForCameraGrant = true
        if await glassesCameraGranted() == false {
            await requestGlassesCameraAccess()
        }
    }

    @ObservationIgnored private var askedForCameraGrant = false

    /// Non-interactive refresh, so the UI can warn before anything fails.
    func refreshGlassesCameraStatus() async {
        guard wearables.registrationState == .registered else { return }
        _ = await glassesCameraGranted()
    }

    /// Cheap check for "will the glasses camera work at all".
    func glassesCameraGranted() async -> Bool {
        if glassesVendor == .aisee { return true }
        return await ensureCameraPermission(interactive: false)
    }

    func ensureCameraPermission(interactive: Bool) async -> Bool {
        // AiSee's camera is reached over the kit's own link - there is no
        // companion-app grant to check or ask for.
        if glassesVendor == .aisee { return true }
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
                throw TestFailure("Bridge mode needs a running session - or switch to Direct")
            }
            try await awaitTestReply {
                submitQuery("Respond with exactly: OK")
            }
        }
    }

    /// Pure output test: play a locally generated tone through the current
    /// audio route (glasses in glasses mode). No bridge or Hermes involved.
    /// AiSee only: open the kit's microphone for four seconds and count what
    /// arrives. This is the on-screen answer to "is the glasses mic streaming
    /// at all" - independent of the recognizer, the audio manager and the UI.
    func testAiSeeMic() async {
        await runTest("Mic") { [self] in
            guard glassesVendor == .aisee else { throw TestFailure("Select AiSee under Devices first.") }
            guard aisee.state.isConnected else { throw TestFailure("AiSee glasses are not connected.") }
            let tally = AiSeeMicTally()
            let t0 = Date()
            try await aiseeCoordinator.startMicrophone { buffer in
                tally.record(AiSeePCM.peakLevel(buffer), frames: Int(buffer.frameLength))
            }
            let startMs = Int(Date().timeIntervalSince(t0) * 1000)
            try await Task.sleep(for: .seconds(4))
            await aiseeCoordinator.stopMicrophone()
            let (buffers, frames, peak) = tally.snapshot()
            let summary = "start \(startMs) ms · \(buffers) buffers · \(frames / 16) ms audio · peak \(String(format: "%.2f", peak))"
            lastTestMicSummary = summary
            guard buffers > 0 else {
                throw TestFailure("AiSee mic opened (\(startMs) ms) but delivered no audio in 4 s. Output route: \(audioManager.currentOutputName)")
            }
        }
    }

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
            lastTestAudioRoute = audioManager.currentOutputName
            if glassesVendor == .aisee, !audioManager.outputIsBluetooth {
                throw TestFailure("Played on \(audioManager.currentOutputName). To hear replies on the AiSee glasses, pair them as a Bluetooth audio device in iOS Settings.")
            }
        }
    }

    /// Full photo pipeline via a canned visual query
    func testVisualQuery() async {
        await runTest("Visual") { [self] in
            guard backend == .direct || apiClient?.isConnected == true else {
                throw TestFailure("Bridge mode needs a running session - or switch to Direct")
            }
            // Borrowed for the whole round trip: the capture happens inside
            // submitQuery, so the session has to outlive this call - and
            // waiting for the answer is what tells us it did. This used to
            // call ensureCameraSession() and walk away, leaving a cold-start
            // session running with nothing on any path to release it
            // (endSession() only tears down the VOICE session).
            try await withCameraSession {
                try await awaitTestReply {
                    submitQuery("What am I looking at? Answer in one short sentence.")
                }
            }
        }
    }

    /// Attach (if needed) and push a static screen to the lens. Works
    /// without a Hermes session: spins up a temporary device session just
    /// for the test and tears it down after a few seconds.
    func testDisplay() async {
        await runTest("Display") { [self] in
            guard glassesVendor.supportsDisplay else {
                throw TestFailure("\(glassesVendor.label) glasses have no lens display.")
            }
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

    /// Resumed by the first reply (or error) that follows a test's query.
    @ObservationIgnored
    private var pendingTestOutcome: CheckedContinuation<Void, Error>?

    /// Longest a test waits for a brain before calling it a failure. Generous
    /// on purpose: a bridge shelling out to `hermes chat` with an image
    /// attached is slow, and a false failure is as useless as a false pass.
    private static let testReplyTimeout: Double = 90

    /// Run `submit` and wait for the answer it produces.
    ///
    /// The Query and Visual tests used to report a pass the moment
    /// `submitQuery` returned - which only says the text was dispatched, not
    /// that any brain answered. A panel that exists to diagnose a broken
    /// setup must not go green on a dead bridge.
    private func awaitTestReply(_ submit: () -> Void) async throws {
        let timeout = Self.testReplyTimeout
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.completeTestOutcome(
                .failure(TestFailure("No answer within \(Int(timeout)) s"))
            )
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { cont in
            // A second test started while this one was waiting would strand
            // the first continuation forever - fail it instead.
            completeTestOutcome(.failure(TestFailure("Superseded by another test")))
            pendingTestOutcome = cont
            submit()
        }
    }

    private func completeTestOutcome(_ result: Result<Void, Error>) {
        guard let cont = pendingTestOutcome else { return }
        pendingTestOutcome = nil
        cont.resume(with: result)
    }

    private func runTest(_ name: String, _ body: () async throws -> Void) async {
        testRunning.insert(name)
        defer { testRunning.remove(name) }
        do {
            try await body()
            testResults[name] = ""
            lastTestFailure = nil
        } catch {
            testResults[name] = error.localizedDescription
            lastTestFailure = error.localizedDescription
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
            photo: pendingPhoto,
            photoSource: pendingPhoto == nil ? nil : vision.sourceLabel
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
        // A test waiting on a round trip has just learnt its outcome: this
        // is the only path every brain's failures share.
        completeTestOutcome(.failure(TestFailure(message)))
    }

    /// The same surface for something that merely happened, phrased as news
    /// rather than as a fault.
    private func show(notice message: String) {
        noticeMessage = message
        showNotice = true
    }
}

struct ConversationTurn: Identifiable {
    let id = UUID()
    let userText: String
    let agentText: String
    let timestamp: Date
    var photo: Data? = nil
    /// Which camera took `photo` ("AiSee camera", "Ray-Ban camera", "iPhone camera").
    var photoSource: String? = nil
}


/// Thread-safe counter for `testAiSeeMic` - the kit delivers on its own thread.
private final class AiSeeMicTally: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var frames = 0
    private var peak: Float = 0
    func record(_ level: Float, frames n: Int) {
        lock.withLock { buffers += 1; frames += n; peak = max(peak, level) }
    }
    func snapshot() -> (Int, Int, Float) { lock.withLock { (buffers, frames, peak) } }
}
