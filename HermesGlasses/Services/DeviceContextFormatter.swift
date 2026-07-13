//
// DeviceContextFormatter.swift
//
// Pure formatting for the per-query user-context line. Foundation-only
// so it unit-tests standalone (tests/device-context/) - all sensor code
// lives in DeviceContextProvider.
//

import Foundation

enum ContextConnectivity {
    case wifi, cellular, offline, unknown
}

struct DeviceContextInputs {
    var date: Date
    var timeZone: TimeZone
    var areaName: String?
    var latitude: Double?
    var longitude: Double?
    var includeCoordinates: Bool
    var activity: String?
    var connectivity: ContextConnectivity
    var batteryPercent: Int?
    var batteryCharging: Bool?
    var weatherTempC: Double?
    var weatherCondition: String?
}

enum DeviceContextFormatter {
    /// One compact line, segments joined by " · ", absent data omitted.
    static func contextLine(_ inputs: DeviceContextInputs) -> String {
        var segments: [String] = []

        // 1. Time - always present, locale-independent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = inputs.timeZone
        formatter.dateFormat = "EEE d MMM yyyy, h:mm a"
        segments.append(
            "\(formatter.string(from: inputs.date)) (\(inputs.timeZone.identifier))"
        )

        // 2. Location
        var location = inputs.areaName ?? ""
        if inputs.includeCoordinates,
           let lat = inputs.latitude, let lon = inputs.longitude {
            let coords = String(format: "(%.4f, %.4f)", lat, lon)
            location = location.isEmpty ? coords : "\(location) \(coords)"
        }
        if !location.isEmpty {
            segments.append(location)
        }

        // 3. Motion
        if let activity = inputs.activity {
            segments.append(activity)
        }

        // 4. Connectivity
        switch inputs.connectivity {
        case .wifi: segments.append("online (Wi-Fi)")
        case .cellular: segments.append("online (cellular)")
        case .offline: segments.append("offline")
        case .unknown: break
        }

        // 5. Battery
        if let percent = inputs.batteryPercent {
            if let charging = inputs.batteryCharging {
                segments.append(
                    "iPhone battery \(percent)%, \(charging ? "charging" : "not charging")"
                )
            } else {
                segments.append("iPhone battery \(percent)%")
            }
        }

        // 6. Weather
        if let temp = inputs.weatherTempC {
            let rounded = Int(temp.rounded())
            if let condition = inputs.weatherCondition {
                segments.append("\(rounded)°C \(condition)")
            } else {
                segments.append("\(rounded)°C")
            }
        }

        return segments.joined(separator: " · ")
    }

    /// "Grafton, Auckland, NZ" from placemark parts; duplicates collapsed.
    static func areaName(
        subLocality: String?, locality: String?, isoCountryCode: String?
    ) -> String? {
        var parts: [String] = []
        for candidate in [subLocality, locality, isoCountryCode] {
            if let candidate, !candidate.isEmpty, !parts.contains(candidate) {
                parts.append(candidate)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Short phrase for an Open-Meteo (WMO) weather code; nil = unknown.
    static func weatherPhrase(wmoCode: Int) -> String? {
        switch wmoCode {
        case 0: return "clear sky"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rain"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71: return "light snow"
        case 73: return "snow"
        case 75: return "heavy snow"
        case 77: return "snow grains"
        case 80, 81: return "rain showers"
        case 82: return "heavy rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"
        default: return nil
        }
    }
}
