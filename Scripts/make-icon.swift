#!/usr/bin/env swift
//
// Renders the application icon and packs it into an .icns.
//
// Keeping this as code rather than a checked-in binary means the icon is
// reviewable in a diff and can be tweaked without a design tool.
//
// Usage: swift Scripts/make-icon.swift Resources/AppIcon.icns
//
// MIT License. Copyright (c) 2026 LoLiMouse contributors.

import AppKit
import Foundation

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "AppIcon.icns")

/// Draws a mouse silhouette with a scroll wheel, on a rounded gradient tile.
func drawIcon(size: CGFloat, context: CGContext) {
    let scale = size / 1024
    context.saveGState()
    context.scaleBy(x: scale, y: scale)

    // Rounded background tile, matching the macOS icon grid.
    let inset: CGFloat = 100
    let tile = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let colours = [
        CGColor(red: 0.36, green: 0.42, blue: 0.95, alpha: 1),
        CGColor(red: 0.55, green: 0.30, blue: 0.85, alpha: 1),
    ] as CFArray
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: tile.minX, y: tile.maxY),
            end: CGPoint(x: tile.maxX, y: tile.minY),
            options: []
        )
    }
    context.restoreGState()

    // Mouse body.
    let body = CGRect(x: 390, y: 270, width: 244, height: 400)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 122, cornerHeight: 132, transform: nil)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    context.setLineWidth(34)
    context.addPath(bodyPath)
    context.strokePath()

    // Wheel slot, the thing this whole application is really about.
    let wheel = CGRect(x: 494, y: 470, width: 36, height: 118)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    context.addPath(CGPath(roundedRect: wheel, cornerWidth: 18, cornerHeight: 18, transform: nil))
    context.fillPath()

    // Ratchet marks either side of the wheel.
    context.setLineWidth(16)
    context.setLineCap(.round)
    for offset in stride(from: -60, through: 60, by: 60) {
        let y = 529 + CGFloat(offset)
        context.move(to: CGPoint(x: 430, y: y))
        context.addLine(to: CGPoint(x: 462, y: y))
        context.move(to: CGPoint(x: 562, y: y))
        context.addLine(to: CGPoint(x: 594, y: y))
    }
    context.strokePath()

    context.restoreGState()
}

func makePNG(size: Int) -> Data? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: size,
              height: size,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
        return nil
    }

    drawIcon(size: CGFloat(size), context: context)

    guard let image = context.makeImage() else { return nil }
    let representation = NSBitmapImageRep(cgImage: image)
    return representation.representation(using: .png, properties: [:])
}

let workDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("LoLiMouse.iconset-\(UUID().uuidString)")
let iconset = workDirectory.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = makePNG(size: variant.size) else {
        FileHandle.standardError.write(Data("could not render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

try? FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()

try? FileManager.default.removeItem(at: workDirectory)

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

print("wrote \(output.path)")
