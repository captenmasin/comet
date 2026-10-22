#!/usr/bin/env swift
import AppKit

// Run from the repository root: swift scripts/generate-icons.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Sources/Runner/Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

let comet = NSImage(contentsOf: root.appendingPathComponent("Artwork/Comet.icon/Assets/Group.svg"))!
let artwork = try XMLDocument(contentsOf: root.appendingPathComponent("Artwork/Comet.icon/Assets/Group.svg"), options: [])
let shapes = try artwork.nodes(forXPath: "//*[local-name()='path']")
precondition(shapes.count == 4, "Expected three streaks followed by the comet head")
shapes.last!.detach()
let streaks = NSImage(data: artwork.xmlData)!

func exportPNG(to url: URL, pixels: Int, draw: () -> Void) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .clear)
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    let decoded = NSBitmapImageRep(data: try Data(contentsOf: url))!
    precondition(decoded.pixelsWide == pixels && decoded.pixelsHigh == pixels, "Incorrect export dimensions")
    precondition(decoded.colorAt(x: 0, y: 0)!.alphaComponent == 0, "Artwork needs transparent margins")
    precondition((0..<pixels).contains { x in
        (0..<pixels).contains { y in decoded.colorAt(x: x, y: y)!.alphaComponent > 0 }
    }, "Artwork is empty")
}

for (name, image) in [("CometTemplate", comet), ("CometStreaksTemplate", streaks)] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        try exportPNG(to: resources.appendingPathComponent("\(name)\(suffix).png"), pixels: 18 * scale) {
            image.draw(in: NSRect(x: 57, y: 57, width: 910, height: 910))
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: 1024, height: 1024).fill(using: .sourceIn)
        }
    }
}
print("Exported Comet and streak template glyphs at 1× and 2×")
