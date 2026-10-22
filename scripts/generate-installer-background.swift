#!/usr/bin/env swift
import AppKit

// Run from the repository root; the Finder layout uses a 660 × 360 point canvas.
let output = URL(fileURLWithPath: "Artwork/Installer/background.png")
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1320, pixelsHigh: 720,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: 660, height: 360)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.translateBy(x: 0, y: 360)
context.scaleBy(x: 1, y: -1)
NSGradient(starting: NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1),
           ending: NSColor(srgbRed: 0.92, green: 0.92, blue: 0.98, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: 660, height: 360), angle: 45)

func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (value as NSString).draw(in: NSRect(x: 30, y: y, width: 600, height: 40), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: paragraph
    ])
}

// Text draws into a flipped context so the PNG and Finder share top-left coordinates.
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
text("Drag Comet to Applications to install.", y: 44, size: 15, weight: .regular,
     color: NSColor(srgbRed: 0.40, green: 0.40, blue: 0.48, alpha: 1))

NSColor.white.withAlphaComponent(0.5).setFill()
for x in [106, 406] {
    NSBezierPath(ovalIn: NSRect(x: x, y: 114, width: 148, height: 148)).fill()
}
NSColor(srgbRed: 0.48, green: 0.47, blue: 0.70, alpha: 1).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 306, y: 188))
arrow.line(to: NSPoint(x: 354, y: 188))
arrow.move(to: NSPoint(x: 344, y: 178))
arrow.line(to: NSPoint(x: 354, y: 188))
arrow.line(to: NSPoint(x: 344, y: 198))
arrow.stroke()
NSGraphicsContext.restoreGraphicsState()

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
let decoded = NSBitmapImageRep(data: try Data(contentsOf: output))!
precondition(decoded.pixelsWide == 1320 && decoded.pixelsHigh == 720)
precondition(decoded.size == NSSize(width: 660, height: 360), "Preserve the Retina image's point size")
print("Exported installer background at 2×")
