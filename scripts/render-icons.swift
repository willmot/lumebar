#!/usr/bin/env swift
// Renders the SVG sources in design/icon into the PNGs used by the asset catalog.
// Usage: swift scripts/render-icons.swift (run from the repository root)

import AppKit

let assets = "Sources/LumeBar/Resources/Assets.xcassets"

func render(svg: String, pixels: Int, to output: String) throws {
    guard let image = NSImage(contentsOfFile: svg) else {
        throw NSError(domain: "render-icons", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot load \(svg)"])
    }
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "render-icons", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot allocate bitmap"])
    }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render-icons", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot encode \(output)"])
    }
    try data.write(to: URL(fileURLWithPath: output))
    print("wrote \(output)")
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try render(svg: "design/icon/AppIcon.svg", pixels: size, to: "\(assets)/AppIcon.appiconset/appicon-\(size).png")
}
try render(svg: "design/icon/MenubarIcon.svg", pixels: 18, to: "\(assets)/MenubarIcon.imageset/menubar-1x.png")
try render(svg: "design/icon/MenubarIcon.svg", pixels: 36, to: "\(assets)/MenubarIcon.imageset/menubar-2x.png")
