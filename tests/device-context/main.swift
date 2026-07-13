//
// Standalone tests for DeviceContextFormatter - run via swiftc
// (no XCTest target in this project).
//

import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}
func expectEqual(_ got: String, _ want: String, _ label: String) {
    if got == want { print("PASS \(label)") } else {
        failures += 1
        print("FAIL \(label)\n  got:  \(got)\n  want: \(want)")
    }
}

let tz = TimeZone(identifier: "Pacific/Auckland")!
var comps = DateComponents()
comps.year = 2026; comps.month = 7; comps.day = 11
comps.hour = 15; comps.minute = 42
var cal = Calendar(identifier: .gregorian)
cal.timeZone = tz
let date = cal.date(from: comps)!

// Full line, everything present
let full = DeviceContextInputs(
    date: date, timeZone: tz,
    areaName: "Grafton, Auckland, NZ",
    latitude: -36.86052, longitude: 174.76452,
    includeCoordinates: true,
    activity: "walking",
    connectivity: .wifi,
    batteryPercent: 25, batteryCharging: false,
    weatherTempC: 14.2, weatherCondition: "light rain"
)
expectEqual(
    DeviceContextFormatter.contextLine(full),
    "Sat 11 Jul 2026, 3:42 PM (Pacific/Auckland) · Grafton, Auckland, NZ (-36.8605, 174.7645) · walking · online (Wi-Fi) · iPhone battery 25%, not charging · 14°C light rain",
    "full context line"
)

// Area-only location (precise toggle off)
var areaOnly = full
areaOnly.includeCoordinates = false
expect(DeviceContextFormatter.contextLine(areaOnly)
    .contains("Grafton, Auckland, NZ · walking"), "coordinates omitted when not precise")

// No location at all → the location segment disappears entirely
var noLoc = full
noLoc.areaName = nil; noLoc.latitude = nil; noLoc.longitude = nil
expect(DeviceContextFormatter.contextLine(noLoc).components(separatedBy: " · ").count == 5,
       "location segment omitted entirely")
expect(!DeviceContextFormatter.contextLine(noLoc).contains("Grafton"),
       "no stale area name when location absent")

// Coordinates without area name (geocode pending) still shown when precise
var coordsOnly = full
coordsOnly.areaName = nil
expect(DeviceContextFormatter.contextLine(coordsOnly)
    .contains("(-36.8605, 174.7645)"), "bare coordinates when geocode pending")

// Offline + unknown battery + no weather → minimal line
let minimal = DeviceContextInputs(
    date: date, timeZone: tz,
    areaName: nil, latitude: nil, longitude: nil,
    includeCoordinates: true,
    activity: nil,
    connectivity: .offline,
    batteryPercent: nil, batteryCharging: nil,
    weatherTempC: nil, weatherCondition: nil
)
expectEqual(
    DeviceContextFormatter.contextLine(minimal),
    "Sat 11 Jul 2026, 3:42 PM (Pacific/Auckland) · offline",
    "minimal line: time + offline only"
)

// Unknown connectivity omitted
var unknownNet = minimal
unknownNet.connectivity = .unknown
expectEqual(
    DeviceContextFormatter.contextLine(unknownNet),
    "Sat 11 Jul 2026, 3:42 PM (Pacific/Auckland)",
    "unknown connectivity omitted"
)

// Charging state variants
var charging = full
charging.batteryCharging = true
expect(DeviceContextFormatter.contextLine(charging).contains("iPhone battery 25%, charging"),
       "charging state phrasing")
var chargeUnknown = full
chargeUnknown.batteryCharging = nil
expect(DeviceContextFormatter.contextLine(chargeUnknown).contains("iPhone battery 25% ·"),
       "battery without charge state")

// Weather: temperature without condition
var tempOnly = full
tempOnly.weatherCondition = nil
expect(DeviceContextFormatter.contextLine(tempOnly).hasSuffix("14°C"),
       "temperature shown without condition")

// areaName composition
expect(DeviceContextFormatter.areaName(subLocality: "Grafton", locality: "Auckland", isoCountryCode: "NZ")
       == "Grafton, Auckland, NZ", "area name full")
expect(DeviceContextFormatter.areaName(subLocality: nil, locality: "Auckland", isoCountryCode: "NZ")
       == "Auckland, NZ", "area name without suburb")
expect(DeviceContextFormatter.areaName(subLocality: "Auckland", locality: "Auckland", isoCountryCode: "NZ")
       == "Auckland, NZ", "duplicate suburb/city collapsed")
expect(DeviceContextFormatter.areaName(subLocality: nil, locality: nil, isoCountryCode: nil) == nil,
       "area name nil when nothing known")

// WMO weather codes
expect(DeviceContextFormatter.weatherPhrase(wmoCode: 0) == "clear sky", "WMO 0")
expect(DeviceContextFormatter.weatherPhrase(wmoCode: 61) == "light rain", "WMO 61")
expect(DeviceContextFormatter.weatherPhrase(wmoCode: 95) == "thunderstorm", "WMO 95")
expect(DeviceContextFormatter.weatherPhrase(wmoCode: 4242) == nil, "unknown WMO code → nil")

if failures > 0 { print("\(failures) test(s) FAILED"); exit(1) }
print("All device context tests passed")
