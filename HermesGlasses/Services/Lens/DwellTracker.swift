//
// DwellTracker.swift
//
// Pure dwell logic for the Lens (Object Snap) view: decides which detected
// object sits under the center reticle and fires a snap event after the
// reticle has stayed on the same object for `dwellDuration`. Identity
// across frames is same label + IoU >= `iouThreshold` (boxes jitter frame
// to frame). After a snap the object is in cooldown - it cannot re-snap
// until the reticle leaves it.
//
// Deliberately UIKit- and Vision-free (CoreGraphics + Foundation only) so
// tests/dwell can compile it with plain swiftc.
//

import Foundation
import CoreGraphics

/// One detected object in a frame. `rect` is normalized [0,1] with
/// TOP-LEFT origin - Vision's bottom-left boxes are converted before
/// they get here.
struct Detection: Equatable {
    let label: String
    let confidence: Float
    let rect: CGRect
}

struct DwellUpdate: Equatable {
    /// 0...1 fraction of the dwell completed for the current target.
    let progress: Double
    /// The box currently under the reticle, nil if none.
    let target: Detection?
    /// Non-nil exactly once per completed dwell: crop this object now.
    let snap: Detection?
}

final class DwellTracker {
    private let dwellDuration: TimeInterval
    private let iouThreshold: Double
    private let reticle = CGPoint(x: 0.5, y: 0.5)

    private var currentTarget: Detection?
    private var dwellStart: TimeInterval?
    private var inCooldown = false

    init(dwellDuration: TimeInterval = 2.0, iouThreshold: Double = 0.3) {
        self.dwellDuration = dwellDuration
        self.iouThreshold = iouThreshold
    }

    func update(detections: [Detection], at time: TimeInterval) -> DwellUpdate {
        // Candidate = box containing the reticle whose center is nearest it.
        let candidate = detections
            .filter { $0.rect.contains(reticle) }
            .min { distanceToReticle($0) < distanceToReticle($1) }

        guard let candidate else {
            currentTarget = nil
            dwellStart = nil
            inCooldown = false
            return DwellUpdate(progress: 0, target: nil, snap: nil)
        }

        let sameObject = currentTarget.map {
            $0.label == candidate.label && iou($0.rect, candidate.rect) >= iouThreshold
        } ?? false

        guard sameObject else {
            currentTarget = candidate
            dwellStart = time
            inCooldown = false
            return DwellUpdate(progress: 0, target: candidate, snap: nil)
        }

        // Follow the box as it drifts so IoU is judged frame-to-frame,
        // not against where the object was 2 s ago.
        currentTarget = candidate

        if inCooldown {
            return DwellUpdate(progress: 1, target: candidate, snap: nil)
        }

        let elapsed = time - (dwellStart ?? time)
        if elapsed >= dwellDuration {
            inCooldown = true
            return DwellUpdate(progress: 1, target: candidate, snap: candidate)
        }
        return DwellUpdate(
            progress: elapsed / dwellDuration, target: candidate, snap: nil
        )
    }

    // MARK: - Geometry

    private func distanceToReticle(_ d: Detection) -> CGFloat {
        let c = CGPoint(x: d.rect.midX, y: d.rect.midY)
        return hypot(c.x - reticle.x, c.y - reticle.y)
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return Double(interArea / unionArea)
    }
}
