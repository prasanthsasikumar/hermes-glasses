//
// swiftc HermesGlasses/Services/Navigation/NavigationTypes.swift \
//        HermesGlasses/Services/Navigation/PolylineEncoder.swift \
//        tests/polyline/main.swift -o /tmp/polyline-tests && /tmp/polyline-tests
//
import Foundation

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}

// Canonical example from the Google Encoded Polyline Algorithm docs.
let coords = [
    MapCoordinate(lat: 38.5, lon: -120.2),
    MapCoordinate(lat: 40.7, lon: -120.95),
    MapCoordinate(lat: 43.252, lon: -126.453),
]
expectEqual(PolylineEncoder.encode(coords), "_p~iF~ps|U_ulLnnqC_mqNvxq`@", "reference polyline")
expectEqual(PolylineEncoder.encode([]), "", "empty")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
