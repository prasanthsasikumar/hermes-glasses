//
// PhoneCameraManager.swift
//
// The iPhone's own camera as a VisionSource, for phone mode (design 5b):
// no glasses on you, so the phone becomes the eye and the lens is
// simulated on screen.
//
// Deliberately shaped like HermesCameraManager so the two are
// interchangeable:
//   * one persistent stream, torn down by stopLiveStream()
//   * capturePhoto() serves the freshest live frame rather than opening a
//     competing capture, so a visual query never stutters the feed
//   * 4:3 output, matching the glasses' aspect, so the Lens reticle and
//     YOLO boxes behave identically on either eye
//

import AVFoundation
import CoreVideo
import UIKit
import os

enum PhoneCameraError: LocalizedError {
    case permissionDenied
    case noCamera
    case configurationFailed
    case streamInUse
    case noFrame

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Camera access is off for Hermes. Turn it on in Settings to use phone mode."
        case .noCamera:
            return "This device has no usable rear camera."
        case .configurationFailed:
            return "Could not start the iPhone camera."
        case .streamInUse:
            return "The iPhone camera is already streaming."
        case .noFrame:
            return "No frame from the iPhone camera yet."
        }
    }
}

final class PhoneCameraManager: NSObject, @unchecked Sendable, VisionSource {
    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "phone-camera"
    )

    var onDebug: ((String) -> Void)?

    let sourceLabel = "iPhone camera"

    /// Human-readable lens description for the phone-mode status tiles.
    private(set) var lensDescription = "Rear · wide"

    private let session = AVCaptureSession()
    /// Frames are delivered here, off the main thread.
    private let outputQueue = DispatchQueue(
        label: "com.flowsxr.hermesglasses.phone-camera"
    )

    private struct State {
        var running = false
        var latestPixelBuffer: CVPixelBuffer?
        var latestImage: UIImage?
        var onFrame: (@Sendable (VisionFrame) -> Void)?
        var onError: (@Sendable (String) -> Void)?
        var frameCount = 0
    }

    private let stateLock = OSAllocatedUnfairLock(uncheckedState: State())

    var isStreaming: Bool {
        stateLock.withLockUnchecked { $0.running }
    }

    /// Frames delivered since the stream started, for the 5b fps chip.
    var frameCount: Int {
        stateLock.withLockUnchecked { $0.frameCount }
    }

    // MARK: - VisionSource

    func startLiveStream(
        onFrame: @escaping @Sendable (VisionFrame) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        if isStreaming { throw PhoneCameraError.streamInUse }

        // Ask rather than assume: phone mode can be entered from the
        // session screen without ever passing through onboarding.
        guard await Self.ensurePermission() else {
            throw PhoneCameraError.permissionDenied
        }

        stateLock.withLockUnchecked { state in
            state.onFrame = onFrame
            state.onError = onError
        }

        try configureIfNeeded()

        // startRunning blocks; keep it off the main actor.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            outputQueue.async { [weak self] in
                self?.session.startRunning()
                continuation.resume()
            }
        }

        stateLock.withLockUnchecked { $0.running = true }
        debug("phone camera: streaming")
    }

    func stopLiveStream() {
        let wasRunning = stateLock.withLockUnchecked { state -> Bool in
            let was = state.running
            state.running = false
            state.onFrame = nil
            state.onError = nil
            state.latestPixelBuffer = nil
            state.latestImage = nil
            state.frameCount = 0
            return was
        }
        guard wasRunning else { return }
        outputQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        debug("phone camera: stopped")
    }

    /// JPEG of the freshest streamed frame. If nothing is streaming - a
    /// visual query on the glasses route that fell back to the phone, say -
    /// spin the camera up briefly, take one frame, and shut it down again.
    /// Mirrors HermesCameraManager's one-shot behaviour so either eye can
    /// serve a still without the caller knowing which it is.
    func capturePhoto() async throws -> Data {
        if let jpeg = latestJPEG() { return jpeg }

        guard !isStreaming else { throw PhoneCameraError.noFrame }

        try await startLiveStream(onFrame: { _ in }, onError: { _ in })
        defer { stopLiveStream() }

        // AVCaptureSession takes a moment to deliver its first frame.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let jpeg = latestJPEG() {
                debug("phone camera: one-shot photo (\(jpeg.count) bytes)")
                return jpeg
            }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        throw PhoneCameraError.noFrame
    }

    private func latestJPEG() -> Data? {
        guard let image = stateLock.withLockUnchecked({ $0.latestImage }) else {
            return nil
        }
        return image.jpegData(compressionQuality: HermesCameraManager.jpegQuality)
    }

    // MARK: - Focus

    /// Aim continuous autofocus (and exposure) at a point in the portrait
    /// frame - normalised, TOP-LEFT origin - or back at the centre with
    /// nil. Translate uses it so a pointing hand in front of the lens is
    /// not what the camera focuses on. Best-effort: a device that can't do
    /// it is left as it was.
    func focus(at point: CGPoint?) {
        outputQueue.async { [weak self] in
            guard let self,
                  let device = (self.session.inputs.first as? AVCaptureDeviceInput)?.device
            else { return }
            let target = FocusSteer.devicePoint(
                forPortrait: point ?? CGPoint(x: 0.5, y: 0.5)
            )
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = target
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = target
                    device.exposureMode = .continuousAutoExposure
                }
            } catch {
                self.logger.error("focus change failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Permission

    /// Already granted? Never prompts - for the non-interactive gates on the
    /// capture paths, which must not throw a dialog mid-sentence.
    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Grants, or reports the existing decision. Safe to call repeatedly.
    static func ensurePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Session configuration

    private func configureIfNeeded() throws {
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 640x480 is 4:3 like the glasses, and plenty for YOLO's 640 input -
        // a bigger preset would only cost battery and heat.
        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            throw PhoneCameraError.noCamera
        }

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            throw PhoneCameraError.configurationFailed
        }
        session.addInput(input)

        // The default autofocus snaps, and a live feed with things moving
        // through it (a hand, a passer-by) visibly pumps in and out. The
        // smooth variant is the one meant for video.
        if device.isSmoothAutoFocusSupported,
           (try? device.lockForConfiguration()) != nil {
            device.isSmoothAutoFocusEnabled = true
            device.unlockForConfiguration()
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]
        // Vision only ever wants the newest frame; queueing them up would
        // add latency to the dwell tracker for no benefit.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw PhoneCameraError.configurationFailed
        }
        session.addOutput(output)

        // Portrait: the phone is held upright in phone mode, and Detection
        // rects are normalized to the image, so the frame must arrive the
        // way the user sees it.
        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        lensDescription = device.localizedName.contains("Back")
            ? "Rear · wide" : device.localizedName
        debug("phone camera: configured \(device.localizedName)")
    }

    private func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        onDebug?(message)
    }
}

// MARK: - Frame delivery

extension PhoneCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let image = Self.makeImage(from: pixelBuffer)

        let handler = stateLock.withLockUnchecked { state -> (@Sendable (VisionFrame) -> Void)? in
            guard state.running else { return nil }
            state.latestPixelBuffer = pixelBuffer
            if let image { state.latestImage = image }
            state.frameCount += 1
            return state.onFrame
        }
        guard let handler else { return }
        handler(VisionFrame(image: image, pixelBuffer: pixelBuffer))
    }

    /// One context for the process: constructing a CIContext per frame sets
    /// up a GPU pipeline 24 times a second.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func makeImage(from buffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
