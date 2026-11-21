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
//  - AI: a crop goes to the provider (askOneShot - never ask(), nothing
//    lands in conversation memory). The only route for things outside the
//    detector's 80 classes. Two things may start it, and nothing else: a
//    TAP, or a pointing FINGER held still. No tap and no held finger, no
//    call.
//
// The finger (phone camera only): while Finger is ON the centre reticle
// is OFF altogether - only a pointing finger held still names things.
// What it points at goes to the AI as the WHOLE frame (the bundled
// detector forces everything into its 80 classes - a toolbox came back as
// "keyboard" - and a tight crop loses the context the AI needs). The
// detector's word is used only as a fallback when the AI can't be reached
// or isn't set up, and is labelled as the phone's own guess.
//
// Phrases: six bundled things to say to a shopkeeper. A phrase PINS the
// card and pauses recognition, so turning the phone towards someone does
// not replace it with whatever the camera now sees.
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
            // Restart the hold: the tracker is in cooldown on whatever the
            // reticle is resting on, so without this a language switch
            // would say nothing until the user looked away and back.
            _ = dwell.flush(at: CACurrentMediaTime())
            pointHold.reset()
            pointProgress = 0
            // A pinned phrase is in the old language.
            if pinnedPhrase != nil { unpinPhrase() }
        }
    }
    /// Whether a pointing finger may choose the target. Persisted.
    var fingerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(fingerEnabled, forKey: Self.fingerKey)
            if !fingerEnabled { clearPointing() }
            refreshStatus()
        }
    }
    /// Finger pointing is offered on this camera (the iPhone's only).
    var fingerAvailable = false
    /// The pointing hand in view, nil when none.
    var pointing: Pointing?
    var pointProgress: Double = 0
    /// A phrase holding the card. Recognition is paused while set.
    var pinnedPhrase: TranslatedTerm?
    /// What the card shows.
    var shown: TranslatedTerm? { pinnedPhrase ?? current }
    /// The phrase buttons. None in English - nothing to translate.
    var phrases: [TranslatePhrase] {
        language == .english ? [] : TranslatePhrases.all
    }
    var feedImage: UIImage?
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
    static let fingerStatus = "Point a finger at a thing and hold still"
    static let offlineGuess = "Couldn't reach the AI - this is the phone's own guess"
    static let fingerKey = "translate_finger_enabled"
    /// Nobody tapped, so automatic sends are spaced out. PROVISIONAL.
    static let autoSendGap: TimeInterval = 3
    static let phrasePinSeconds: TimeInterval = 20
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
    @ObservationIgnored private let handDetector = HandPoseDetector()
    @ObservationIgnored private var pointHold = PointHold()
    @ObservationIgnored private var lastDetections: [Detection] = []
    @ObservationIgnored private var lastPointingAt: TimeInterval?
    @ObservationIgnored private var lastAutoSend: TimeInterval?
    @ObservationIgnored private var focusSteer = FocusSteer()
    /// Set by a key / provider error: pointing stops sending until the
    /// screen is reopened, instead of failing the same way every hold.
    @ObservationIgnored private var autoSendOff = false
    @ObservationIgnored private var pinGeneration = 0

    /// Finger mode: the finger chooses, the centre reticle is off.
    var fingerActive: Bool { fingerEnabled && fingerAvailable }

    private static let observerKey = "translate"

    init(hermesVM: HermesSessionViewModel) {
        self.hermesVM = hermesVM
        let stored = UserDefaults.standard.string(forKey: TranslateLanguage.storageKey)
        language = stored.flatMap(TranslateLanguage.init(rawValue:)) ?? .defaultLanguage
        fingerEnabled = UserDefaults.standard.object(forKey: Self.fingerKey) as? Bool ?? true
    }

    // MARK: - Lifecycle (mirrors LookupViewModel)

    func start() async {
        errorBanner = nil
        hermesVM.logVisionDiagnostics("translate-start")
        var route = hermesVM.visionRoute

        if route == .glasses {
            statusText = "Connecting to glasses…"
            let granted = await hermesVM.glassesCameraGranted()
            guard !didStop else { return }
            if granted == false {
                needsGlassesCameraGrant = true
                errorBanner = "The glasses camera isn't allowed yet."
                statusText = "Tap Allow camera to grant it in the Meta AI app"
                return
            }
            do {
                try await hermesVM.ensureCameraSession()
            } catch {
                // Closed while connecting: the cancelled wait throws, and
                // must not be mistaken for "glasses unreachable, use the
                // iPhone" - that would start a camera for a gone screen.
                if didStop { teardown(); return }
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

        // Every await below can outlast the screen. stop() ran with nothing
        // to stop then, so whatever was acquired since is torn down here.
        if didStop { teardown(); return }

        hermesVM.pinVisionRoute(route)
        hermesVM.prepareCuePlaybackIfIdle()
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

        if didStop { teardown(); return }

        detector.onDetections = { [weak self] detections in
            MainActor.assumeIsolated {
                self?.handle(detections: detections)
            }
        }

        handDetector.onHand = { [weak self] joints, aspect in
            MainActor.assumeIsolated {
                self?.handle(hand: joints, aspect: aspect)
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
            // Closed while the camera was waking up: the stream that just
            // started is ours, and nobody is left to stop it.
            if didStop { teardown(); return }
            streamStarted()
        } catch {
            if didStop { teardown(); return }
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
        // The wearer's own hands are in a glasses view all day, and that
        // path can't be tested without hardware: the finger is phone-only.
        fingerAvailable = hermesVM.visionRoute == .phone
        refreshStatus()
    }

    private func refreshStatus() {
        guard isStreaming else { return }
        if fingerActive {
            statusText = Self.fingerStatus
        } else {
            statusText = detectorLoaded ? Self.readyStatus : Self.tapOnlyStatus
        }
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
        teardown()
    }

    /// Release everything Translate holds. Safe to run twice - a start
    /// that was still awaiting when the screen closed calls it again for
    /// whatever it acquired late.
    private func teardown() {
        // The camera may be the voice session's too: hand it back centred.
        steerFocus(focusSteer.release())
        if sharesSessionStream {
            hermesVM.removeVisionFrameObserver(Self.observerKey)
        } else {
            vision?.stopLiveStream()
        }
        detector.onDetections = nil
        handDetector.onHand = nil
        pinGeneration += 1
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
        guard let pixelBuffer else { return }
        if detectorLoaded { detector.process(pixelBuffer) }
        if fingerActive, pinnedPhrase == nil { handDetector.process(pixelBuffer) }
    }

    private func handle(detections: [Detection]) {
        guard !didStop else { return }
        let now = CACurrentMediaTime()
        lastDetections = detections

        // A hand that stopped being reported (frames paused) is not a hand.
        if pointing != nil, let last = lastPointingAt, now - last > PointHold.lostReset {
            clearPointing()
        }
        // The reticle is off while a phrase is pinned, and for as long as
        // Finger is on: with pointing on, ONLY the finger names things.
        if pinnedPhrase != nil || fingerActive {
            _ = dwell.flush(at: now)
            holdProgress = 0
            targetBox = nil
            return
        }
        // Only things with a word in this language may hold the reticle -
        // a person behind the cup would otherwise win it and block the cup.
        let speakable = detections.filter {
            ObjectVocabulary.isSpeakable($0.label, in: language)
        }
        let update = dwell.update(detections: speakable, at: now)
        targetBox = update.target?.rect
        holdProgress = update.progress

        guard let snap = update.snap,
              let term = ObjectVocabulary.term(for: snap.label, in: language)
        else { return }

        switch policy.verdict(term, confidence: snap.confidence, at: now) {
        case .speak:
            deliver(term)
        case .uncertain:
            // The tracker spent its snap on a frame the detector wasn't
            // sure of. Restart the hold so a better frame gets its turn,
            // instead of a full ring and silence.
            _ = dwell.flush(at: now)
        case .quiet:
            break
        }
    }

    // MARK: - The finger

    private func handle(hand joints: HandJoints?, aspect: CGFloat) {
        guard !didStop, fingerActive, pinnedPhrase == nil else { return }
        let now = CACurrentMediaTime()
        let found = joints.flatMap { FingerPointer.pointing(from: $0, aspect: aspect) }

        if let found {
            pointing = found
            lastPointingAt = now
        } else if let last = lastPointingAt, now - last >= PointHold.flickerGrace {
            pointing = nil
            lastPointingAt = nil
            pointProgress = 0
        }

        // Focus follows the point, not the hand in front of it. `pointing`
        // (not `found`) so one missed pose frame doesn't swing focus away.
        steerFocus(focusSteer.update(probe: pointing?.probe))

        let update = pointHold.update(probe: found?.probe, at: now)
        guard let found else { return }
        pointProgress = update.progress
        if update.fired { firePoint(found, at: now) }
    }

    /// The detector's own word for what the finger is on, if it has a
    /// confident one. A FALLBACK only - never the first answer.
    private func detectorGuess(for pointing: Pointing) -> TranslatedTerm? {
        guard case (.box, let detection?) = fingerTarget(pointing),
              detection.confidence >= TranslateSpeakPolicy.minimumConfidence
        else { return nil }
        return ObjectVocabulary.term(for: detection.label, in: language)
    }

    /// What the finger is on: a known box, or a region for the AI.
    private func fingerTarget(_ pointing: Pointing) -> (PointTarget, Detection?) {
        let speakable = lastDetections.filter {
            ObjectVocabulary.isSpeakable($0.label, in: language)
        }
        let target = FingerPointer.target(for: pointing, boxes: speakable.map(\.rect))
        if case .box(let index) = target { return (target, speakable[index]) }
        return (target, nil)
    }

    /// The finger has rested on one spot for the hold time.
    private func firePoint(_ pointing: Pointing, at now: TimeInterval) {
        let guess = detectorGuess(for: pointing)

        // No usable AI (no key, rejected key): the phone's guess is all
        // there is, so say it rather than nothing.
        guard !autoSendOff else {
            if let guess { deliverGuess(guess) }
            return
        }
        // Nobody tapped, so this send sits behind guards a tap doesn't need.
        let tooSoon = lastAutoSend.map { now - $0 < Self.autoSendGap } ?? false
        guard aiState != .looking, !tooSoon else {
            // Blocked, not answered: let a finger still resting here send
            // once the guard clears.
            pointHold.restart()
            return
        }
        lastAutoSend = now
        send(.frame, pointing: true, fallback: guess)
    }

    /// The detector's word, spoken because the AI couldn't answer.
    private func deliverGuess(_ term: TranslatedTerm) {
        aiState = .failed(Self.offlineGuess)
        policy.noteSpoken(term, at: CACurrentMediaTime())
        deliver(term)
    }

    private func clearPointing() {
        pointing = nil
        lastPointingAt = nil
        pointProgress = 0
        pointHold.reset()
        steerFocus(focusSteer.release())
    }

    private func steerFocus(_ change: FocusSteer.Change?) {
        guard let change, fingerAvailable else { return }
        switch change {
        case .point(let point): hermesVM.phoneCamera.focus(at: point)
        case .centre: hermesVM.phoneCamera.focus(at: nil)
        }
    }

    // MARK: - Phrases

    /// Speak a phrase and pin it to the card so the phone can be held up.
    func speakPhrase(_ phrase: TranslatePhrase) {
        guard !didStop, let term = TranslatePhrases.term(for: phrase, in: language) else { return }
        let now = CACurrentMediaTime()
        pinnedPhrase = term
        clearPointing()
        _ = dwell.flush(at: now)
        holdProgress = 0
        targetBox = nil
        hermesVM.showTranslationOnLens(term)
        speak(term)

        pinGeneration += 1
        let generation = pinGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.phrasePinSeconds))
            guard let self, self.pinGeneration == generation else { return }
            self.unpinPhrase()
        }
    }

    func unpinPhrase() {
        pinGeneration += 1
        pinnedPhrase = nil
        clearPointing()
        _ = dwell.flush(at: CACurrentMediaTime())
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
        // A pinned phrase keeps the card, the lens and the silence: an AI
        // answer landing now is kept for when the pin ends.
        guard pinnedPhrase == nil else { return }
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
        guard let shown else { return }
        speak(shown)
    }

    // MARK: - The AI path

    private enum Crop {
        /// A detector box: cropped with the usual padding.
        case box(CGRect)
        /// A bare part of the frame.
        case region(CGRect)
        /// Everything the camera sees - the finger says which thing.
        case frame
    }

    /// Ask the AI about one thing. With a pointing finger in view that is
    /// what the finger is on; otherwise what is at the centre.
    func tapped() {
        guard !didStop, pinnedPhrase == nil, aiState != .looking else { return }
        if fingerActive, let pointing {
            // The tap is the send for this spot: the hold must not send
            // it a second time.
            pointHold.spend(at: pointing.probe)
            lastAutoSend = CACurrentMediaTime()
            send(.frame, pointing: true, fallback: detectorGuess(for: pointing))
        } else {
            send(targetBox.map { .box($0) } ?? .region(Self.centreCrop), pointing: false, fallback: nil)
        }
    }

    /// One call at a time; a tap and a held finger both end up here.
    /// `fallback` is what to say if the AI can't be reached.
    private func send(_ crop: Crop, pointing: Bool, fallback: TranslatedTerm?) {
        guard !didStop, aiState != .looking, let frame = feedImage else { return }
        // The language is captured NOW: switching the picker while the
        // call is in flight must not relabel the answer.
        let language = self.language
        let cropped: UIImage?
        switch crop {
        case .box(let rect): cropped = LensViewModel.crop(frame, to: rect)
        case .region(let rect): cropped = LensViewModel.crop(frame, to: rect, padding: 0)
        case .frame: cropped = frame
        }
        let image = cropped
            ?? LensViewModel.crop(frame, to: Self.centreCrop, padding: 0)
            ?? frame
        // A whole scene needs more pixels than one cropped object.
        guard let jpeg = Self.jpeg(image, longestSide: pointing ? 1280 : 768) else {
            aiState = .failed("Couldn't read the camera frame")
            return
        }

        aiState = .looking
        hermesVM.showTranslationPendingOnLens()

        Task { [weak self, client] in
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await client.askOneShot(
                    systemPrompt: TranslatePrompt.system(for: language, pointing: pointing),
                    userText: TranslatePrompt.userText,
                    photoJPEG: jpeg,
                    timeout: TranslateViewModel.aiTimeout
                ))
            } catch {
                outcome = .failure(error)
            }
            self?.finishTap(outcome, language: language, fallback: fallback)
        }
    }

    private func finishTap(
        _ outcome: Result<String, Error>, language: TranslateLanguage,
        fallback: TranslatedTerm?
    ) {
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
            // A missing or rejected key fails the same way every time;
            // pointing must not keep trying it. Tap still does.
            if Self.isSetupError(error) { autoSendOff = true }
            // The AI never saw it. The detector's word is better than
            // nothing, as long as it is shown for what it is. (Not after
            // "couldn't tell" above: the AI looked, and a guess would
            // contradict it.)
            if let fallback, pinnedPhrase == nil {
                hermesVM.clearTranslationPendingOnLens()
                deliverGuess(fallback)
                return
            }
        }
        // The lens is showing the pinned phrase, not "Looking…".
        guard pinnedPhrase == nil else { return }
        hermesVM.clearTranslationPendingOnLens()
    }

    /// The call can't succeed until something changes in Settings.
    static func isSetupError(_ error: Error) -> Bool {
        switch error as? AIProviderError {
        case .missingKey:
            return true
        case .http(let status, _):
            // 400 is how Gemini rejects a bad key; 402 is no credit left.
            return [400, 401, 402, 403].contains(status)
        case .badResponse(let message):
            return message.hasSuffix("cannot read images.")
        default:
            return false
        }
    }

    static func message(for error: Error) -> String {
        if error is URLError { return "Couldn't reach the AI" }
        switch error as? AIProviderError {
        case .missingKey:
            return "Add an AI key in Settings to name things the detector doesn't know."
        case .http(let status, _) where status == 401 || status == 403:
            return "The AI key was rejected. Check it in Settings."
        case .http(let status, _) where status == 400 || status == 402:
            return "The AI refused the request. Check the key and plan in Settings."
        case .http(429, _):
            return "The AI is rate-limiting requests. Try again in a moment."
        case .badResponse(let message) where message.hasSuffix("cannot read images."):
            return "\(message) Pick a provider with vision in Settings."
        default:
            return "Couldn't tell what that is"
        }
    }

    /// Longest side capped (768 px for one cropped object, 1280 px for a
    /// whole pointed-at scene): a small upload on a phone connection.
    private static func jpeg(_ image: UIImage, longestSide: CGFloat) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, longestSide / longest)
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
