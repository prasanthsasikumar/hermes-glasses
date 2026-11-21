//
// HandPoseDetector.swift
//
// Finds one hand's index and middle finger joints with Vision's built-in
// hand pose request - on-device, no model to bundle. Used by Translate to
// see what a finger points at.
//
// Shaped like ObjectDetector: at most one request in flight, results on
// the MAIN queue, and joints converted ONCE here to the app-wide
// convention (normalised, TOP-LEFT origin) so a fingertip and a detector
// box share one coordinate space. It runs with the same `.up` orientation
// on the same buffer for the same reason.
//
// Throttled: a pointing hand does not need 30 poses a second, and this
// runs beside the object detector on every frame.
//
// Lives outside Services/Translate on purpose - tests/translate compiles
// that whole directory without Vision.
//

import Foundation
import CoreVideo
import Vision
import os

final class HandPoseDetector: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "hand-pose"
    )

    /// Fires on the MAIN queue for each processed frame. Joints are nil
    /// when no hand was found; the second value is frame width / height.
    var onHand: (@Sendable (HandJoints?, CGFloat) -> Void)?

    /// PROVISIONAL: about ten poses a second.
    static let minInterval: TimeInterval = 0.1

    private let queue = DispatchQueue(
        label: "com.flowsxr.hermesglasses.hand-pose"
    )
    private struct Gate {
        var isProcessing = false
        var lastStart: TimeInterval = 0
    }
    private let gate = OSAllocatedUnfairLock(uncheckedState: Gate())

    /// Feed a frame. Cheap to call at full stream rate: frames arriving
    /// too soon, or while a request is in flight, are dropped.
    func process(_ pixelBuffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldStart = gate.withLockUnchecked { state -> Bool in
            guard !state.isProcessing,
                  now - state.lastStart >= Self.minInterval else { return false }
            state.isProcessing = true
            state.lastStart = now
            return true
        }
        guard shouldStart else { return }
        queue.async { [weak self] in self?.run(pixelBuffer) }
    }

    private func run(_ pixelBuffer: CVPixelBuffer) {
        defer { gate.withLockUnchecked { $0.isProcessing = false } }

        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let aspect = height > 0 ? width / height : 1

        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer, orientation: .up
        )
        do {
            try handler.perform([request])
        } catch {
            logger.error("hand pose request failed: \(error.localizedDescription)")
            return
        }

        let observation: VNHumanHandPoseObservation? = request.results?.first
        let joints = observation.flatMap { Self.joints(from: $0) }
        DispatchQueue.main.async { [weak self] in
            self?.onHand?(joints, aspect)
        }
    }

    private static func joints(from observation: VNHumanHandPoseObservation) -> HandJoints? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        func joint(_ name: VNHumanHandPoseObservation.JointName) -> HandJoint? {
            guard let p = points[name] else { return nil }
            // Vision points are normalised with a BOTTOM-LEFT origin;
            // everything downstream uses TOP-LEFT. Flip y here, nowhere else.
            return HandJoint(
                point: CGPoint(x: p.location.x, y: 1 - p.location.y),
                confidence: Double(p.confidence)
            )
        }
        return HandJoints(
            indexMCP: joint(.indexMCP), indexPIP: joint(.indexPIP),
            indexDIP: joint(.indexDIP), indexTip: joint(.indexTip),
            middleMCP: joint(.middleMCP), middlePIP: joint(.middlePIP),
            middleDIP: joint(.middleDIP), middleTip: joint(.middleTip)
        )
    }
}
