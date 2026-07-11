# Device Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attach a compact snapshot of the user's situation (local time, location, motion, connectivity, phone battery, weather) to every query so Claude Direct and both bridges answer with real personal context.

**Architecture:** A pure `DeviceContextFormatter` (Foundation-only, standalone-tested) turns typed inputs into one context line; a `DeviceContextProvider` (@MainActor) gathers inputs from CoreLocation / NWPathMonitor / UIDevice / CoreMotion / Open-Meteo behind caches so `contextLine()` returns synchronously. The view model injects the line per query: an uncached second system block for Claude Direct, a `[Context: …]` text prefix for bridge mode (both bridges unmodified).

**Tech Stack:** Swift, CoreLocation, Network (NWPathMonitor), CoreMotion, UIKit battery API, Open-Meteo REST (no key), standalone swiftc tests.

**Spec:** `docs/superpowers/specs/2026-07-11-device-context-design.md`

## Global Constraints

- Build from the **repo root**: `xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build`. Ignore SourceKit "No such module"/"unavailable in macOS" diagnostics — xcodebuild is authoritative.
- Context is best-effort and non-blocking: **no context source may delay, fail, or alter a query** beyond the added line; `contextLine()` is synchronous (reads caches, kicks off background refreshes).
- Settings keys, exact: `context_enabled` (Bool, default **true**), `context_precise_location` (Bool, default **true**).
- Segment separator is `" · "` (space, middle dot, space). Coordinates to 4 decimal places. Weather cache: refresh when older than **15 min**; omit from the line when older than **60 min**. Location fix freshness cache: **60 s**. Re-geocode when moved > **200 m**.
- `DeviceContextFormatter.swift` must import Foundation only (standalone swiftc-testable). `DeviceContextProvider.swift` holds all SDK/sensor code.
- Conversation history and `lastTranscript` keep the RAW user text — context lines never persist or accumulate.
- The Claude Direct persona system block keeps `cache_control: ephemeral` and stays FIRST; the context block is appended after it, uncached.
- Repo is public: no API keys or tokens in any commit (Open-Meteo needs none).

---

### Task 1: `DeviceContextFormatter` with standalone tests

**Files:**
- Create: `HermesGlasses/Services/DeviceContextFormatter.swift`
- Create: `tests/device-context/main.swift`

**Interfaces:**
- Consumes: nothing (Foundation only).
- Produces (used by Tasks 2–3):
  - `enum ContextConnectivity { case wifi, cellular, offline, unknown }`
  - `struct DeviceContextInputs` (all fields shown below, memberwise init)
  - `DeviceContextFormatter.contextLine(_ inputs: DeviceContextInputs) -> String`
  - `DeviceContextFormatter.areaName(subLocality: String?, locality: String?, isoCountryCode: String?) -> String?`
  - `DeviceContextFormatter.weatherPhrase(wmoCode: Int) -> String?`

- [ ] **Step 1: Write the failing tests**

Create `tests/device-context/main.swift`:

```swift
//
// Standalone tests for DeviceContextFormatter — run via swiftc
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
    "Fri 11 Jul 2026, 3:42 PM (Pacific/Auckland) · Grafton, Auckland, NZ (-36.8605, 174.7645) · walking · online (Wi-Fi) · iPhone battery 25%, not charging · 14°C light rain",
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
    "Fri 11 Jul 2026, 3:42 PM (Pacific/Auckland) · offline",
    "minimal line: time + offline only"
)

// Unknown connectivity omitted
var unknownNet = minimal
unknownNet.connectivity = .unknown
expectEqual(
    DeviceContextFormatter.contextLine(unknownNet),
    "Fri 11 Jul 2026, 3:42 PM (Pacific/Auckland)",
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from repo root):
```bash
xcrun swiftc HermesGlasses/Services/DeviceContextFormatter.swift tests/device-context/main.swift -o /tmp/device-context-tests && /tmp/device-context-tests
```
Expected: FAIL to compile — `DeviceContextFormatter.swift` does not exist (`no such file`).

- [ ] **Step 3: Write the implementation**

Create `HermesGlasses/Services/DeviceContextFormatter.swift`:

```swift
//
// DeviceContextFormatter.swift
//
// Pure formatting for the per-query user-context line. Foundation-only
// so it unit-tests standalone (tests/device-context/) — all sensor code
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

        // 1. Time — always present, locale-independent
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcrun swiftc HermesGlasses/Services/DeviceContextFormatter.swift tests/device-context/main.swift -o /tmp/device-context-tests && /tmp/device-context-tests
```
Expected: all `PASS` lines, final line `All device context tests passed`, exit 0. (The file is not in the Xcode project yet — Task 2 registers it; only the standalone compile matters here.)

- [ ] **Step 5: Commit**

```bash
git add HermesGlasses/Services/DeviceContextFormatter.swift tests/device-context/main.swift
git commit -m "feat: device context formatter (time/location/motion/net/battery/weather line) with standalone tests"
```

---

### Task 2: `DeviceContextProvider` + project registration + Info.plist keys

**Files:**
- Modify: `HermesGlasses.xcodeproj/project.pbxproj`
- Modify: `HermesGlasses/Info.plist`
- Create: `HermesGlasses/Services/DeviceContextProvider.swift`

**Interfaces:**
- Consumes: `DeviceContextFormatter`, `DeviceContextInputs`, `ContextConnectivity` (Task 1).
- Produces (used by Task 3):
  - `@MainActor final class DeviceContextProvider: NSObject` with:
    - `static let enabledKey = "context_enabled"`, `static let preciseKey = "context_precise_location"`
    - `var isEnabled: Bool` (reads UserDefaults, default true)
    - `func start()` — begins location/motion updates, requests when-in-use permission if undetermined
    - `func stop()` — stops location/motion updates
    - `func contextLine() -> String?` — synchronous; nil when disabled

- [ ] **Step 1: Register the new source files in the pbxproj**

Run from the repo root (IDs continue the existing sequence; anchors are the HermesDisplayManager entries):

```bash
python3 - <<'EOF'
path = "HermesGlasses.xcodeproj/project.pbxproj"
s = open(path).read()

def sub(old, new):
    global s
    assert old in s, f"anchor not found: {old[:60]}..."
    assert new not in s, "already applied"
    s = s.replace(old, new, 1)

sub(
  "\t\tAAAA00000000000000000015 /* HermesDisplayManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000118 /* HermesDisplayManager.swift */; };\n",
  "\t\tAAAA00000000000000000015 /* HermesDisplayManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000118 /* HermesDisplayManager.swift */; };\n"
  "\t\tAAAA00000000000000000016 /* DeviceContextFormatter.swift in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000119 /* DeviceContextFormatter.swift */; };\n"
  "\t\tAAAA00000000000000000017 /* DeviceContextProvider.swift in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000120 /* DeviceContextProvider.swift */; };\n",
)

sub(
  "\t\tAAAA00000000000000000118 /* HermesDisplayManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HermesDisplayManager.swift; sourceTree = \"<group>\"; };\n",
  "\t\tAAAA00000000000000000118 /* HermesDisplayManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HermesDisplayManager.swift; sourceTree = \"<group>\"; };\n"
  "\t\tAAAA00000000000000000119 /* DeviceContextFormatter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeviceContextFormatter.swift; sourceTree = \"<group>\"; };\n"
  "\t\tAAAA00000000000000000120 /* DeviceContextProvider.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeviceContextProvider.swift; sourceTree = \"<group>\"; };\n",
)

sub(
  "\t\t\t\tAAAA00000000000000000118 /* HermesDisplayManager.swift */,\n",
  "\t\t\t\tAAAA00000000000000000118 /* HermesDisplayManager.swift */,\n"
  "\t\t\t\tAAAA00000000000000000119 /* DeviceContextFormatter.swift */,\n"
  "\t\t\t\tAAAA00000000000000000120 /* DeviceContextProvider.swift */,\n",
)

sub(
  "\t\t\t\tAAAA00000000000000000015 /* HermesDisplayManager.swift in Sources */,\n",
  "\t\t\t\tAAAA00000000000000000015 /* HermesDisplayManager.swift in Sources */,\n"
  "\t\t\t\tAAAA00000000000000000016 /* DeviceContextFormatter.swift in Sources */,\n"
  "\t\t\t\tAAAA00000000000000000017 /* DeviceContextProvider.swift in Sources */,\n",
)

open(path, "w").write(s)
print("pbxproj updated")
EOF
```
Expected output: `pbxproj updated`

- [ ] **Step 2: Add the two usage strings to Info.plist**

In `HermesGlasses/Info.plist`, directly after the `NSSpeechRecognitionUsageDescription` string entry, insert:

```xml
	<!-- Personal context attached to queries (time/place/weather) -->
	<key>NSLocationWhenInUseUsageDescription</key>
	<string>Hermes Glasses shares your approximate location with the assistant so it can answer questions about where you are, nearby places, and the weather.</string>
	<key>NSMotionUsageDescription</key>
	<string>Hermes Glasses tells the assistant whether you're walking, driving, or still, so answers fit what you're doing.</string>
```

- [ ] **Step 3: Create the provider**

Create `HermesGlasses/Services/DeviceContextProvider.swift`:

```swift
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
        subsystem: "com.flowsxr.hermes-glasses", category: "context"
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

        // Weather older than 60 min is stale enough to mislead — omit
        let weatherFresh = weatherAt.map { Date().timeIntervalSince($0) < 3600 } ?? false

        let inputs = DeviceContextInputs(
            date: Date(),
            timeZone: TimeZone.current,
            areaName: areaName,
            latitude: lastFix?.coordinate.latitude,
            longitude: lastFix?.coordinate.longitude,
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
        guard let fix = lastFix, connectivity != .offline else { return }
        if let weatherAt, Date().timeIntervalSince(weatherAt) < 900 { return }
        guard !weatherFetchInFlight else { return }
        weatherFetchInFlight = true

        let lat = fix.coordinate.latitude
        let lon = fix.coordinate.longitude
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
```

- [ ] **Step 4: Build**

Run (from repo root):
```bash
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. Known wrinkle: if the compiler rejects the `nonisolated` delegate methods calling into MainActor (Swift concurrency strictness varies), the delegate extension pattern above (nonisolated methods that immediately hop via `Task { @MainActor ... }`) is the standard fix — adjust only if the build demands it and note the change.

- [ ] **Step 5: Commit**

```bash
git add HermesGlasses.xcodeproj/project.pbxproj HermesGlasses/Info.plist HermesGlasses/Services/DeviceContextProvider.swift
git commit -m "feat: device context provider (location/motion/network/battery/weather caches)"
```

---

### Task 3: Inject context into both query paths

**Files:**
- Modify: `HermesGlasses/Services/ClaudeDirectClient.swift`
- Modify: `HermesGlasses/ViewModels/HermesSessionViewModel.swift`

**Interfaces:**
- Consumes: `DeviceContextProvider` (Task 2).
- Produces (used by Task 4): `var contextEnabled: Bool`, `var contextPreciseLocation: Bool`, `var contextPreview: String?` on `HermesSessionViewModel`.

- [ ] **Step 1: Context parameter on `ClaudeDirectClient.ask`**

In `HermesGlasses/Services/ClaudeDirectClient.swift`, change the `ask` signature and the request body. Old:

```swift
    func ask(_ text: String, photoJPEG: Data?) async throws -> String {
```

New:

```swift
    func ask(_ text: String, photoJPEG: Data?, contextLine: String? = nil) async throws -> String {
```

Old body fragment:

```swift
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 1024,
            "system": [[
                "type": "text",
                "text": Self.systemPrompt,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": messages,
        ]
```

New:

```swift
        // Persona block stays FIRST and cached (stable prefix); the
        // context block is per-query and never cached.
        var system: [[String: Any]] = [[
            "type": "text",
            "text": Self.systemPrompt,
            "cache_control": ["type": "ephemeral"],
        ]]
        if let contextLine {
            system.append([
                "type": "text",
                "text": "Current user context: \(contextLine)",
            ])
        }
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 1024,
            "system": system,
            "messages": messages,
        ]
```

- [ ] **Step 2: View model — settings vars, provider, lifecycle**

In `HermesGlasses/ViewModels/HermesSessionViewModel.swift`:

a) In the published-state section, directly after the `displaySilentMode` property's closing `}`, add:

```swift
    /// Attach time/location/status context to every query
    var contextEnabled: Bool =
        (UserDefaults.standard.object(forKey: DeviceContextProvider.enabledKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(contextEnabled, forKey: DeviceContextProvider.enabledKey)
            if contextEnabled, connectionState != .disconnected {
                contextProvider.start()
            }
        }
    }
    /// Include exact coordinates (vs area name only)
    var contextPreciseLocation: Bool =
        (UserDefaults.standard.object(forKey: DeviceContextProvider.preciseKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(
                contextPreciseLocation, forKey: DeviceContextProvider.preciseKey
            )
        }
    }
    /// Live context line for the Settings preview
    var contextPreview: String? {
        contextProvider.contextLine()
    }
```

b) In the private section, after the `displayManager` property, add:

```swift
    @ObservationIgnored private let contextProvider = DeviceContextProvider()
```

c) In `startSession()`, directly after the line `Task { await ensureCameraPermission(interactive: false) }`, add:

```swift
        // Personal context (time/location/motion/battery/weather) —
        // requests location permission on first use
        contextProvider.start()
```

d) In `endSession()`, after `displayStatus = .off`, add:

```swift
        contextProvider.stop()
```

- [ ] **Step 3: View model — inject per query**

In `submitQuery(_:)`, add the context fetch at the top (after the `guard !trimmed.isEmpty` line):

```swift
        let context = contextProvider.contextLine()
```

Claude Direct branch — old:

```swift
            Task { await askClaudeDirect(trimmed) }
```

New:

```swift
            Task { await askClaudeDirect(trimmed, context: context) }
```

Bridge branch — old:

```swift
            apiClient?.sendQuery(
                trimmed,
                bridgeTTS: !useDeviceTTS && !displaySilentActive
            )
```

New (context travels as a text prefix; both bridges work unmodified; the
UI keeps showing `trimmed` because `lastTranscript` was already set):

```swift
            let outgoing = context.map { "[Context: \($0)]\n\n\(trimmed)" } ?? trimmed
            apiClient?.sendQuery(
                outgoing,
                bridgeTTS: !useDeviceTTS && !displaySilentActive
            )
```

Then update `askClaudeDirect` — old signature and ask call:

```swift
    private func askClaudeDirect(_ text: String) async {
```
```swift
            let reply = try await claudeClient.ask(text, photoJPEG: photo)
```

New:

```swift
    private func askClaudeDirect(_ text: String, context: String? = nil) async {
```
```swift
            let reply = try await claudeClient.ask(text, photoJPEG: photo, contextLine: context)
```

(`testQuery`/`testVisualQuery` call `submitQuery`, so they get context automatically — no changes there.)

- [ ] **Step 4: Build + regression tests**

Run (from repo root):
```bash
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build 2>&1 | tail -3
xcrun swiftc HermesGlasses/Services/DeviceContextFormatter.swift tests/device-context/main.swift -o /tmp/device-context-tests && /tmp/device-context-tests
xcrun swiftc HermesGlasses/Services/HermesDisplayLogic.swift tests/display-logic/main.swift -o /tmp/display-logic-tests && /tmp/display-logic-tests
```
Expected: `** BUILD SUCCEEDED **`, `All device context tests passed`, `All display logic tests passed`.

- [ ] **Step 5: Commit**

```bash
git add HermesGlasses/Services/ClaudeDirectClient.swift HermesGlasses/ViewModels/HermesSessionViewModel.swift
git commit -m "feat: attach device context to queries (uncached system block for Claude Direct, [Context:] prefix for bridges)"
```

---

### Task 4: Settings UI, CLAUDE.md, deploy

**Files:**
- Modify: `HermesGlasses/Views/ContentView.swift`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `hermesVM.contextEnabled`, `hermesVM.contextPreciseLocation`, `hermesVM.contextPreview` (Task 3).
- Produces: user-facing controls; nothing downstream.

- [ ] **Step 1: Context section in Settings**

In `SettingsView`'s `Form` in `HermesGlasses/Views/ContentView.swift`, insert a new section between the "Glasses Display" section and the "Glasses" (diagnostics) section:

```swift
                Section {
                    Toggle("Share my context", isOn: Binding(
                        get: { hermesVM.contextEnabled },
                        set: { hermesVM.contextEnabled = $0 }
                    ))
                    Toggle("Include precise coordinates", isOn: Binding(
                        get: { hermesVM.contextPreciseLocation },
                        set: { hermesVM.contextPreciseLocation = $0 }
                    ))
                    .disabled(!hermesVM.contextEnabled)
                    if hermesVM.contextEnabled {
                        Text(hermesVM.contextPreview ?? "Gathering…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Context")
                } footer: {
                    Text("Attached to every question so the assistant knows your time, place, and status. Weather is fetched from open-meteo.com using your coordinates. The line above is exactly what gets sent.")
                }
```

- [ ] **Step 2: CLAUDE.md note**

In `CLAUDE.md`, under "Key facts that are easy to get wrong", append:

```markdown
- **Device context:** every query carries a context line (time, location,
  motion, connectivity, battery, weather). Claude Direct gets it as a
  SECOND, uncached system block (persona block stays first + cached);
  bridge mode gets it as a "[Context: …]" prefix on the query text — the
  bridges need no changes. History stores raw user text only. Keys:
  `context_enabled` / `context_precise_location` (both default true).
```

- [ ] **Step 3: Build and deploy**

Run (from repo root):
```bash
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses -destination 'generic/platform=iOS' build 2>&1 | tail -3
xcrun devicectl device install app --device 00008150-001410210C7A401C "$HOME/Library/Developer/Xcode/DerivedData/HermesGlasses-dctuxkiumxnzfqcmvvzdamlksafw/Build/Products/Debug-iphoneos/Hermes Glasses.app"
xcrun devicectl device process launch --device 00008150-001410210C7A401C com.flowsxr.hermes-glasses
```
Expected: `** BUILD SUCCEEDED **`, install completes, launch succeeds (if the phone is locked, install still lands; note it in the report instead of failing).

- [ ] **Step 4: Commit**

```bash
git add HermesGlasses/Views/ContentView.swift CLAUDE.md
git commit -m "feat: context settings section with live preview line"
```

---

### On-device verification (user-run, after Task 4)

1. Start a session → iOS asks for location permission (first time only).
2. Settings → Context shows the live line: correct local time, suburb/city after a few seconds, online (Wi-Fi), battery %, temperature.
3. Ask "what time is it for me?" in Claude Direct → answered with local time, no clarifying question.
4. Ask "where am I?" and "do I need a jacket?" → location/weather-aware answers.
5. Switch to a bridge backend, ask "what time is it?" → same context awareness (Mac and maya, no bridge redeploy).
6. Toggle "Share my context" off → assistant no longer knows the time/place.
7. Airplane mode → context line shows "offline", queries still work when back online.
