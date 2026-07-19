//
// swiftc HermesGlasses/Services/Navigation/NavigationTypes.swift \
//        HermesGlasses/Services/Navigation/PolylineEncoder.swift \
//        HermesGlasses/Services/Navigation/MapboxStaticMap.swift \
//        tests/mapbox/main.swift -o /tmp/mapbox-tests && /tmp/mapbox-tests
//
import Foundation

var failures = 0
func expect(_ c: Bool, _ label: String) {
    if c { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let u = MapboxStaticMap.url(
    token: "tok123",
    center: MapCoordinate(lat: 37.77, lon: -122.42),
    zoom: 16,
    size: 600,
    user: MapCoordinate(lat: 37.77, lon: -122.42),
    destination: MapCoordinate(lat: 37.80, lon: -122.40),
    route: [MapCoordinate(lat: 37.77, lon: -122.42), MapCoordinate(lat: 37.80, lon: -122.40)]
)

expect(u.hasPrefix("https://api.mapbox.com/styles/v1/mapbox/streets-v12/static/"), "https + style prefix")
expect(u.contains("pin-s+3b82f6(-122.42,37.77)"), "user pin lon,lat blue")
expect(u.contains("pin-s+ef4444(-122.4,37.8)"), "destination pin red")
expect(u.contains("path-4+3b82f6-0.9("), "route path overlay")
expect(u.contains("/-122.42,37.77,16/"), "center lon,lat,zoom")
expect(u.contains("/600x600@2x?"), "size retina")
expect(u.contains("access_token=tok123"), "token query")

// Size is clamped to <= 600
let big = MapboxStaticMap.url(token: "t", center: MapCoordinate(lat: 0, lon: 0), zoom: 14,
                              size: 9000, user: MapCoordinate(lat: 0, lon: 0),
                              destination: nil, route: [])
expect(big.contains("/600x600@2x?"), "size clamped to 600")
expect(!big.contains("path-"), "no path when route empty")
expect(!big.contains("ef4444"), "no destination pin when nil")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
