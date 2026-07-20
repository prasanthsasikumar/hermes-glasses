//
// NavigationTypes.swift
//
// Shared, Foundation-only value types for the navigation + definition
// features so the pure units unit-test standalone (tests/) without MapKit.
//

import Foundation

enum TransportMode: Equatable {
    case walking
    case driving
}

/// A geographic point. Kept Foundation-only (no CoreLocation) so URL
/// builders and the polyline encoder unit-test without the SDK.
struct MapCoordinate: Equatable {
    let lat: Double
    let lon: Double
}

/// What a finalized utterance asks for. `.none` means the normal reply path.
enum HermesIntent: Equatable {
    case navigate(destination: String, mode: TransportMode)
    case stopNavigation
    case define(subject: String)
    case none
}

/// Pure human-readable formatting for the lens.
enum NavigationFormat {
    /// Whole minutes, always at least 1.
    static func eta(seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return "\(minutes) min"
    }

    /// Metric distance: metres under 1 km, one-decimal km above.
    static func distance(meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters.rounded())) m"
        }
        let km = (meters / 100).rounded() / 10
        return "\(km) km"
    }
}
