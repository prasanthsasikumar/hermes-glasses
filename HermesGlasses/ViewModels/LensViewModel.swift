//
// LensViewModel.swift
//
// Drives the Lens (Object Snap) view: live glasses frames in, detections
// overlaid, and a 2 s center-dwell crops the pointed-at object into a
// session-only snap strip. Snaps live in memory and die with the view -
// no persistence, no AI, no network.
//

import SwiftUI
import Observation
import CoreMedia
import MWDATCamera

/// One captured object crop. Session-only.
struct LensSnap: Identifiable {
    let id = UUID()
    let image: UIImage
    let label: String
    let date: Date
}

@MainActor
@Observable
final class LensViewModel {
    /// Stages of the snap moment: shutter flash ("Taking a pic…"), then
    /// the crop reveal ("Cropping…"). Nil outside a capture.
    enum CaptureStage: Equatable {
        case flash
        case cropping
    }

    var feedImage: UIImage?
    var detections: [Detection] = []
    var dwellProgress: Double = 0
    var targetLabel: String?
    var snaps: [LensSnap] = []
    var statusText = "Connecting to glasses…"
    var errorBanner: String?
    var isStreaming = false
    var fps = 0
    var captureStage: CaptureStage?

    @ObservationIgnored private let hermesVM: HermesSessionViewModel
    @ObservationIgnored private let camera: HermesCameraManager
    @ObservationIgnored private let detector = ObjectDetector()
    @ObservationIgnored private let dwell = DwellTracker()
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var fpsWindowStart = Date()

    init(hermesVM: HermesSessionViewModel) {
        self.hermesVM = hermesVM
        self.camera = hermesVM.camera
    }

    func start() async {
        errorBanner = nil

        // Connect the glasses camera WITHOUT the voice loop - opening
        // Lens must never leave the mic listening in the background.
        statusText = "Connecting to glasses…"
        do {
            try await hermesVM.ensureCameraSession()
        } catch {
            errorBanner = error.localizedDescription
            statusText = "Glasses unavailable"
            return
        }

        statusText = "Loading model…"
        do {
            try await detector.load()
        } catch {
            // Feed still works without boxes; keep going.
            errorBanner = "Detection model failed to load."
        }

        detector.onDetections = { [weak self] detections in
            // ObjectDetector calls this on the main queue.
            MainActor.assumeIsolated {
                self?.handle(detections: detections)
            }
        }

        statusText = "Starting glasses camera…"
        do {
            try await camera.startLiveStream(
                onFrame: { [weak self] frame in
                    // SDK thread - decode then hop to main.
                    let image = frame.makeUIImage()
                    let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer)
                    Task { @MainActor [weak self] in
                        self?.handle(image: image, pixelBuffer: pixelBuffer)
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.errorBanner = "Camera stream error: \(message)"
                        self?.isStreaming = false
                    }
                }
            )
            isStreaming = true
            statusText = "Point the center at an object"
        } catch {
            errorBanner = error.localizedDescription
            statusText = "Camera unavailable"
        }
    }

    func stop() {
        camera.stopLiveStream()
        detector.onDetections = nil
        isStreaming = false
        hermesVM.releaseCameraSession()
    }

    // MARK: - Private

    private func handle(image: UIImage?, pixelBuffer: CVPixelBuffer?) {
        if let image { feedImage = image }
        if let pixelBuffer { detector.process(pixelBuffer) }

        frameCount += 1
        let elapsed = Date().timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            fps = Int(Double(frameCount) / elapsed)
            frameCount = 0
            fpsWindowStart = Date()
        }
    }

    private func handle(detections: [Detection]) {
        self.detections = detections
        let update = dwell.update(
            detections: detections, at: CACurrentMediaTime()
        )
        dwellProgress = update.progress
        targetLabel = update.target?.label
        if let snap = update.snap, let frame = feedImage {
            runCaptureEffect(frame: frame, detection: snap)
        }
    }

    /// The snap moment: freeze the triggering frame, flash the shutter
    /// ("Taking a pic…"), then reveal the crop ("Cropping…"). The dwell
    /// tracker's cooldown keeps the same object from re-firing meanwhile.
    private func runCaptureEffect(frame: UIImage, detection: Detection) {
        guard captureStage == nil else { return }
        Task { @MainActor in
            captureStage = .flash
            try? await Task.sleep(nanoseconds: 450_000_000)
            captureStage = .cropping
            try? await Task.sleep(nanoseconds: 550_000_000)
            if let cropped = Self.crop(frame, to: detection.rect) {
                snaps.insert(
                    LensSnap(image: cropped, label: detection.label, date: Date()),
                    at: 0
                )
            }
            captureStage = nil
        }
    }

    /// Crop a normalized top-left-origin rect out of `image`, padded 10 %
    /// per side and clamped to the frame.
    static func crop(
        _ image: UIImage, to normalizedRect: CGRect, padding: CGFloat = 0.1
    ) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        var r = normalizedRect.insetBy(
            dx: -normalizedRect.width * padding,
            dy: -normalizedRect.height * padding
        )
        r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, !r.isEmpty else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let pixelRect = CGRect(
            x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h
        ).integral
        guard let cropped = cg.cropping(to: pixelRect) else { return nil }
        return UIImage(
            cgImage: cropped, scale: image.scale,
            orientation: image.imageOrientation
        )
    }
}
