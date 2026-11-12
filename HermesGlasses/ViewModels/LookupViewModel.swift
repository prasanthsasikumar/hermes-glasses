//
// LookupViewModel.swift
//
// Drives the Lookup app: live frames in, YOLO person boxes through
// PersonLookupGate (close + centered + held), then a Vision face check
// ("are they actually facing me?"), then identification against the
// IMPORTED ROSTER - entirely on-device.
//
// Nothing leaves the phone here. No provider, no web search, no badge OCR.
// The face crop is aligned by FaceAlignment (the same call the importer
// makes), embedded by the bundled model, and compared against RosterStore
// by FaceMatcher. A name appears only when the match clears a threshold AND
// beats the runner-up by a margin; otherwise the wearer is told the person
// is not in the roster, which is a real answer rather than a hedge.
//
// This IS face recognition, and it is the only place in the app that does
// any. Encounter/People grouping is still by badge text and shares no
// identity data with this path - a roster match is a momentary read on the
// lens, never written into an encounter.
//
// Camera plumbing mirrors LensViewModel: route decided at start, glasses
// falling back to the phone, shared-stream observation in phone mode, and
// the stream torn down with the view.
//

import SwiftUI
import Observation
import CoreMedia
import Vision

/// One person recognised this session. Session-only, in memory - Lookup
/// deliberately keeps no store: who you saw is a moment's context, and the
/// roster already holds everything worth persisting about them.
struct LookupHit: Identifiable {
    let id = UUID()
    let image: UIImage
    let name: String
    let summary: String
    let date: Date
    /// The roster entry this came from, nil for the unavailable states.
    let personID: UUID?

    init(image: UIImage, name: String, summary: String,
         date: Date = Date(), personID: UUID? = nil) {
        self.image = image
        self.name = name
        self.summary = summary
        self.date = date
        self.personID = personID
    }
}

@MainActor
@Observable
final class LookupViewModel {
    enum Phase: Equatable {
        case connecting
        case scanning
        /// Fired: checking the snap actually shows a face turned this way.
        case verifying
        /// Embedding the face and comparing it against the roster.
        case matching
        case result
    }

    var phase: Phase = .connecting
    var feedImage: UIImage?
    /// Person boxes only, for the overlay (normalized, top-left origin).
    var personBoxes: [CGRect] = []
    /// The box the gate is holding on, nil when nobody qualifies.
    var targetBox: CGRect?
    var holdProgress: Double = 0
    var statusText = "Connecting to camera…"
    var errorBanner: String?
    var isStreaming = false
    var needsGlassesCameraGrant = false
    /// Newest first. The latest hit is the result card.
    var hits: [LookupHit] = []

    @ObservationIgnored private let hermesVM: HermesSessionViewModel
    @ObservationIgnored private var vision: VisionSource?
    @ObservationIgnored private var sharesSessionStream = false
    @ObservationIgnored private let detector = ObjectDetector()
    @ObservationIgnored private var gate = PersonLookupGate()
    @ObservationIgnored private let roster = RosterStore()
    @ObservationIgnored private let embedder = FaceEmbedder()
    @ObservationIgnored private var didStop = false

    /// Measured on the real roster with the bundled MobileFaceNet
    /// (`face-probe separation` + `simulate`, 2026-08-16):
    ///
    ///   worst stranger pair            0.408
    ///   same person, face 40 px wide   0.849 (p10), 0.755 (min)
    ///   same person, face 80 px + blur 0.883 (p10)
    ///
    /// 0.50 sits clearly above every stranger pair in this roster while
    /// leaving room below the weakest genuine match. The asymmetry is
    /// deliberate: too high costs a recognition the wearer simply retries,
    /// too low puts a real name on the wrong face while that person is
    /// standing in front of them.
    ///
    /// STILL UNVERIFIED: those same-person numbers come from degraded
    /// copies of the SAME source photo, so they overstate what a genuinely
    /// different photo scores. Confirm against real device crops before
    /// trusting this at the conference - and if it misses, raise
    /// `PersonLookupGate`'s proximity requirement so the face is bigger,
    /// rather than lowering this.
    @ObservationIgnored private let matcher = FaceMatcher(
        acceptThreshold: 0.50, margin: 0.10
    )

    /// True when the app cannot identify anyone at all, whatever it sees.
    var faceModelMissing: Bool { embedder == nil }
    var rosterIsEmpty: Bool { roster.matchableCount == 0 }

    private static let observerKey = "lookup"

    init(hermesVM: HermesSessionViewModel) {
        self.hermesVM = hermesVM
    }

    // MARK: - Lifecycle (mirrors LensViewModel)

    func start() async {
        errorBanner = nil
        hermesVM.logVisionDiagnostics("lookup-start")
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
                NSLog("[Hermes] lookup: glasses unavailable (\(error.localizedDescription)) - using iPhone")
                errorBanner = "Glasses unreachable - using the iPhone camera."
                route = .phone
            }
        }

        hermesVM.pinVisionRoute(route)
        vision = hermesVM.vision
        sharesSessionStream = hermesVM.visionStreamIsShared
        // Result cards go to the real lens even without a voice session.
        hermesVM.attachDisplayToCameraSession()

        statusText = "Loading model…"
        do {
            try await detector.load()
        } catch {
            // Without boxes the gate can never fire - unlike Lens, this is
            // fatal to the feature, so say so instead of streaming quietly.
            errorBanner = "Detection model failed to load."
        }

        detector.onDetections = { [weak self] detections in
            MainActor.assumeIsolated {
                self?.handle(detections: detections)
            }
        }

        await beginStream()
    }

    private func beginStream() async {
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
            NSLog("[Hermes] lookup: \(hermesVM.visionRoute) stream failed - \(error.localizedDescription)")
            hermesVM.logVisionDiagnostics("lookup-stream-failed")

            guard hermesVM.visionRoute == .glasses,
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
            await beginPhoneStream()
        }
    }

    /// Second attempt, on the phone - separate so a failure here reports
    /// honestly instead of recursing.
    private func beginPhoneStream() async {
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
        statusText = "Starting iPhone camera…"
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
            NSLog("[Hermes] lookup: iPhone fallback also failed - \(error.localizedDescription)")
            errorBanner = error.localizedDescription
            statusText = "Camera unavailable"
        }
    }

    private func streamStarted() {
        isStreaming = true
        phase = .scanning
        statusText = "Face someone close by - hold steady to identify them"
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
        // Only Lookup's own pin is released - a running voice session
        // pinned its route first and owns it until the session ends.
        if !hermesVM.phoneModeActive, hermesVM.connectionState == .disconnected {
            hermesVM.unpinVisionRoute()
        }
        // Before releaseCameraSession - the display capability dies with it.
        hermesVM.detachDisplayFromCameraSession()
        hermesVM.releaseCameraSession()
    }

    // MARK: - Frames and detections

    private func handle(image: UIImage?, pixelBuffer: CVPixelBuffer?) {
        if let image { feedImage = image }
        if let pixelBuffer { detector.process(pixelBuffer) }
    }

    private func handle(detections: [Detection]) {
        let persons = detections.filter { $0.label == "person" }.map(\.rect)
        personBoxes = persons

        // The gate only advances while scanning - a lookup in flight keeps
        // the frozen state on screen.
        guard phase == .scanning else { return }

        let update = gate.update(personBoxes: persons, at: CACurrentMediaTime())
        targetBox = update.target
        holdProgress = update.progress

        if let rect = update.fire {
            phase = .verifying
            statusText = "Checking they're facing you…"
            Task { await processCandidate(rect: rect) }
        }
    }

    // MARK: - The snap pipeline

    private func processCandidate(rect: CGRect) async {
        guard let frame = feedImage,
              let crop = LensViewModel.crop(frame, to: rect) else {
            gate.rejected(at: CACurrentMediaTime())
            backToScanning("Lost them - hold steady")
            return
        }

        // Facing check: face DETECTION only, on-device, and only to answer
        // "are they turned towards the wearer". Someone showing their back
        // or profile is not being faced, so no lookup. Also returns the face
        // rect so the face path can crop tight to it.
        guard let faceRect = await Self.frontalFace(in: crop) else {
            gate.rejected(at: CACurrentMediaTime())
            backToScanning("Waiting for them to face you…")
            return
        }

        // From here the snap is spent, whatever the matcher says.
        gate.fired(at: CACurrentMediaTime())

        guard let embedder else {
            // Said plainly rather than degraded into a weaker matcher - see
            // FaceEmbedder's header for why there is no fallback here.
            finish(crop: crop, name: "Face model not installed",
                   summary: "Lookup needs the face recognition model to identify anyone.")
            return
        }

        phase = .matching
        statusText = "Matching…"
        hermesVM.showLookupSearchingOnLens()

        // Same alignment the roster portraits went through at import - the
        // one function, so the two sides cannot drift apart.
        let faceCrop = LensViewModel.crop(crop, to: faceRect, padding: 0.35) ?? crop
        guard let probe = await embedder.embed(faceCrop) else {
            backToScanning("Couldn't read their face - hold steady")
            return
        }

        let gallery = roster.all()
        switch matcher.match(probe: probe, gallery: gallery) {
        case .match(let personID, let score):
            guard let person = gallery.first(where: { $0.id == personID }) else {
                backToScanning("Not in the roster")
                return
            }
            NSLog("[Hermes] lookup: matched \(person.name) at \(score)")
            finish(crop: crop, person: person)

        case .unknown(let reason):
            // The wearer sees a short message; the log keeps the numbers,
            // because belowThreshold and ambiguous mean different things
            // when the constants are being tuned.
            switch reason {
            case .emptyRoster:
                backToScanning("No roster imported - add one in Settings")
                hermesVM.showPersonLookupOnLens(
                    name: "No roster", info: "Import one in Settings → People roster."
                )
            case .belowThreshold(let best):
                NSLog("[Hermes] lookup: no match, best \(best)")
                backToScanning("Not in the roster")
                hermesVM.showPersonLookupOnLens(name: "Not in the roster", info: "")
            case .ambiguous(let best, let runnerUp):
                NSLog("[Hermes] lookup: ambiguous, \(best) vs \(runnerUp)")
                backToScanning("Not sure — too close to call")
                hermesVM.showPersonLookupOnLens(
                    name: "Not sure", info: "Too close to call between two people."
                )
            }
        }
    }

    /// A recognised roster member.
    private func finish(crop: UIImage, person: RosterPerson) {
        finish(crop: crop, name: person.name,
               summary: person.detailLine, personID: person.id)
    }

    private func finish(
        crop: UIImage, name: String, summary: String, personID: UUID? = nil
    ) {
        hits.insert(
            LookupHit(image: crop, name: name, summary: summary,
                      personID: personID),
            at: 0
        )
        phase = .result
        statusText = "Face someone close by - hold steady to identify them"
        hermesVM.showPersonLookupOnLens(name: name, info: summary)
        // Scanning resumes underneath the result card; the gate's fired
        // cooldown keeps the same person from immediately re-firing.
        phase = .scanning
    }

    private func backToScanning(_ message: String) {
        statusText = message
        phase = .scanning
    }

    /// Does this person crop contain a face turned roughly towards the
    /// camera, and if so, where is it? Detection only -
    /// VNDetectFaceRectanglesRequest finds faces and estimates yaw; nothing
    /// here identifies anyone. Returns the LARGEST frontal face as a
    /// normalized top-left-origin rect, nil when nobody is facing the
    /// wearer. Detached for the same reason BadgeReader's passes are: the
    /// Vision call is synchronous and the caller is on the main actor.
    static func frontalFace(in image: UIImage) async -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        return await Task.detached(priority: .utility) { () -> CGRect? in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("[Hermes] lookup: face request failed - \(error.localizedDescription)")
                return nil
            }
            let frontal = (request.results ?? []).filter { face in
                // A face at conversational range is a decent slice of the
                // crop; tiny ones are bystanders in the background.
                guard face.boundingBox.width >= 0.12 else { return false }
                // Yaw ±~35° counts as facing. When Vision doesn't report
                // yaw, finding the face at all is the (near-frontal) signal.
                guard let yaw = face.yaw?.doubleValue else { return true }
                return abs(yaw) <= 0.62
            }
            guard let largest = frontal.max(by: {
                $0.boundingBox.width * $0.boundingBox.height
                    < $1.boundingBox.width * $1.boundingBox.height
            }) else { return nil }

            // Vision is bottom-left origin; flip to the app-wide top-left.
            let box = largest.boundingBox
            return CGRect(
                x: box.minX, y: 1 - box.maxY,
                width: box.width, height: box.height
            )
        }.value
    }
}
