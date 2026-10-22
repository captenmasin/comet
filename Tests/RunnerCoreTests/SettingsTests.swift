import AppKit
import SwiftUI
import Synchronization
import Testing
@testable import Runner
@testable import RunnerCore

@Suite(.serialized) @MainActor
struct SettingsTests {
    @Test(arguments: [false, true], [false, true])
    func settingsStayWithinTheirWindow(signedIn: Bool, dark: Bool) async throws {
        let store = RunnerStore()
        store.signedIn = signedIn
        store.account = String(repeating: "a", count: 39)
        try await render(AnyView(SettingsView(store: store)), size: CGSize(width: 520, height: signedIn ? 350 : 570),
                         name: "settings-\(signedIn ? "connected" : "connect")-\(dark ? "dark" : "light")", dark: dark)
    }

    @Test(arguments: [false, true])
    func enabledMCPConfigurationFitsItsWindow(dark: Bool) async throws {
        let suite = "comet-mcp-settings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RunnerStore()
        store.signedIn = true
        store.account = "fixture-account"
        store.mcp = MCPServer(store: store, defaults: defaults, port: 0,
                              loadToken: { String(repeating: "fixture", count: 10) }, saveToken: { _ in })
        await store.mcp.setEnabled(true)
        do {
            #expect(store.mcp.endpoint != nil)
            try await render(AnyView(SettingsView(store: store)), size: CGSize(width: 520, height: 350),
                             name: "settings-mcp-\(dark ? "dark" : "light")", dark: dark, scrollToBottom: true)
            await store.mcp.stop()
        } catch {
            await store.mcp.stop()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func replacementTokenEditorFitsItsWindow(dark: Bool) async throws {
        let store = RunnerStore()
        store.signedIn = true
        store.account = "fixture-account"
        try await render(AnyView(TokenReplacementView(store: store)), size: CGSize(width: 520, height: 330),
                         name: "token-editor-\(dark ? "dark" : "light")", dark: dark)
    }

    @Test(arguments: [false, true])
    func addRunnerFitsWithLongRepositoryNames(dark: Bool) async throws {
        SettingsRepositoryProtocol.requests.withLock { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsRepositoryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = RunnerStore(github: GitHub(session: session, token: "fixture-token"))
        store.signedIn = true
        store.account = "fixture-account"
        try await render(AnyView(SetupView(store: store)), size: CGSize(width: 560, height: 460),
                         name: "add-runner-\(dark ? "dark" : "light")", dark: dark)
        #expect(SettingsRepositoryProtocol.requests.withLock { $0 } > 0)
    }

    private func render(_ screen: AnyView, size: CGSize, name: String, dark: Bool, scrollToBottom: Bool = false) async throws {
        _ = NSApplication.shared
        let root = screen.background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        defer { window.close() }
        view.setFrameSize(size)
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let minimum = NSHostingController(rootView: root).sizeThatFits(in: size)
        #expect(minimum.width <= size.width && minimum.height <= size.height)
        func descendants(_ node: NSView) -> [NSView] { [node] + node.subviews.flatMap(descendants) }
        let scrolls = descendants(view).compactMap { $0 as? NSScrollView }
        #expect(scrolls.count == 1)
        let scroll = try #require(scrolls.first)
        let document = try #require(scroll.documentView)
        #expect(document.frame.width <= scroll.contentSize.width + 1)
        if scrollToBottom {
            document.scroll(NSPoint(x: 0, y: document.frame.height))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("comet-settings-check")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.maxY >= document.frame.maxY - 1)
    }
}

private final class SettingsRepositoryProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        let repository = String(repeating: "o", count: 39) + "/" + String(repeating: "r", count: 100)
        let payload = "[{\"id\":1,\"full_name\":\"\(repository)\",\"permissions\":{\"admin\":true}}]"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
