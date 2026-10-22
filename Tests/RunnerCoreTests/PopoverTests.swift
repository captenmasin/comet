import AppKit
import Sparkle
import SwiftUI
import Testing
@testable import Runner
@testable import RunnerCore

@Suite(.serialized) @MainActor
struct PopoverTests {
    private let suite = "Comet.PopoverTests.\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    @Test func reopeningRestoresARemovedMenuBarItem() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = AppDelegate(store: RunnerStore(), defaults: defaults)
        #expect(delegate.menuBarInserted)
        delegate.menuBarInserted = false
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(delegate.menuBarInserted)
    }

    @Test func dockPresenceFollowsAppWindows() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        let delegate = AppDelegate(store: RunnerStore(), defaults: defaults)
        #expect(delegate.showMainWindowOnLaunch)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: window.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let popover = NSPanel(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        let menuBarWindow = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        for window in [window, other, popover, menuBarWindow] { window.isReleasedWhenClosed = false }
        defer {
            window.close()
            other.close()
            popover.close()
            menuBarWindow.close()
            app.setActivationPolicy(previousPolicy)
        }

        app.setActivationPolicy(.accessory)
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        defer { driver.dismissUpdateInstallation() }
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        let checking = try #require(app.windows.first { $0.identifier?.rawValue == "SUStatus" && $0.isVisible })
        checking.setFrameOrigin(window.frame.origin)
        delegate.updateDockPresence(Notification(name: NSWindow.didBecomeMainNotification, object: checking))
        #expect(app.activationPolicy() == .accessory)
        delegate.updateDockPresence(Notification(name: NSWindow.willCloseNotification, object: checking))
        #expect(app.activationPolicy() == .accessory)
        #expect(delegate.showMainWindowOnLaunch)
        driver.dismissUpdateInstallation()
        driver.showDownloadInitiated(cancellation: {})
        let downloading = try #require(app.windows.first { $0.identifier?.rawValue == "SUStatus" && $0.isVisible })
        downloading.setFrameOrigin(window.frame.origin)
        delegate.updateDockPresence(Notification(name: NSWindow.didBecomeMainNotification, object: downloading))
        #expect(app.activationPolicy() == .accessory)
        delegate.updateDockPresence(Notification(name: NSWindow.didBecomeMainNotification, object: popover))
        #expect(app.activationPolicy() == .accessory)
        #expect(delegate.showMainWindowOnLaunch)

        window.orderFront(nil)
        delegate.updateDockPresence(Notification(name: NSWindow.didBecomeMainNotification, object: window))
        #expect(app.activationPolicy() == .regular)
        #expect(!delegate.showMainWindowOnLaunch)
        let relaunched = AppDelegate(store: delegate.store, defaults: defaults)
        #expect(!relaunched.showMainWindowOnLaunch)
        other.orderFront(nil)
        delegate.updateDockPresence(Notification(name: NSWindow.willCloseNotification, object: other))
        #expect(app.activationPolicy() == .regular)
        other.close()

        popover.orderFront(nil)
        menuBarWindow.orderFront(nil)
        #expect(!menuBarWindow.canBecomeMain)
        delegate.updateDockPresence(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(app.activationPolicy() == .accessory)
        #expect(!delegate.showMainWindowOnLaunch)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(app))
        window.close()
        window.orderFront(nil)
        delegate.updateDockPresence(Notification(name: NSWindow.didBecomeMainNotification, object: window))
        #expect(app.activationPolicy() == .regular)
    }

    @Test(arguments: [0, 1, 3])
    func launchLoadsWithoutAMainWindow(count: Int) async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "hasShownMainWindow")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let runners = try fixtures(count)
        try paths.save(runners)
        let store = RunnerStore(paths: paths, restore: {
            throw RunnerError.message("Fixture authentication unavailable")
        })
        let delegate = AppDelegate(store: store, defaults: defaults)
        #expect(delegate.store === store)
        #expect(!delegate.showMainWindowOnLaunch)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        for _ in 0..<200 where store.error == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.error == "Fixture authentication unavailable")
        #expect(store.runners == runners)
        #expect(store.selectedID == runners.first?.id)
        #expect(await store.shutdown())
    }

    @Test(arguments: [0, 1, 3, 10])
    func popoverFitsSavedRunners(count: Int) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let runners = try fixtures(count)
        try paths.save(runners)
        let store = RunnerStore(paths: paths)
        store.runners = try paths.load()
        let view = NSHostingView(rootView: RunnerPopover(store: store)
            .environment(\.colorScheme, .light).background(Color.white))
        let controller = NSHostingController(rootView: RunnerPopover(store: store))
        let compressed = controller.sizeThatFits(in: CGSize(width: 380, height: 0))
        let size = view.fittingSize
        #expect(compressed.height == size.height)
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(30))
        view.layoutSubtreeIfNeeded()
        #expect(size.width == 380)
        #expect(size.height > (count == 0 ? 100 : 140))
        #expect(size.height < 460)
        let scrollViews = descendants(view).compactMap { $0 as? NSScrollView }
        #expect(scrollViews.count == (count == 0 ? 0 : 1))
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("runner-bar-lifecycle-check")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("popover-\(count).png"))
        if count == 10 {
            let scroll = try #require(scrollViews.first)
            let document = try #require(scroll.documentView)
            #expect(scroll.contentSize.height <= 341)
            #expect(document.frame.height > scroll.contentSize.height)
            document.scroll(NSPoint(x: 0, y: document.frame.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            #expect(scroll.contentView.bounds.maxY >= document.frame.maxY - 1)
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scrolled = try #require(bitmap.representation(using: .png, properties: [:]))
            try scrolled.write(to: output.appendingPathComponent("popover-10-scrolled.png"))
        }
        if let first = runners.first, count < 10 {
            store.states[first.id] = .busy
            try await Task.sleep(for: .milliseconds(30))
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let updated = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(updated != data)
            try updated.write(to: output.appendingPathComponent("popover-\(count)-updated.png"))
        }
    }

    private func fixtures(_ count: Int) throws -> [RunnerCore.Runner] {
        try (0..<count).map {
            try RunnerCore.Runner(repository: "fixture/repo-\($0)", name: "Mac-\($0)", label: "fixture-\($0)")
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
