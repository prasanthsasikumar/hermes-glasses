//
// TranslateViewModel.swift
//
// Drives the Translate app: aim at a thing, hear what it is called in the
// selected language.
//
// Two paths, deliberately different in cost:
//
//  - INSTANT: the reticle rests on an object the bundled detector knows
//    (ObjectDetector + DwellTracker, both shared with Lens and unchanged),
//    the label is looked up in ObjectVocabulary, TranslateSpeakPolicy
//    decides whether it is worth saying, and the iPhone voice says it.
//    On-device, offline, free.
//  - TAP: whatever is at the centre goes to the AI (askOneShot - never
//    ask(), nothing lands in conversation memory). This is the only route
//    for things outside the detector's 80 classes, and the ONLY place an
//    AI call is made. No tap, no call.
//
// Camera lifecycle mirrors LookupViewModel: camera-only, never starts the
// voice session, observes a stream someone else owns rather than starting
// a second one, and stops only what it started.
//

import SwiftUI
import Observation
import CoreMedia

@MainActor
@Observable
final class TranslateViewModel {
    enum AIState: Equatable {
        case idle
        case looking
        case failed(String)
    }

    /// The language words are spoken in. Persisted.
    var language: TranslateLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: TranslateLanguage.storageKey)
        }
    }
    var feedImage: UIImage?
    /// Every box this frame, for the overlay (normalized, top-left origin).
    var detections: [Detection] = []
    /// The box under the reticle, nil when none.
    var targetBox: CGRect?
    var holdProgress: Double = 0
    /// The word on the card.
    var current: TranslatedTerm?
    /// This session's words, newest first. In memory only.
    var recent: [TranslatedTerm] = []
    var aiState: AIState = .idle
    /// The phone has no voice for the language of `current`.
    var voiceMissing = false
    var statusText = "Connecting to camera…"
    var errorBanner: String?
    var isStreaming = false
    var needsGlassesCameraGrant = false

    static let recentLimit = 20
    /// Lens holds for 2 s; someone walking wants the word sooner.
    /// PROVISIONAL until tried on a real walk.
    static let dwellSeconds: TimeInterval = 1.0
    static let aiTimeout: TimeInterval = 10
    /// What the tap path sends when no box is under the reticle.
    static let centreCrop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    static let readyStatus = "Hold on an object · tap for anything else"
    static let tapOnlyStatus = "Tap to name what's in the centre"

    @ObservationIgnored private let hermesVM: HermesSessionViewModel
    @ObservationIgnored private var vision: VisionSource?
    @ObservationIgnored private var sharesSessionStream = false
    @ObservationIgnored private let detector = ObjectDetector()
    @ObservationIgnored private let dwell = DwellTracker(dwellDuration: TranslateViewModel.dwellSeconds)
    @ObservationIgnored private var policy = TranslateSpeakPolicy()
    @ObservationIgnored private let client = DirectClient()
    @ObservationIgnored private var detectorLoaded = false
    @ObservationIgnored private var didStop = false

    private static let observerKey = "translate"

    init(hermesVM: HermesSessionViewModel) {
        self.hermesVM = hermesVM
        let stored = UserDefaults.standard.string(forKey: TranslateLanguage.storageKey)
        language = stored.flatMap(TranslateLanguage.init(rawValue:)) ?? .defaultLanguage
    }

    // MARK: - Lifecycle (mirrors LookupViewModel)

    func start() async {
        errorBanner = nil
        hermesVM.logVisionDiagnostics("translate-start")
        var route = hermesVM.visionRoute

        if route == .glasses {
            statusText = "Connecting to glasses…"
            if await hermesVM.glassesCameraGranted() == false {
                needsGlassesCameraGrant = true
                errorBanner = "The glasses camera isn't allowed yet."
                statusText = "Tap Allow camera to grant it in the Meta AI app"
                return
            }
            do {
                try await hermesVM.ensureCameraSession()
            } catch {
                guard VisionRouting.mayFallBackToPhone(
                    preference: hermesVM.phoneModePreference
                ) else {
                    errorBanner = error.localizedDescription
                    statusText = "Glasses unavailable"
                    return
                }
                NSLog("[Hermes] translate: glasses unavailable (\(error.localizedDescription)) - using iPhone")
                errorBanner = "Glasses unreachable - using the iPhone camera."
                route = .phone
            }
        }

        hermesVM.pinVisionRoute(route)
        vision = hermesVM.vision
        sharesSessionStream = hermesVM.visionStreamIsShared
        // Word cards go to the real lens even without a voice session.
        hermesVM.attachDisplayToCameraSession()

        statusText = "Loading model…"
        do {
            try await detector.load()
            detectorLoaded = true
        } catch {
            // Not fatal here, unlike Lookup: the tap path needs no boxes.
            NSLog("[Hermes] translate: detector failed to load - \(error.localizedDescription)")
            errorBanner = "Object model failed to load - tap to name things instead."
        }

        detector.onDetections = { [weak self] detections in
            MainActor.assumeIsolated {
                self?.handle(detections: detections)
            }
        }

        await beginStream(allowPhoneFallback: true)
    }

    private func beginStream(allowPhoneFallback: Bool) async {
        if sharesSessionStream {
            hermesVM.addVisionFrameObserver(Self.observerKey) { [weak self] frame in
                MainActor.assumeIsolated {
                    self?.handle(image: frame.image, pixelBuffer: frame.pixelBuffer)
                }
            }
            streamStarted()
            return
        }

        guard let vision else {
            statusText = "No camera available"
            return
        }
        statusText = hermesVM.visionRoute == .phone
            ? "Starting iPhone camera…" : "Starting glasses camera…"
        do {
            try await vision.startLiveStream(
                onFrame: { [weak self] frame in
                    Task { @MainActor [weak self] in
                        self?.handle(image: frame.image, pixelBuffer: frame.pixelBuffer)
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.errorBanner = "Camera stream error: \(message)"
                        self?.isStreaming = false
                    }
                }
            )
            streamStarted()
        } catch {
            NSLog("[Hermes] translate: \(hermesVM.visionRoute) stream failed - \(error.localizedDescription)")
            hermesVM.logVisionDiagnostics("translate-stream-failed")

            // Never predict hardware without a fallback: the glasses can
            // lapse between the check and the start. One retry, on the
            // phone, and a failure there reports honestly.
            guard allowPhoneFallback,
                  hermesVM.visionRoute == .glasses,
                  VisionRouting.mayFallBackToPhone(
                      preference: hermesVM.phoneModePreference
                  )
            else {
                errorBanner = error.localizedDescription
                statusText = "Camera unavailable"
                return
            }

            errorBanner = "Glasses camera unavailable - using the iPhone camera."
            hermesVM.pinVisionRoute(.phone)
            // `self.` is load-bearing: the guard above shadows `vision`.
            self.vision = hermesVM.vision
            sharesSessionStream = hermesVM.visionStreamIsShared
            await beginStream(allowPhoneFallback: false)
        }
    }

    private func streamStarted() {
        isStreaming = true
        statusText = detectorLoaded ? Self.readyStatus : Self.tapOnlyStatus
    }

    /// Ask Meta AI for the glasses camera, then carry on where we left off.
    func grantGlassesCamera() async {
        guard await hermesVM.requestGlassesCameraAccess() else {
            errorBanner = "Still not allowed. Open the Meta AI app and enable camera access for Hermes."
            return
        }
        needsGlassesCameraGrant = false
        errorBanner = nil
        didStop = false
        await start()
    }

    func stop() {
        guard !didStop else { return }
        didStop = true
        if sharesSessionStream {
            hermesVM.removeVisionFrameObserver(Self.observerKey)
        } else {
            vision?.stopLiveStream()
        }
        detector.onDetections = nil
        isStreaming = false
        hermesVM.clearTranslationPendingOnLens()
        // Only Translate's own pin is released - a running voice session
        // pinned its route first and owns it until the session ends.
        if !hermesVM.phoneModeActive, hermesVM.connectionState == .disconnected {
            hermesVM.unpinVisionRoute()
        }
        // Before releaseCameraSession - the display capability dies with it.
        hermesVM.detachDisplayFromCameraSession()
        hermesVM.releaseCameraSession()
    }

    // MARK: - Frames and the instant path

    private func handle(image: UIImage?, pixelBuffer: CVPixelBuffer?) {
        guard !didStop else { return }
        if let image { feedImage = image }
        if let pixelBuffer, detectorLoaded { detector.process(pixelBuffer) }
    }

    private func handle(detections: [Detection]) {
        guard !didStop else { return }
        self.detections = detections
        let now = CACurrentMediaTime()
        let update = dwell.update(detections: detections, at: now)
        targetBox = update.target?.rect
        holdProgress = update.progress

        guard let snap = update.snap,
              let term = ObjectVocabulary.term(for: snap.label, in: language),
              policy.shouldSpeak(term, confidence: snap.confidence, at: now)
        else { return }
        deliver(term)
    }

    /// A word has been decided on: card, session list, lens, voice. The
    /// card and the list update even when the voice can't or won't speak.
    private func deliver(_ term: TranslatedTerm) {
        current = term
        if recent.first != term {
            recent.insert(term, at: 0)
            if recent.count > Self.recentLimit {
                recent.removeLast(recent.count - Self.recentLimit)
            }
        }
        hermesVM.showTranslationOnLens(term)
        speak(term)
    }

    private func speak(_ term: TranslatedTerm) {
        voiceMissing = !HermesSpeechSynthesizer.hasVoice(for: term.language.voiceCode)
        guard !voiceMissing else { return }
        hermesVM.speakCue(term.word, language: term.language.voiceCode)
    }

    /// Say the word on the card again. The user asked, so the quiet period
    /// does not apply.
    func replay() {
        guard let current else { return }
        speak(current)
    }

    // MARK: - The tap path

    /// Send what is at the centre to the AI. One call at a time.
    func tapped() {
        guard !didStop, aiState != .looking, let frame = feedImage else { return }
        // The language is captured NOW: switching the picker while the
        // call is in flight must not relabel the answer.
        let language = self.language
        let region = targetBox
        let crop = region.flatMap { LensViewModel.crop(frame, to: $0) }
            ?? LensViewModel.crop(frame, to: Self.centreCrop, padding: 0)
            ?? frame
        guard let jpeg = Self.jpeg(crop) else {
            aiState = .failed("Couldn't read the camera frame")
            return
        }

        aiState = .looking
        hermesVM.showTranslationPendingOnLens()

        Task { [weak self, client] in
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await client.askOneShot(
                    systemPrompt: TranslatePrompt.system(for: language),
                    userText: TranslatePrompt.userText,
                    photoJPEG: jpeg,
                    timeout: TranslateViewModel.aiTimeout
                ))
            } catch {
                outcome = .failure(error)
            }
            self?.finishTap(outcome, language: language)
        }
    }

    private func finishTap(_ outcome: Result<String, Error>, language: TranslateLanguage) {
        // Closed while the call was in flight: say and show nothing.
        guard !didStop else { return }

        switch outcome {
        case .success(let reply):
            switch TranslateAnswerParser.parse(reply, language: language) {
            case .term(let term):
                aiState = .idle
                policy.noteSpoken(term, at: CACurrentMediaTime())
                deliver(term)
                return
            case .nothing:
                aiState = .failed("Couldn't tell what that is")
            case .malformed:
                NSLog("[Hermes] translate: unreadable AI reply: \(reply.prefix(200))")
                aiState = .failed("Couldn't tell what that is")
            }
        case .failure(let error):
            NSLog("[Hermes] translate: AI call failed - \(error.localizedDescription)")
            aiState = .failed(Self.message(for: error))
        }
        hermesVM.clearTranslationPendingOnLens()
    }

    static func message(for error: Error) -> String {
        switch error as? AIProviderError {
        case .missingKey:
            return "Add an AI key in Settings to name things the detector doesn't know."
        case .http(let status, _) where status == 401 || status == 403:
            return "The AI key was rejected. Check it in Settings."
        case .badResponse(let message) where message.hasSuffix("cannot read images."):
            return "\(message) Pick a provider with vision in Settings."
        default:
            return "Couldn't tell what that is"
        }
    }

    /// Longest side capped at 768 px: plenty to name one object, and a
    /// small upload on a phone connection.
    private static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 768 / longest)
        guard scale < 1 else { return image.jpegData(compressionQuality: 0.7) }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }
}
