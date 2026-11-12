//
// FaceEmbedding.swift
//
// The face -> vector core, shared by three callers that must never disagree:
// the roster importer, the live Lookup snap, and tools/face-probe.swift.
// The probe is the reason this file is CoreGraphics + Vision only, with no
// UIKit: it compiles on macOS, so the thresholds are measured against the
// code that actually ships rather than a re-implementation of it.
//
// Two backends:
//
//   .coreML          - a bundled ArcFace-class faceid.mlpackage. The real
//                      thing. See tools/export-face.md.
//   .visionFeaturePrint - Apple's general-purpose image descriptor, run on
//                      the ALIGNED, background-free 112x112 crop.
//
// The second is PROVISIONAL and says so everywhere it surfaces. It is not a
// face recogniser: it describes an image, and identity is only part of what
// it encodes. It exists because it needs no model file at all, so the
// pipeline can be exercised end to end before a real recogniser is
// converted - and because aligning the crop first removes most of what made
// it hopeless (framing, background, head tilt, scale).
//
// It must never be presented as the finished feature. `isProvisional` is
// what the UI reads to say so.
//

import Foundation
import CoreGraphics
import Vision
import CoreML

enum FaceEmbeddingBackend {
    case coreML(MLModel, inputName: String)
    case visionFeaturePrint

    var modelID: String {
        switch self {
        case .coreML(let model, _):
            return "faceid-in\(Int(FaceAlignment.outputSize))"
                + "-out\(model.modelDescription.outputDescriptionsByName.count)"
        case .visionFeaturePrint:
            return "vision-featureprint-aligned112-v1"
        }
    }

    var isProvisional: Bool {
        if case .visionFeaturePrint = self { return true }
        return false
    }
}

enum FaceEmbedding {
    /// Eye centres in image pixel coordinates (top-left origin) for the
    /// largest detected face. Nil when no face is found, or when Vision
    /// finds a face but no eye landmarks - a face that cannot be aligned is
    /// no use to anything downstream.
    static func eyes(in image: CGImage) -> (left: CGPoint, right: CGPoint)? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let face = (request.results ?? []).max(by: {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }), let marks = face.landmarks,
           let leftEye = marks.leftEye, let rightEye = marks.rightEye
        else { return nil }

        // Landmark points are normalised to the FACE BOUNDING BOX, which is
        // itself normalised to the image and bottom-left origin. Both
        // conversions happen here, once, so everything downstream is in the
        // app-wide top-left pixel convention.
        let box = face.boundingBox
        func centre(_ region: VNFaceLandmarkRegion2D) -> CGPoint? {
            let points = region.normalizedPoints
            guard !points.isEmpty else { return nil }
            let sum = points.reduce(CGPoint.zero) {
                CGPoint(x: $0.x + CGFloat($1.x), y: $0.y + CGFloat($1.y))
            }
            let mean = CGPoint(x: sum.x / CGFloat(points.count),
                               y: sum.y / CGFloat(points.count))
            let nx = box.minX + mean.x * box.width
            let ny = box.minY + mean.y * box.height
            return CGPoint(x: nx * width, y: (1 - ny) * height)
        }
        guard let l = centre(leftEye), let r = centre(rightEye) else { return nil }
        // Vision's "left eye" is the subject's left, which appears on the
        // RIGHT of the image. FaceAlignment wants them left-most first.
        return l.x <= r.x ? (l, r) : (r, l)
    }

    /// The aligned 112x112 crop, or nil when there is no usable face.
    static func alignedCrop(_ image: CGImage) -> CGImage? {
        guard let eyePair = eyes(in: image) else { return nil }
        let transform = FaceAlignment.transform(leftEye: eyePair.left,
                                                rightEye: eyePair.right)
        guard transform != .identity else { return nil }
        return render(image, transform: transform,
                      edge: Int(FaceAlignment.outputSize))
    }

    /// Align, embed, L2-normalise. Nil when there is no usable face.
    static func embed(_ image: CGImage, backend: FaceEmbeddingBackend) -> [Float]? {
        guard let aligned = alignedCrop(image) else { return nil }
        let raw: [Float]?
        switch backend {
        case .coreML(let model, let inputName):
            raw = coreMLVector(aligned, model: model, inputName: inputName)
        case .visionFeaturePrint:
            raw = featurePrintVector(aligned)
        }
        guard var values = raw, !values.isEmpty else { return nil }
        // L2-normalise HERE. FaceMatcher.cosine normalises defensively too,
        // but the thresholds are calibrated on normalised vectors and the
        // max-over-photos comparison would otherwise be skewed.
        let norm = values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        for i in values.indices { values[i] /= norm }
        return values
    }

    // MARK: - Backends

    private static func featurePrintVector(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        // The crop is already exactly the region of interest, so no further
        // cropping - anything else would undo the alignment.
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch {
            NSLog("[Hermes] face: feature print failed - \(error.localizedDescription)")
            return nil
        }
        guard let print = request.results?.first as? VNFeaturePrintObservation
        else { return nil }

        let count = print.elementCount
        let data = print.data
        switch print.elementType {
        case .float:
            return data.withUnsafeBytes { buffer -> [Float] in
                let bound = buffer.bindMemory(to: Float.self)
                return Array(bound.prefix(count))
            }
        case .double:
            return data.withUnsafeBytes { buffer -> [Float] in
                let bound = buffer.bindMemory(to: Double.self)
                return bound.prefix(count).map { Float($0) }
            }
        default:
            NSLog("[Hermes] face: unexpected feature print element type")
            return nil
        }
    }

    private static func coreMLVector(
        _ image: CGImage, model: MLModel, inputName: String
    ) -> [Float]? {
        let edge = Int(FaceAlignment.outputSize)
        guard let array = pixelArray(from: image, edge: edge) else { return nil }
        do {
            let input = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: array)]
            )
            let output = try model.prediction(from: input)
            guard let name = output.featureNames.sorted().first,
                  let vector = output.featureValue(for: name)?.multiArrayValue
            else { return nil }
            return (0..<vector.count).map { Float(truncating: vector[$0]) }
        } catch {
            NSLog("[Hermes] face: inference failed - \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Pixels

    /// Draw the source image through the alignment transform into a square
    /// `edge`x`edge` context.
    static func render(
        _ image: CGImage, transform: CGAffineTransform, edge: Int
    ) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: edge, height: edge, bitsPerComponent: 8,
            bytesPerRow: edge * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // TWO flips, and both are load-bearing.
        //
        // The first puts user space in the app-wide top-left convention, so
        // `transform` (computed from top-left pixel coordinates) applies
        // directly. The second is because `CGContext.draw` places an image's
        // TOP row at the rect's maxY - right-side-up in a bottom-left space,
        // and therefore upside down in the space the first flip just created.
        //
        // Drop the second flip and every crop is vertically mirrored. That
        // does NOT look broken: both the roster and the live snap are
        // mirrored identically, so same-person scores stay high and the bug
        // hides. What gives it away is a tilted face, because the aligner
        // then rotates the wrong way and doubles the tilt instead of
        // removing it - which is exactly what `face-probe simulate`'s
        // "tilt 10 deg" control is for. It caught this.
        context.translateBy(x: 0, y: CGFloat(edge))
        context.scaleBy(x: 1, y: -1)
        context.concatenate(transform)
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: image.width, height: image.height))
        return context.makeImage()
    }

    /// RGB, NCHW, `(pixel - 127.5) / 128` - the contract recorded in
    /// tools/export-face.md. A silently mismatched normalisation produces
    /// embeddings that look perfectly well-formed and match nothing.
    static func pixelArray(from image: CGImage, edge: Int) -> MLMultiArray? {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              let array = try? MLMultiArray(
                  shape: [1, 3, NSNumber(value: edge), NSNumber(value: edge)],
                  dataType: .float32
              ) else { return nil }
        let bytesPerRow = image.bytesPerRow
        let pointer = array.dataPointer.bindMemory(
            to: Float.self, capacity: array.count
        )
        let plane = edge * edge
        for y in 0..<edge {
            for x in 0..<edge {
                let offset = y * bytesPerRow + x * 4
                let r = Float(bytes[offset]), g = Float(bytes[offset + 1])
                let b = Float(bytes[offset + 2])
                let index = y * edge + x
                pointer[index] = (r - 127.5) / 128.0
                pointer[plane + index] = (g - 127.5) / 128.0
                pointer[2 * plane + index] = (b - 127.5) / 128.0
            }
        }
        return array
    }
}
