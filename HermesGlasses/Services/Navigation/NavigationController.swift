//
// NavigationController.swift
//
// Owns one active navigation session. Resolves the destination with MapKit,
// computes a route + turn steps, tracks the user with CoreLocation, and pushes
// a self-recentering Mapbox map to the lens as they move. Best-effort: any
// failure ends cleanly with a spoken notice.
//

import CoreLocation
import Foundation
import MapKit

@MainActor
final class NavigationController: NSObject {
    var onShow: ((_ mapURL: String?, _ title: String, _ step: String, _ eta: String) -> Void)?
    var onSpeak: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var onEnd: (() -> Void)?
    var onDebug: ((String) -> Void)?

    private(set) var isActive = false

    private let manager = CLLocationManager()
    private var route: MKRoute?
    private var destinationName = ""
    private var destinationCoord: MapCoordinate?
    private var routeCoords: [MapCoordinate] = []
    private var currentStepIndex = 0

    // Refresh throttle (Global Constraints): >= 15 m moved AND >= 4 s elapsed.
    private var lastSentAt: Date?
    private var lastSentCoord: CLLocation?
    private static let minMoveMeters: CLLocationDistance = 15
    private static let minInterval: TimeInterval = 4
    private static let arrivalMeters: CLLocationDistance = 25
    private static let mapZoom: Double = 16

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start(destination: String, mode: TransportMode) {
        stop()  // clear any prior session
        destinationName = destination
        isActive = true
        manager.requestWhenInUseAuthorization()

        Task { @MainActor in
            do {
                let placemark = try await resolve(destination)
                let route = try await route(to: placemark, mode: mode)
                self.route = route
                self.routeCoords = Self.coords(of: route.polyline)
                self.destinationCoord = placemark.location.map {
                    MapCoordinate(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude)
                }
                self.currentStepIndex = 0
                onSpeak?("Navigating to \(destinationName), \(NavigationFormat.eta(seconds: route.expectedTravelTime)).")
                manager.startUpdatingLocation()
            } catch {
                onDebug?("Navigation failed: \(error.localizedDescription)")
                onNotice?("I couldn't find a route to \(destinationName).")
                end()
            }
        }
    }

    func stop() {
        guard isActive else { return }
        end()
    }

    private func end() {
        manager.stopUpdatingLocation()
        isActive = false
        route = nil
        routeCoords = []
        destinationCoord = nil
        lastSentAt = nil
        lastSentCoord = nil
        onEnd?()
    }

    // MARK: - MapKit

    private func resolve(_ query: String) async throws -> MKPlacemark {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let here = manager.location {
            request.region = MKCoordinateRegion(
                center: here.coordinate,
                latitudinalMeters: 50_000, longitudinalMeters: 50_000
            )
        }
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw NavError.notFound
        }
        return MKPlacemark(coordinate: item.placemark.coordinate)
    }

    private func route(to placemark: MKPlacemark, mode: TransportMode) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = MKMapItem(placemark: placemark)
        request.transportType = (mode == .driving) ? .automobile : .walking
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw NavError.noRoute }
        return route
    }

    private static func coords(of polyline: MKPolyline) -> [MapCoordinate] {
        var pts = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount
        )
        polyline.getCoordinates(&pts, range: NSRange(location: 0, length: polyline.pointCount))
        return pts.map { MapCoordinate(lat: $0.latitude, lon: $0.longitude) }
    }

    // MARK: - Per-update rendering

    private func handle(location: CLLocation) {
        guard isActive, let route else { return }

        // Arrival check.
        if let dest = destinationCoord {
            let destLoc = CLLocation(latitude: dest.lat, longitude: dest.lon)
            if location.distance(from: destLoc) <= Self.arrivalMeters {
                onSpeak?("You've arrived at \(destinationName).")
                onShow?(nil, destinationName, "Arrived", "0 min")
                end()
                return
            }
        }

        // Throttle re-sends against the Bluetooth budget.
        let now = Date()
        if let lastAt = lastSentAt, let lastCoord = lastSentCoord,
           now.timeIntervalSince(lastAt) < Self.minInterval,
           location.distance(from: lastCoord) < Self.minMoveMeters {
            return
        }
        lastSentAt = now
        lastSentCoord = location

        advanceStep(near: location)
        let step = route.steps.indices.contains(currentStepIndex)
            ? route.steps[currentStepIndex] : nil
        let instruction = step?.instructions.isEmpty == false
            ? step!.instructions : "Continue"
        let stepDistance = step.map { NavigationFormat.distance(meters: $0.distance) } ?? ""
        let stepText = stepDistance.isEmpty ? instruction : "\(instruction) - \(stepDistance)"

        let user = MapCoordinate(lat: location.coordinate.latitude,
                                 lon: location.coordinate.longitude)
        let mapURL = MapCredentials.loadToken().map { token in
            MapboxStaticMap.url(
                token: token,
                center: user,
                zoom: Self.mapZoom,
                size: 600,
                user: user,
                destination: destinationCoord,
                route: routeCoords
            )
        }
        if mapURL == nil, lastSentAt == now {
            onNotice?("Add a Mapbox token in Settings to see the map.")
        }
        onShow?(mapURL, destinationName, stepText,
                NavigationFormat.eta(seconds: route.expectedTravelTime))
    }

    /// Advance to the nearest not-yet-passed step by distance to its end point.
    private func advanceStep(near location: CLLocation) {
        guard let route else { return }
        while currentStepIndex < route.steps.count - 1 {
            let step = route.steps[currentStepIndex]
            guard step.polyline.pointCount > 0 else { currentStepIndex += 1; continue }
            let ends = Self.coords(of: step.polyline)
            guard let last = ends.last else { break }
            let endLoc = CLLocation(latitude: last.lat, longitude: last.lon)
            if location.distance(from: endLoc) <= Self.arrivalMeters {
                currentStepIndex += 1
            } else {
                break
            }
        }
    }

    private enum NavError: LocalizedError {
        case notFound, noRoute
        var errorDescription: String? {
            switch self {
            case .notFound: return "Place not found"
            case .noRoute: return "No route found"
            }
        }
    }
}

extension NavigationController: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let latest = locations.last else { return }
        Task { @MainActor in self.handle(location: latest) }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didFailWithError error: Error
    ) {
        Task { @MainActor in self.onDebug?("Location error: \(error.localizedDescription)") }
    }
}
