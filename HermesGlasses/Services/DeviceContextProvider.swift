//
// DeviceContextProvider.swift
//
// Gathers the user's situation (location, motion, connectivity, battery,
// weather) behind caches so contextLine() answers synchronously. All
// sources are best-effort: anything unavailable is simply omitted from
// the line. Formatting lives in DeviceContextFormatter.
//

import CoreLocation
import CoreMotion
import Foundation
import Network
import UIKit
import os

@MainActor
final class DeviceContextProvider: NSObject {
    static let enabledKey = "context_enabled"
    static let preciseKey = "context_precise_location"

    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "context"
    )

    var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true
    }

    private var includeCoordinates: Bool {
        (UserDefaults.standard.object(forKey: Self.preciseKey) as? Bool) ?? true
    }

    // Sensors
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let pathMonitor = NWPathMonitor()
    private let activityManager = CMMotionActivityManager()

    // Caches
    private var lastFix: CLLocation?
    private var lastFixAt: Date?
    private var fixRequestInFlight = false
    private var geocodedAt: CLLocation?
    private var areaName: String?
    private var connectivity: ContextConnectivity = .unknown
    private var activityPhrase: String?
    private var weatherTempC: Double?
    private var weatherCondition: String?
    private var weatherAt: Date?
    private var weatherFetchInFlight = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Network monitor runs for the provider's lifetime (NWPathMonitor
        // cannot be restarted after cancel)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let status: ContextConnectivity
            if path.status != .satisfied {
                status = .offline
            } else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                status = .wifi
            } else if path.usesInterfaceType(.cellular) {
                status = .cellular
            } else {
                status = .wifi
            }
            Task { @MainActor [weak self] in
                self?.connectivity = status
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "context.path"))
    }

    // MARK: - Lifecycle (session-scoped)

    func start() {
        guard isEnabled else { return }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        requestFixIfStale()

        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let self, let activity else { return }
                if activity.automotive { self.activityPhrase = "driving" }
                else if activity.cycling { self.activityPhrase = "cycling" }
                else if activity.running { self.activityPhrase = "running" }
                else if activity.walking { self.activityPhrase = "walking" }
                else if activity.stationary { self.activityPhrase = "stationary" }
                else { self.activityPhrase = nil }
            }
        }
    }

    func stop() {
        activityManager.stopActivityUpdates()
        activityPhrase = nil
        geocoder.cancelGeocode()
    }

    // MARK: - The line

    /// Synchronous: reads caches only; kicks off background refreshes for
    /// stale pieces so the NEXT query is fresher. Nil when disabled.
    func contextLine() -> String? {
        guard isEnabled else { return nil }
        requestFixIfStale()
        refreshWeatherIfStale()

        var batteryPercent: Int?
        var batteryCharging: Bool?
        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            batteryPercent = Int((level * 100).rounded())
            switch UIDevice.current.batteryState {
            case .charging, .full: batteryCharging = true
            case .unplugged: batteryCharging = false
            case .unknown: batteryCharging = nil
            @unknown default: batteryCharging = nil
            }
        }

        // Weather older than 60 min is stale enough to mislead - omit
        let weatherFresh = weatherAt.map { Date().timeIntervalSince($0) < 3600 } ?? false

        // Same for the location fix: after a relocation the old fix would
        // be asserted confidently - better to say nothing until GPS lands
        let fixFresh = lastFixAt.map { Date().timeIntervalSince($0) < 3600 } ?? false

        let inputs = DeviceContextInputs(
            date: Date(),
            timeZone: TimeZone.current,
            areaName: fixFresh ? areaName : nil,
            latitude: fixFresh ? lastFix?.coordinate.latitude : nil,
            longitude: fixFresh ? lastFix?.coordinate.longitude : nil,
            includeCoordinates: includeCoordinates,
            activity: activityPhrase,
            connectivity: connectivity,
            batteryPercent: batteryPercent,
            batteryCharging: batteryCharging,
            weatherTempC: weatherFresh ? weatherTempC : nil,
            weatherCondition: weatherFresh ? weatherCondition : nil
        )
        return DeviceContextFormatter.contextLine(inputs)
    }

    // MARK: - Location

    private func requestFixIfStale() {
        let status = locationManager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        if let lastFixAt, Date().timeIntervalSince(lastFixAt) < 60 { return }
        guard !fixRequestInFlight else { return }
        fixRequestInFlight = true
        locationManager.requestLocation()
    }

    private func reverseGeocodeIfNeeded(_ fix: CLLocation) {
        if let geocodedAt, fix.distance(from: geocodedAt) < 200, areaName != nil {
            return
        }
        guard !geocoder.isGeocoding else { return }
        geocoder.reverseGeocodeLocation(fix) { [weak self] placemarks, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let placemark = placemarks?.first {
                    self.areaName = DeviceContextFormatter.areaName(
                        subLocality: placemark.subLocality,
                        locality: placemark.locality,
                        isoCountryCode: placemark.isoCountryCode
                    )
                    self.geocodedAt = fix
                } else if let error {
                    self.logger.info("Geocode failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Weather (Open-Meteo, no key)

    private func refreshWeatherIfStale() {
        guard let fix = lastFix, connectivity != .offline,
              let lastFixAt, Date().timeIntervalSince(lastFixAt) < 3600 else { return }
        if let weatherAt, Date().timeIntervalSince(weatherAt) < 900 { return }
        guard !weatherFetchInFlight else { return }
        weatherFetchInFlight = true

        // %.5f: raw Double interpolation renders tiny values as "3e-05",
        // which the API may misparse
        let lat = String(format: "%.5f", fix.coordinate.latitude)
        let lon = String(format: "%.5f", fix.coordinate.longitude)
        let url = URL(string:
            "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current_weather=true"
        )!
        Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.weatherFetchInFlight = false } }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                let (data, _) = try await URLSession.shared.data(for: request)
                guard
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let current = json["current_weather"] as? [String: Any],
                    let temperature = current["temperature"] as? Double
                else { return }
                let code = current["weathercode"] as? Int
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.weatherTempC = temperature
                    self.weatherCondition = code.flatMap {
                        DeviceContextFormatter.weatherPhrase(wmoCode: $0)
                    }
                    self.weatherAt = Date()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.logger.info("Weather fetch failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension DeviceContextProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let fix = locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastFix = fix
            self.lastFixAt = Date()
            self.fixRequestInFlight = false
            self.reverseGeocodeIfNeeded(fix)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fixRequestInFlight = false
            self.logger.info("Location fix failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.requestFixIfStale()
        }
    }
}
