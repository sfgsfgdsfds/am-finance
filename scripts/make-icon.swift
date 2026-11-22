#!/usr/bin/env swift
// make-icon.swift — render the AM Finance 1024×1024 iOS app icon.
//
// Standalone macOS script (CoreGraphics/AppKit only, no third-party assets):
// draws a deep-green → teal diagonal gradient, a white rising bar chart with
// a trend arrow, and a bold "AM" monogram, then writes an opaque sRGB PNG into
// App/Assets.xcassets/AppIcon.appiconset. Full-bleed square, no transparency,
// no corner mask — iOS applies the rounded-rect mask itself.
//
// Run from anywhere:  swift scripts/make-icon.swift

import AppKit
import Foundation

let side = 1024
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // repo root
let appIconSet = root.appendingPathComponent(
    "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
let output = appIconSet.appendingPathComponent("AppIcon-1024.png")

guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("make-icon: sRGB color space unavailable")
}
// noneSkipLast => 24-bit RGB, no alpha channel: the icon is fully opaque.
guard let ctx = CGContext(
    data: nil, width: side, height: side,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: srgb,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("make-icon: could not create bitmap context")
}

func color(_ hex: Int) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(colorSpace: srgb, components: [r, g, b, 1])!
}
let s = CGFloat(side)

// MARK: 1 — deep green → teal diagonal gradient (top-left → bottom-right)
let gradient = CGGradient(
    colorsSpace: srgb,
    colors: [color(0x064E3B), color(0x14B8A6)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: s),
                       end: CGPoint(x: s, y: 0),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

let white = color(0xFFFFFF)
ctx.setFillColor(white)
ctx.setStrokeColor(white)

// MARK: 2 — rising bar chart: flat-bottom, round-top bars on one baseline
func barPath(x: CGFloat, base: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
    let r = w / 2 // semicircular top
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x, y: base))
    p.addLine(to: CGPoint(x: x, y: base + h - r))
    p.addArc(center: CGPoint(x: x + r, y: base + h - r),
             radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
    p.addLine(to: CGPoint(x: x + w, y: base))
    p.closeSubpath()
    return p
}

let baseline: CGFloat = 575
let barW: CGFloat = 124
let barGap: CGFloat = 76
let barX0 = (s - (3 * barW + 2 * barGap)) / 2
for (i, h) in [CGFloat(150), 235, 330].enumerated() {
    ctx.addPath(barPath(x: barX0 + CGFloat(i) * (barW + barGap),
                        base: baseline, w: barW, h: h))
    ctx.fillPath()
}

// MARK: 3 — trend arrow rising over the bars (thick line + triangular head)
let arrowFrom = CGPoint(x: 285, y: 825)
let arrowTo = CGPoint(x: 760, y: 975)
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.move(to: arrowFrom)
ctx.addLine(to: arrowTo)
ctx.strokePath()

let angle = atan2(arrowTo.y - arrowFrom.y, arrowTo.x - arrowFrom.x)
let headLen: CGFloat = 110
let halfWidth: CGFloat = 58
let back = CGPoint(x: arrowTo.x - headLen * cos(angle),
                   y: arrowTo.y - headLen * sin(angle))
let perp = CGPoint(x: -sin(angle), y: cos(angle))
ctx.move(to: arrowTo)
ctx.addLine(to: CGPoint(x: back.x + perp.x * halfWidth,
                        y: back.y + perp.y * halfWidth))
ctx.addLine(to: CGPoint(x: back.x - perp.x * halfWidth,
                        y: back.y - perp.y * halfWidth))
ctx.closePath()
ctx.fillPath()

// MARK: 4 — "AM" monogram, heavy weight so it stays legible at 60 pt
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let font = NSFont.systemFont(ofSize: 350, weight: .black)
let label = NSAttributedString(string: "AM", attributes: [
    .font: font,
    .foregroundColor: NSColor.white,
])
let textSize = label.size()
// Center the cap-height optically (the string has no descenders).
let textCenterY: CGFloat = 260
label.draw(at: NSPoint(x: (s - textSize.width) / 2,
                       y: textCenterY - font.capHeight / 2))
NSGraphicsContext.restoreGraphicsState()

// MARK: 5 — write the PNG (image carries the sRGB profile, no alpha)
guard let image = ctx.makeImage() else {
    fatalError("make-icon: could not produce image")
}
guard let dest = CGImageDestinationCreateWithURL(
    output as CFURL, "public.png" as CFString, 1, nil)
else {
    fatalError("make-icon: could not create image destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    fatalError("make-icon: failed writing \(output.path)")
}
print("make-icon: wrote \(output.path) (\(side)x\(side), sRGB, opaque)")
