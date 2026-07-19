//
// MapboxStaticMap.swift
//
// Builds a Mapbox Static Images API https URL for the lens: real map tiles
// with the user's pin, the destination pin, and the route drawn on top.
// Pure string assembly (no networking) so it unit-tests exactly.
//
// URL shape:
//   https://api.mapbox.com/styles/v1/{style}/static/{overlays}/{lon},{lat},{zoom}/{w}x{h}{@2x}?access_token=...
//

import Foundation

enum MapboxStaticMap {
    private static let style = "mapbox/streets-v12"
    private static let userColor = "3b82f6"        // blue
    private static let destColor = "ef4444"        // red

    static func url(
        token: String,
        center: MapCoordinate,
        zoom: Double,
        size: Int,
        user: MapCoordinate,
        destination: MapCoordinate?,
        route: [MapCoordinate],
        retina: Bool = true
    ) -> String {
        let dim = min(max(size, 1), 600)

        // Overlays are drawn in order; the route sits under the pins.
        var overlays: [String] = []
        if route.count >= 2 {
            let encoded = PolylineEncoder.encode(route)
            let escaped = encoded.addingPercentEncoding(
                withAllowedCharacters: pathAllowed
            ) ?? encoded
            overlays.append("path-4+\(userColor)-0.9(\(escaped))")
        }
        if let destination {
            overlays.append("pin-s+\(destColor)(\(num(destination.lon)),\(num(destination.lat)))")
        }
        overlays.append("pin-s+\(userColor)(\(num(user.lon)),\(num(user.lat)))")

        let overlayPart = overlays.joined(separator: ",")
        let centerPart = "\(num(center.lon)),\(num(center.lat)),\(num(zoom))"
        let sizePart = "\(dim)x\(dim)\(retina ? "@2x" : "")"

        return "https://api.mapbox.com/styles/v1/\(style)/static/"
            + "\(overlayPart)/\(centerPart)/\(sizePart)"
            + "?access_token=\(token)"
    }

    /// Trim trailing-zero noise so coordinates read cleanly and tests are
    /// stable (37.80 -> "37.8", 16.0 -> "16").
    private static func num(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        var s = String(format: "%.5f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// The encoded polyline contains \, ?, and other reserved characters that
    /// must be escaped inside the overlay path segment.
    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.")
        return set
    }()
}
