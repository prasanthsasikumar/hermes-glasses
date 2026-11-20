//
// FingerPointer.swift
//
// Turns the joints of one hand into "this is what the finger points at".
// Two questions, both pure:
//
//  - Is this hand POINTING? Only an extended index finger with the middle
//    finger not extended counts. A hand that is merely in view - an open
//    palm, a fist, two fingers up - must never be a point, because a point
//    held still sends a paid request to the AI with nobody tapping.
//  - WHAT does it point at? A camera sees the finger flat, so this is an
//    estimate: the spot just past the fingertip along the finger.
//
// Coordinates are normalised, TOP-LEFT origin - the same space as the
// object detector's boxes. Distances are fractions of the frame. Every
// constant is PROVISIONAL: none has been tuned on a real hand.
//
// Foundation only; tested in tests/translate/.
//

import Foundation
import CoreGraphics

struct HandJoint: Equatable {
    let point: CGPoint
    let confidence: Double
}

/// The joints the pointing test reads. Nil = not found in the frame.
struct HandJoints: Equatable {
    var indexMCP: HandJoint?
    var indexPIP: HandJoint?
    var indexDIP: HandJoint?
    var indexTip: HandJoint?
    var middleMCP: HandJoint?
    var middlePIP: HandJoint?
    var middleDIP: HandJoint?
    var middleTip: HandJoint?
}

struct Pointing: Equatable {
    let tip: CGPoint
    /// Unit vector along the finger, in normalised frame space.
    let direction: CGVector

    /// Just past the fingertip: where the pointed-at thing is taken to be.
    var probe: CGPoint { point(at: FingerPointer.probeDistance) }

    func point(at distance: CGFloat) -> CGPoint {
        CGPoint(x: tip.x + direction.dx * distance, y: tip.y + direction.dy * distance)
    }
}

enum PointTarget: Equatable {
    /// Index into the boxes that were passed in.
    case box(Int)
    /// Nothing known there - this part of the frame goes to the AI.
    case region(CGRect)
}

enum FingerPointer {
    static let minJointConfidence = 0.5
    /// End-to-end length over joint-to-joint length; 1 is perfectly straight.
    static let straightness: CGFloat = 0.9
    /// The middle finger is believed at a lower confidence than the index:
    /// it only ever argues AGAINST a point.
    static let middleSeenConfidence = 0.3
    /// A middle finger reaching less than this share of the index is
    /// folded, not extended.
    static let middleLengthShare: CGFloat = 0.6
    /// Shorter than this the "finger" is noise.
    static let minFingerLength: CGFloat = 0.04
    static let probeDistance: CGFloat = 0.06
    static let reach: CGFloat = 0.35
    static let regionSide: CGFloat = 0.4
    static let regionOffset: CGFloat = 0.15
    /// A stall's table is one huge box; pointing at a thing ON it must not
    /// answer "table".
    static let maxBoxArea: CGFloat = 0.35

    /// `aspect` is frame width / height: straightness is judged in real
    /// proportions, not in the squashed normalised space.
    static func pointing(from joints: HandJoints, aspect: CGFloat) -> Pointing? {
        guard let mcp = sure(joints.indexMCP), let pip = sure(joints.indexPIP),
              let dip = sure(joints.indexDIP), let tip = sure(joints.indexTip)
        else { return nil }

        let index = [mcp, pip, dip, tip]
        let indexLength = span(index, aspect)
        guard indexLength >= minFingerLength, isStraight(index, aspect) else { return nil }

        // The veto is deliberately loose: knuckle-to-tip reach alone, read
        // at a lower confidence. A relaxed open hand, or one with an
        // unsure joint, must not pass as a point. Only a middle fingertip
        // that is folded back or not visible at all lets the point stand.
        if let mMCP = seen(joints.middleMCP), let mTip = seen(joints.middleTip),
           distance(mMCP, mTip, aspect) >= indexLength * middleLengthShare {
            return nil
        }

        let dx = tip.x - pip.x, dy = tip.y - pip.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        return Pointing(tip: tip, direction: CGVector(dx: dx / length, dy: dy / length))
    }

    static func target(for pointing: Pointing, boxes: [CGRect]) -> PointTarget {
        let candidates = boxes.enumerated().filter {
            $0.element.width * $0.element.height <= maxBoxArea
        }

        let probe = pointing.probe
        if let inside = candidates
            .filter({ $0.element.contains(probe) })
            .min(by: { area($0.element) < area($1.element) }) {
            return .box(inside.offset)
        }

        let entered = candidates.compactMap { candidate -> (Int, CGFloat)? in
            guard let t = entry(of: pointing, into: candidate.element), t <= reach
            else { return nil }
            return (candidate.offset, t)
        }
        if let first = entered.min(by: { $0.1 < $1.1 }) {
            return .box(first.0)
        }
        return .region(region(for: pointing))
    }

    /// What the AI is shown when no known box is pointed at. It includes
    /// the fingertip on purpose, so the AI can tell which thing is meant.
    static func region(for pointing: Pointing) -> CGRect {
        let centre = pointing.point(at: regionOffset)
        let half = regionSide / 2
        let x = min(max(centre.x - half, 0), 1 - regionSide)
        let y = min(max(centre.y - half, 0), 1 - regionSide)
        return CGRect(x: x, y: y, width: regionSide, height: regionSide)
    }

    // MARK: - Private

    private static func sure(_ joint: HandJoint?) -> CGPoint? {
        guard let joint, joint.confidence >= minJointConfidence else { return nil }
        return joint.point
    }

    private static func seen(_ joint: HandJoint?) -> CGPoint? {
        guard let joint, joint.confidence >= middleSeenConfidence else { return nil }
        return joint.point
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint, _ aspect: CGFloat) -> CGFloat {
        hypot((a.x - b.x) * aspect, a.y - b.y)
    }

    /// Knuckle to tip, straight line.
    private static func span(_ joints: [CGPoint], _ aspect: CGFloat) -> CGFloat {
        distance(joints[0], joints[joints.count - 1], aspect)
    }

    private static func isStraight(_ joints: [CGPoint], _ aspect: CGFloat) -> Bool {
        var path: CGFloat = 0
        for i in 1..<joints.count { path += distance(joints[i - 1], joints[i], aspect) }
        guard path > 0 else { return false }
        return span(joints, aspect) / path >= straightness
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    /// Distance along the ray at which it enters `rect`; nil if it misses.
    private static func entry(of pointing: Pointing, into rect: CGRect) -> CGFloat? {
        var tMin: CGFloat = 0
        var tMax = CGFloat.greatestFiniteMagnitude
        let axes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (pointing.tip.x, pointing.direction.dx, rect.minX, rect.maxX),
            (pointing.tip.y, pointing.direction.dy, rect.minY, rect.maxY),
        ]
        for (origin, direction, low, high) in axes {
            if abs(direction) < 1e-9 {
                if origin < low || origin > high { return nil }
                continue
            }
            let a = (low - origin) / direction
            let b = (high - origin) / direction
            tMin = max(tMin, min(a, b))
            tMax = min(tMax, max(a, b))
            if tMin > tMax { return nil }
        }
        return tMin
    }
}
