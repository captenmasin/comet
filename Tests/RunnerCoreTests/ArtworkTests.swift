import AppKit
import SwiftUI
import Testing
@testable import Runner

#if DEBUG
@Test func runningJobSimulationRequiresItsDevelopmentFlag() {
    #expect(!Entry.simulatesRunningJob(arguments: ["Comet"]))
    #expect(Entry.simulatesRunningJob(arguments: ["Comet", "--simulate-running-job"]))
}
#endif

@Test(arguments: [false, true], [false, true]) @MainActor
func unchangedStatusImagesKeepTheirIdentity(dark: Bool, running: Bool) {
    for failure in [false, true] {
        for success in [false, true] {
            let first = MenuBarStatusIcon.image(isRunningJob: running,
                hasFailure: failure, hasSuccess: success, dark: dark)
            let next = MenuBarStatusIcon.image(isRunningJob: running,
                hasFailure: failure, hasSuccess: success, dark: dark)
            #expect(first === next)
        }
    }
}

@Test(arguments: [false, true], [false, true]) @MainActor
func menuBarSuccessDotIsGreenAndFailureTakesPriority(dark: Bool, running: Bool) throws {
    for failure in [false, true] {
        let image = MenuBarStatusIcon.image(isRunningJob: running,
            hasFailure: failure, hasSuccess: true, dark: dark)
        #expect(image.size == NSSize(width: 18, height: 18) && !image.isTemplate)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let dot = try #require(bitmap.colorAt(x: bitmap.pixelsWide * 15 / 18,
            y: bitmap.pixelsHigh * 15 / 18)?.usingColorSpace(.deviceRGB))
        #expect(dot.alphaComponent > 0.9)
        #expect(failure ? dot.redComponent > dot.greenComponent * 2 : dot.greenComponent > dot.redComponent * 2)
    }
}

@Test(arguments: [false, true], [false, true]) @MainActor
func menuBarFailureDotStaysRedWithoutChangingSize(dark: Bool, running: Bool) throws {
    let image = MenuBarStatusIcon.image(isRunningJob: running, hasFailure: true, dark: dark)
    #expect(image.size == NSSize(width: 18, height: 18))
    #expect(!image.isTemplate)
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    let dot = try #require(bitmap.colorAt(x: bitmap.pixelsWide * 15 / 18,
                                        y: bitmap.pixelsHigh * 15 / 18)?.usingColorSpace(.deviceRGB))
    #expect(dot.alphaComponent > 0.9)
    #expect(dot.redComponent > 0.6 && dot.redComponent > dot.greenComponent * 2)
    let colors = (0..<bitmap.pixelsWide).flatMap { x in
        (0..<bitmap.pixelsHigh).compactMap { y in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }
    }
    #expect(colors.contains { $0.alphaComponent > 0.9 && (dark
        ? $0.redComponent > 0.9 && $0.greenComponent > 0.9
        : $0.redComponent < 0.1 && $0.greenComponent < 0.1) })
}

@Test @MainActor
func staticRunningHeadIsACompleteOutline() throws {
    let image = MenuBarStatusIcon.image(isRunningJob: true)
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    for (x, y) in [(12.26, 3.25), (14.71, 5.70), (12.26, 8.15), (9.81, 5.70)] {
        let color = try #require(bitmap.colorAt(x: Int(x * Double(bitmap.pixelsWide) / 18),
                                               y: Int(y * Double(bitmap.pixelsHigh) / 18)))
        #expect(color.alphaComponent > 0.7)
    }
    #expect(bitmap.colorAt(x: bitmap.pixelsWide * 12 / 18, y: bitmap.pixelsHigh * 6 / 18)?.alphaComponent == 0)
}

@Test @MainActor
func menuBarActivityFramesKeepTheStreaksAndRotateTheHead() throws {
    let idle = MenuBarStatusIcon.image(isRunningJob: false)
    let first = MenuBarStatusIcon.image(isRunningJob: true, angle: 0)
    let next = MenuBarStatusIcon.image(isRunningJob: true, angle: 20)
    #expect(idle.size == NSSize(width: 18, height: 18))
    #expect(first.size == idle.size && next.size == idle.size)
    #expect(idle.isTemplate && first.isTemplate && next.isTemplate)
    let firstData = try #require(first.tiffRepresentation)
    let nextData = try #require(next.tiffRepresentation)
    let a = try #require(NSBitmapImageRep(data: firstData))
    let b = try #require(NSBitmapImageRep(data: nextData))
    #expect(a.representation(using: .png, properties: [:]) != b.representation(using: .png, properties: [:]))
    for x in 0..<a.pixelsWide {
        for y in 0..<a.pixelsHigh where x < a.pixelsWide * 8 / 18 || y > a.pixelsHigh * 10 / 18 {
            #expect(a.colorAt(x: x, y: y) == b.colorAt(x: x, y: y))
        }
    }
    #expect(a.colorAt(x: a.pixelsWide * 12 / 18, y: a.pixelsHigh * 6 / 18)?.alphaComponent == 0)
}

@Test(arguments: [("CometTemplate", 18), ("CometTemplate@2x", 36),
                  ("CometStreaksTemplate", 18), ("CometStreaksTemplate@2x", 36)])
func cometGlyphHasTransparentMarginsAndMonochromeInk(name: String, pixels: Int) throws {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "png"))
    let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
    #expect(bitmap.pixelsWide == pixels && bitmap.pixelsHigh == pixels)
    let corner = try #require(bitmap.colorAt(x: 0, y: 0))
    #expect(corner.alphaComponent == 0)
    let ink = (0..<pixels).flatMap { x in
        (0..<pixels).compactMap { y in bitmap.colorAt(x: x, y: y) }.filter { $0.alphaComponent > 0 }
    }
    #expect(ink.contains { $0.alphaComponent > 0.9 })
    #expect(ink.allSatisfy { $0.redComponent == 0 && $0.greenComponent == 0 && $0.blueComponent == 0 })
}

@Test(arguments: [false, true]) @MainActor
func menuBarCometShowsJobActivityInBothAppearances(dark: Bool) async throws {
    _ = NSApplication.shared
    let view = NSHostingView(rootView: MenuBarStatusIcon(isRunningJob: false).foregroundStyle(.primary)
        .padding(4)
        .background(dark ? Color.black : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light))
    let size = view.fittingSize
    view.setFrameSize(size)
    let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(30))
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let colors = (0..<bitmap.pixelsWide).flatMap { x in
        (0..<bitmap.pixelsHigh).compactMap { y in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }
    }
    #expect(colors.contains { dark ? $0.redComponent > 0.7 : $0.redComponent < 0.3 })

    let output = FileManager.default.temporaryDirectory.appendingPathComponent("comet-menubar-check")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try #require(bitmap.representation(using: .png, properties: [:]))
        .write(to: output.appendingPathComponent("idle-\(dark).png"))
    view.rootView = MenuBarStatusIcon(isRunningJob: true, animates: false).foregroundStyle(.primary)
        .padding(4)
        .background(dark ? Color.black : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light)
    let busySize = view.fittingSize
    #expect(busySize == size)
    view.setFrameSize(busySize)
    try await Task.sleep(for: .milliseconds(30))
    view.layoutSubtreeIfNeeded()
    let busy = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: busy)
    let busyData = try #require(busy.representation(using: .png, properties: [:]))
    try busyData.write(to: output.appendingPathComponent("busy-\(dark).png"))
    try await Task.sleep(for: .milliseconds(120))
    view.layoutSubtreeIfNeeded()
    view.cacheDisplay(in: view.bounds, to: busy)
    #expect(busy.representation(using: .png, properties: [:]) == busyData)
}
