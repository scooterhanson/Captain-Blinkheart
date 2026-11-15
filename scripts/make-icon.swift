// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

// Builds a 1024 px macOS icon PNG from captain_blinkheart_icon.png.
//
// macOS 26 shrinks any icon whose outline isn't Apple's standard rounded
// square onto a gray tile. Icons with a drop shadow, or a plain opaque square,
// get that treatment. So this:
//   1. crops the art just inside its silver rim and scales it to fill a
//      square, painting the small corner gaps with the art's background;
//   2. clips that square to Apple's continuous-corner shape (a superellipse)
//      at the standard icon-grid size: an 824 px tile centered on 1024 px,
//      with transparent margins and no shadow.
//
// Usage: swift scripts/make-icon.swift <source.png> <output-1024.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3,
      let data = FileManager.default.contents(atPath: args[1]),
      let bitmap = NSBitmapImageRep(data: data),
      let art = bitmap.cgImage
else {
    FileHandle.standardError.write("usage: make-icon.swift <source.png> <output.png>\n".data(using: .utf8)!)
    exit(1)
}

// The art's dark interior, inside the silver rim, measured on the 896x894
// source and scaled if the source is re-exported at another size. The rim's
// inner edge is about 18 px in from each side; 2 px more avoids its fringe.
let sx = CGFloat(bitmap.pixelsWide) / 896
let sy = CGFloat(bitmap.pixelsHigh) / 894
let interior = CGRect(x: 20 * sx, y: 20 * sy, width: 854 * sx, height: 852 * sy)
let interiorRadius = 160 * sx

let canvas: CGFloat = 1024
guard let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

// Background: a vertical gradient sampled down the left edge of the interior,
// which is plain backdrop with no artwork, so the corner fills match it.
func sample(_ x: CGFloat, _ y: CGFloat) -> CGColor {
    bitmap.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB)?.cgColor ?? NSColor.black.cgColor
}
let stops = 8
let colors = (0..<stops).map { index -> CGColor in
    let fraction = CGFloat(index) / CGFloat(stops - 1)
    return sample(interior.minX + 6 * sx, interior.minY + 6 * sy + fraction * (interior.height - 12 * sy))
}
let locations = (0..<stops).map { CGFloat($0) / CGFloat(stops - 1) }
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
// Image rows run top-down; CoreGraphics' y axis runs bottom-up.
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas), end: CGPoint(x: 0, y: 0), options: [])

// Artwork interior, scaled to fill the canvas and clipped to its own rounded
// corners so none of the rim shows.
guard let cropped = art.cropping(to: interior.integral) else { exit(1) }
let fill = CGRect(x: 0, y: 0, width: canvas, height: canvas)
let radius = interiorRadius * canvas / interior.width
context.saveGState()
context.addPath(CGPath(roundedRect: fill, cornerWidth: radius, cornerHeight: radius, transform: nil))
context.clip()
context.interpolationQuality = .high
context.draw(cropped, in: fill)
context.restoreGState()

guard let fullBleed = context.makeImage() else { exit(1) }

/// Apple's continuous-corner icon outline, approximated by a superellipse.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(angle), s = sin(angle)
        let x = rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

guard let iconContext = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
iconContext.addPath(squircle(in: tile))
iconContext.clip()
iconContext.interpolationQuality = .high
iconContext.draw(fullBleed, in: tile)

guard let output = iconContext.makeImage(),
      let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
