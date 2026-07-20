// Renders the Hermes Glasses app icon: the Ray-Ban glasses glyph from the
// design system, cream on a warm terracotta gradient. No alpha channel -
// iOS app icons must be fully opaque.
//
//   swift make_icon.swift <output.png>

import AppKit
import CoreGraphics
import Foundation

let size = 1024
let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "icon-1024.png"

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("context") }

func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: 1)
}

// Warm gradient: the design's #E08340 highlight down into a deeper burnt
// tone, so the glyph keeps contrast across the whole face.
let gradient = CGGradient(
    colorsSpace: space,
    colors: [rgb(0xE8, 0x8F, 0x4A), rgb(0xC4, 0x62, 0x2D), rgb(0x96, 0x42, 0x1B)] as CFArray,
    locations: [0.0, 0.55, 1.0])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: [])

let cream = rgb(0xF7, 0xF0, 0xE4)
ctx.setStrokeColor(cream)
ctx.setFillColor(cream)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Geometry: two rounded lenses either side of a short bridge, plus stubby
// temple arms so it still reads as glasses at 40pt.
let stroke: CGFloat = 40
let lensW: CGFloat = 262
let lensH: CGFloat = 210
let bridgeW: CGFloat = 58
let centerY: CGFloat = 512
let totalW = lensW * 2 + bridgeW
let leftX = (CGFloat(size) - totalW) / 2

func lens(at x: CGFloat) -> CGPath {
    // Slightly larger radius at the bottom: the Wayfarer-ish taper from the
    // design system's glyph (border-radius: 4px 4px 6px 6px).
    let rect = CGRect(x: x, y: centerY - lensH / 2, width: lensW, height: lensH)
    let path = CGMutablePath()
    let rTop: CGFloat = 56
    let rBot: CGFloat = 82
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY - rTop))
    path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: rTop)
    path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: rTop)
    path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: rBot)
    path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: rBot)
    path.closeSubpath()
    return path
}

ctx.setLineWidth(stroke)
ctx.addPath(lens(at: leftX))
ctx.strokePath()
ctx.addPath(lens(at: leftX + lensW + bridgeW))
ctx.strokePath()

// Bridge, sitting in the upper third like a real frame
let bridgeY = centerY + lensH / 2 - 48
ctx.setLineWidth(34)
ctx.move(to: CGPoint(x: leftX + lensW - 4, y: bridgeY))
ctx.addLine(to: CGPoint(x: leftX + lensW + bridgeW + 4, y: bridgeY))
ctx.strokePath()

// Temple arms: short stubs angling back from the outer hinges
ctx.setLineWidth(34)
for (hinge, dir) in [(leftX, CGFloat(-1)), (leftX + totalW, CGFloat(1))] {
    ctx.move(to: CGPoint(x: hinge, y: bridgeY))
    ctx.addLine(to: CGPoint(x: hinge + dir * 66, y: bridgeY + 26))
    ctx.strokePath()
}

guard let image = ctx.makeImage() else { fatalError("image") }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png")
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(png.count / 1024) KB)")
