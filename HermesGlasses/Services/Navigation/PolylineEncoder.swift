//
// PolylineEncoder.swift
//
// Google/Mapbox precision-5 encoded polyline. Mapbox Static Images draws a
// route with a `path-...(<encoded>)` overlay, so a MapKit route's coordinates
// are encoded here before going into the image URL.
//

import Foundation

enum PolylineEncoder {
    static func encode(_ coords: [MapCoordinate]) -> String {
        var result = ""
        var prevLat = 0
        var prevLon = 0
        for c in coords {
            let lat = Int((c.lat * 1e5).rounded())
            let lon = Int((c.lon * 1e5).rounded())
            result += chunk(lat - prevLat)
            result += chunk(lon - prevLon)
            prevLat = lat
            prevLon = lon
        }
        return result
    }

    /// Encode one signed delta into the base-64-ish polyline alphabet.
    private static func chunk(_ value: Int) -> String {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        var out = ""
        while v >= 0x20 {
            let byte = (0x20 | (v & 0x1f)) + 63
            out.append(Character(UnicodeScalar(byte)!))
            v >>= 5
        }
        out.append(Character(UnicodeScalar(v + 63)!))
        return out
    }
}
