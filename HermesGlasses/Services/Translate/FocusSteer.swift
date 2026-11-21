//
// FocusSteer.swift
//
// Decides when the phone camera's focus should move to what a finger
// points at. Left alone, continuous autofocus measures the centre of the
// frame; a hand held up in front of the thing it points at passes through
// that centre, and the lens hunts between the near hand and the far
// object. Aiming focus past the fingertip takes the hand out of the
// measurement.
//
// It answers with a CHANGE only when one is needed - every focus change
// is itself a visible refocus, so a trembling finger must not cause one.
//
// Foundation only; tested in tests/translate/.
//

import Foundation
import CoreGraphics

struct FocusSteer {
    enum Change: Equatable {
        /// Focus here: normalised, TOP-LEFT origin, portrait frame.
        case point(CGPoint)
        /// Back to the camera's default.
        case centre
    }

    /// PROVISIONAL: the probe must move this far before focus follows.
    static let moveThreshold: CGFloat = 0.1

    private var focused: CGPoint?

    mutating func update(probe: CGPoint?) -> Change? {
        guard let probe else { return release() }
        if let focused,
           hypot(probe.x - focused.x, probe.y - focused.y) < Self.moveThreshold {
            return nil
        }
        focused = probe
        return .point(probe)
    }

    /// The finger is gone or the screen is closing.
    mutating func release() -> Change? {
        guard focused != nil else { return nil }
        focused = nil
        return .centre
    }

    /// AVCaptureDevice takes points in the sensor's own landscape space;
    /// the phone delivers frames rotated 90 degrees to portrait.
    static func devicePoint(forPortrait point: CGPoint) -> CGPoint {
        let x = min(max(point.x, 0), 1)
        let y = min(max(point.y, 0), 1)
        return CGPoint(x: y, y: 1 - x)
    }
}
