//
// ObjectDetector.swift
//
// YOLO object detection for the Lens view. Wraps the bundled yolo11n
// CoreML model (ultralytics export with nms=True, so Vision returns
// VNRecognizedObjectObservation directly) behind latest-wins
// backpressure: at most one Vision request in flight; while it runs,
// newer frames replace the single pending slot and stale ones are
// dropped. Detections are reported on the main queue with rects
// converted to the app-wide convention (normalized, TOP-LEFT origin).
//

import Foundation
import CoreML
import CoreVideo
import Vision
import os

final class ObjectDetector: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "lens-detector"
    )

    /// Bundle resource name of the compiled model (see tools/export-yolo.md)
    static let modelName = "yolo11n"

    /// Detections below this confidence are dropped
    private let confidenceThreshold: VNConfidence = 0.4

    /// Fires on the MAIN queue with each processed frame's detections.
    var onDetections: (@Sendable ([Detection]) -> Void)?

    private let queue = DispatchQueue(
        label: "com.flowsxr.hermesglasses.lens-detector"
    )
    private struct Backpressure {
        var isProcessing = false
        var pending: CVPixelBuffer?
    }
    private let backpressure = OSAllocatedUnfairLock(
        uncheckedState: Backpressure()
    )
    private let modelLock = OSAllocatedUnfairLock<VNCoreMLModel?>(
        uncheckedState: nil
    )

    enum DetectorError: Error {
        case modelMissing
    }

    /// Load + compile-check the bundled model. Call once before process().
    func load() async throws {
        guard let url = Bundle.main.url(
            forResource: Self.modelName, withExtension: "mlmodelc"
        ) else {
            logger.error("model \(Self.modelName).mlmodelc missing from bundle")
            throw DetectorError.modelMissing
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all // let CoreML pick the Neural Engine
        let mlModel = try MLModel(contentsOf: url, configuration: config)
        let visionModel = try VNCoreMLModel(for: mlModel)
        modelLock.withLockUnchecked { $0 = visionModel }
        logger.info("lens model loaded")
    }

    /// Feed a frame. Cheap to call at full stream rate - frames arriving
    /// while a request is in flight overwrite the one pending slot.
    func process(_ pixelBuffer: CVPixelBuffer) {
        let shouldStart = backpressure.withLockUnchecked { state -> Bool in
            if state.isProcessing {
                state.pending = pixelBuffer
                return false
            }
            state.isProcessing = true
            return true
        }
        guard shouldStart else { return }
        queue.async { [weak self] in self?.run(pixelBuffer) }
    }

    // MARK: - Private

    private func run(_ pixelBuffer: CVPixelBuffer) {
        defer {
            let next = backpressure.withLockUnchecked { state -> CVPixelBuffer? in
                if let pending = state.pending {
                    state.pending = nil
                    return pending
                }
                state.isProcessing = false
                return nil
            }
            if let next {
                queue.async { [weak self] in self?.run(next) }
            }
        }

        guard let model = modelLock.withLockUnchecked({ $0 }) else { return }

        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer, orientation: .up
        )
        do {
            try handler.perform([request])
        } catch {
            logger.error("vision request failed: \(error.localizedDescription)")
            return
        }

        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
        let detections = observations.compactMap { obs -> Detection? in
            guard obs.confidence >= confidenceThreshold,
                  let top = obs.labels.first else { return nil }
            // Vision boxes are normalized with a BOTTOM-LEFT origin;
            // everything downstream uses TOP-LEFT. Flip y here, nowhere else.
            let bb = obs.boundingBox
            let rect = CGRect(
                x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height
            )
            return Detection(
                label: top.identifier, confidence: obs.confidence, rect: rect
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.onDetections?(detections)
        }
    }
}
