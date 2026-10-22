import Foundation
import Darwin
import Testing
import Synchronization
import AppKit
import SwiftUI
import Network
import Observation
@testable import RunnerCore
@testable import Runner

@Test @MainActor func vmInstallRejectsAnUnpackagedHelperBeforeConnecting() async throws {
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let connection = try VMConnection(address: "192.168.64.2", directory: root, password: "fixture")
    let runner = try RunnerCore.Runner(repository: "fixture/repo", name: "fixture", label: "fixture", execution: .macOSVM)
    var reportedProgress = false
    do {
        _ = try await connection.install(runner, github: GitHub(), executable: root.appendingPathComponent("Comet")) { _ in
            reportedProgress = true
        }
        Issue.record("An unpackaged helper must not be uploaded to the VM")
    } catch {
        #expect(error.localizedDescription.contains("helper framework is missing"))
    }
    #expect(!reportedProgress)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func vmHelperArchivePreservesTheSignedAppBundle() async throws {
    let root = URL.temporaryDirectory.appendingPathComponent("comet helper ' \(UUID())")
    let contents = root.appendingPathComponent("Comet.app/Contents")
    let executable = contents.appendingPathComponent("MacOS/Comet")
    let files = FileManager.default
    defer { try? files.removeItem(at: root) }
    try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try files.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let framework = package.appendingPathComponent(".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework")
    try files.createDirectory(at: contents.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: [framework.path, contents.appendingPathComponent("Frameworks/Sparkle.framework").path], directory: root)
    try PropertyListSerialization.data(fromPropertyList: [
        "CFBundleExecutable": "Comet", "CFBundleIdentifier": "dev.comet.vm-helper-test", "CFBundlePackageType": "APPL"
    ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    let app = contents.deletingLastPathComponent()
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/codesign"),
        arguments: ["--force", "--sign", "-", app.path], directory: root)
    let archive = root.appendingPathComponent("helper.zip")
    try await VMConnection.archiveHelper(executable: executable, to: archive)
    let restored = root.appendingPathComponent("restored/Comet.app")
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: ["-x", "-k", archive.path, restored.path], directory: root)
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/codesign"),
        arguments: ["--verify", "--deep", "--strict", restored.path], directory: root)
    #expect(try Data(contentsOf: restored.appendingPathComponent("Contents/Info.plist")) == Data(contentsOf: contents.appendingPathComponent("Info.plist")))
    #expect(try files.destinationOfSymbolicLink(atPath: restored.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Versions/Current").path) == "B")
    #expect(try await RunnerProcess.command(restored.appendingPathComponent("Contents/MacOS/Comet"),
        arguments: ["helper works"], directory: root) == "helper works\n")
}

@Test @MainActor func installerAvailabilityRefreshesWhenDownloadFinishes() async throws {
    guard MacVirtualMachines.available else { return }
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = AppPaths(root: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Fail preparation before contacting Apple, but exercise the real download lifecycle.
    try Data().write(to: paths.runnersRoot)
    let machines = MacVirtualMachines()
    let completed = Mutex(false)
    withObservationTracking {
        #expect(!machines.hasInstaller(paths: paths))
    } onChange: {
        MainActor.assumeIsolated {
            withObservationTracking {
                _ = machines.hasInstaller(paths: paths)
            } onChange: {
                completed.withLock { $0 = true }
            }
        }
    }

    await machines.downloadInstaller(paths: paths)

    #expect(completed.withLock { $0 })
    #expect(!machines.isDownloading)
    #expect(machines.downloadMessage != nil)
    #expect(!machines.hasInstaller(paths: paths))
    try Data("fixture".utf8).write(to: MacVirtualMachines.installer(paths: paths))
    #expect(machines.hasInstaller(paths: paths))
}

@Test @MainActor func restoreDownloadReportsMeasuredProgress() async {
    var updates: [(Double?, String)] = []
    let delegate = RestoreDownloadProgress { fraction, size in updates.append((fraction, size)) }
    delegate.update(written: 25, expected: -1)
    delegate.update(written: 25, expected: 0)
    delegate.update(written: 25, expected: 100)
    delegate.update(written: 25, expected: 100)
    delegate.update(written: 50, expected: 100)
    delegate.update(written: 120, expected: 100)
    for _ in 0..<100 where updates.count < 4 { await Task.yield() }
    #expect(updates.compactMap(\.0).sorted() == [0.25, 0.5, 1])
    #expect(updates.contains { $0.0 == nil && $0.1.contains("25 bytes received") })
    #expect(updates.map(\.1).contains { $0.contains("25%") && $0.contains("100") })
}

@Test(arguments: [false, true]) @MainActor
func restoreDownloadTracksAnActualTransfer(knownSize: Bool) async throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let payload = Data(repeating: 42, count: 2 * 1024 * 1024)
    listener.newConnectionHandler = { connection in
        connection.start(queue: DispatchQueue(label: "comet-download-fixture"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
            let length = knownSize ? "Content-Length: \(payload.count)\r\n" : ""
            let headers = Data("HTTP/1.1 200 OK\r\n\(length)Connection: close\r\n\r\n".utf8)
            connection.send(content: headers + payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    listener.start(queue: DispatchQueue(label: "comet-download-listener"))
    defer { listener.cancel() }
    for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
    let port = try #require(listener.port)
    #expect(port.rawValue > 0)
    var updates: [(Double?, String)] = []
    let delegate = RestoreDownloadProgress { fraction, size in updates.append((fraction, size)) }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port.rawValue)/restore.ipsw")!, timeoutInterval: 5)
    let (file, _) = try await session.download(for: request, delegate: delegate)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try Data(contentsOf: file) == payload)
    for _ in 0..<100 where !updates.contains(where: { $0.1.contains("MB") }) { await Task.yield() }
    if knownSize {
        #expect(updates.contains { ($0.0 ?? 0) > 0 && $0.1.contains("of") })
    } else {
        #expect(updates.contains { $0.0 == nil && $0.1.contains("MB received") })
    }
}

@Test @MainActor func cancellingRestoreDownloadStopsTheNetworkTask() async throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { connection in
        connection.start(queue: DispatchQueue(label: "comet-cancel-fixture"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Length: 10485760\r\n\r\n".utf8)
            connection.send(content: headers + Data(repeating: 42, count: 1_048_576), completion: .contentProcessed { _ in
                // Keep the response open so only cancellation can finish the client's task.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
            })
        }
    }
    listener.start(queue: DispatchQueue(label: "comet-cancel-listener"))
    defer { listener.cancel() }
    for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
    let port = try #require(listener.port)
    var receivedData = false
    let delegate = RestoreDownloadProgress { fraction, _ in receivedData = (fraction ?? 0) > 0 }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port.rawValue)/restore.ipsw")!, timeoutInterval: 5)
    let download = Task { try await session.download(for: request, delegate: delegate) }
    defer { download.cancel() }
    for _ in 0..<100 where !receivedData { try await Task.sleep(for: .milliseconds(10)) }
    #expect(receivedData)
    download.cancel()
    do {
        let (file, _) = try await download.value
        try? FileManager.default.removeItem(at: file)
        Issue.record("A stopped download must not complete successfully")
    } catch {
        #expect((error as? URLError)?.code == .cancelled || error is CancellationError)
    }
    #expect(await session.allTasks.isEmpty)
}

@Test func executionDefaultsToHostAndRoundTrips() throws {
    let legacy = #"{"id":"472574D8-CA3E-43D0-A955-67BEA58F8323","repository":"owner/repo","name":"Mac","label":"runner-test","githubID":21}"#
    let runner = try JSONDecoder().decode(RunnerCore.Runner.self, from: Data(legacy.utf8))
    #expect(runner.execution == .host)
    let vm = try RunnerCore.Runner(repository: runner.repository, name: runner.name, label: runner.label, execution: .macOSVM)
    #expect(try JSONDecoder().decode(RunnerCore.Runner.self, from: JSONEncoder().encode(vm)) == vm)
    #expect(vm.workflow == runner.workflow)
    let damaged = legacy.dropLast() + #", "execution":"unrecognised"}"#
    #expect(throws: (any Error).self) { try JSONDecoder().decode(RunnerCore.Runner.self, from: Data(damaged.utf8)) }
}

@Test func guestAddressMatchingRejectsUnsafeAddresses() throws {
    let leases = "{\nip_address=192.168.64.2\nhw_address=1,6:17:0:1:75:59\n}"
    #expect(VMConnection.address(for: "06:17:00:01:75:59", leases: leases) == "192.168.64.2")
    #expect(VMConnection.address(for: "01:02:03:04:05:06", leases: leases) == nil)
    for invalid in ["", "-oProxyCommand=id", "localhost", "1.2.3.4;id", "256.1.1.1", "1.2.3", "::1", "１.2.3.4"] {
        #expect(!VMConnection.validAddress(invalid))
        #expect(throws: RunnerError.self) { try VMConnection(address: invalid, directory: .temporaryDirectory, password: "fixture") }
    }
}

@Test @MainActor func missingInstallerNeverStartsADownloadOrCreatesADisk() async throws {
    guard MacVirtualMachines.available else { return }
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = AppPaths(root: directory)
    try paths.prepare()
    let runner = try RunnerCore.Runner(repository: "fixture/repo", name: "Mac", label: "test", execution: .macOSVM)
    let machines = MacVirtualMachines()
    do {
        _ = try await machines.start(runner, paths: paths) { _ in }
        Issue.record("VM setup should require an explicit installer download")
    } catch {
        #expect(error.localizedDescription.contains("Download macOS"))
    }
    #expect(!machines.isDownloading)
    #expect(machines.downloadMessage == nil)
    #expect(!FileManager.default.fileExists(atPath: paths.directory(runner.id).path))
    #expect(!machines.hasInstaller(paths: paths))
    try Data("fixture".utf8).write(to: MacVirtualMachines.installer(paths: paths))
    #expect(machines.hasInstaller(paths: paths))
    await machines.finishCancellingDownload()
}

@Test func remoteShellArgumentsAreQuotedLiterally() async throws {
    let value = "spaces 'quotes' \n$(echo unsafe); `id`"
    let output = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf %s " + VMConnection.quote(value)], directory: .temporaryDirectory)
    #expect(output == value)
}

@Test func guestSnapshotRefusesUnknownProcessesAndPreservesRegistration() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"agentId":123}"#.utf8).write(to: directory.appendingPathComponent(".runner"))
    try Data("ghp_fixture123\noutput".utf8).write(to: directory.appendingPathComponent("runner.log"))
    let snapshot = try await VMSnapshot.read(directory)
    #expect(!snapshot.running)
    #expect(snapshot.registrationID == 123)
    #expect(!snapshot.log.contains("ghp_fixture123"))
    let fd = open(directory.appendingPathComponent(".host.lock").path, O_CREAT | O_RDWR, 0o600)
    defer { close(fd) }
    #expect(fd >= 0)
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    await #expect(throws: RunnerError.self) { try await VMSnapshot.read(directory) }
}

@Test @MainActor func interruptedExecutionChangeCannotStartStaleRegistration() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = AppPaths(root: directory)
    let runner = try RunnerCore.Runner(repository: "owner/repo", name: "Mac", label: "test", githubID: 21)
    try paths.save([runner])
    try FileManager.default.createDirectory(at: paths.directory(runner.id), withIntermediateDirectories: true)
    try Data().write(to: paths.directory(runner.id).appendingPathComponent("execution-change"))
    let store = RunnerStore(paths: paths, restore: { false })
    await store.load()
    await store.start(runner)
    #expect(store.state(runner) == .attention)
    #expect(store.issues[runner.id]?.contains("interrupted") == true)
    #expect(!store.hasHost(runner))
    #expect(await store.shutdown())
}

private final class ExecutionProtocol: URLProtocol, @unchecked Sendable {
    static let state = Mutex((status: 204, deletes: 0))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.state.withLock { state in
            if request.httpMethod == "DELETE" { state.deletes += 1; return state.status }
            return 200
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: request.httpMethod == "DELETE" ? Data() : Data(#"{"runners":[{"id":21,"name":"Mac","status":"offline","busy":false}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct ExecutionChangeTests {
    @Test func installationProgressBarTracksTheReportedFraction() async throws {
        _ = NSApplication.shared
        let runner = try RunnerCore.Runner(repository: "fixture/repository", name: "Mac-fixture", label: "runner-fixture", execution: .macOSVM)
        let store = RunnerStore(paths: AppPaths(root: .temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        store.runners = [runner]
        store.selectedID = runner.id
        store.issues[runner.id] = "Installing macOS…"
        store.operations.insert(runner.id)
        store.virtualMachines.installationProgress[runner.id] = 0.25
        let view = NSHostingView(rootView: MainWindow(store: store)
            .environment(\.colorScheme, .light).frame(width: 940, height: 650).background(Color.white))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 940, height: 650),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        func descendants(_ node: NSView) -> [NSView] {
            [node] + node.subviews.flatMap { descendants($0) }
        }
        func installationBar() throws -> NSProgressIndicator {
            try #require(descendants(view).compactMap { $0 as? NSProgressIndicator }.first { $0.style == .bar })
        }
        func snapshot() throws -> Data {
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        try await Task.sleep(for: .milliseconds(50))
        let first = try snapshot()
        let quarter = try installationBar()
        #expect(!quarter.isIndeterminate)
        #expect(abs(quarter.doubleValue / quarter.maxValue - 0.25) < 0.001)

        store.virtualMachines.installationProgress[runner.id] = 0.75
        try await Task.sleep(for: .milliseconds(50))
        let second = try snapshot()
        let threeQuarters = try installationBar()
        #expect(!threeQuarters.isIndeterminate)
        #expect(abs(threeQuarters.doubleValue / threeQuarters.maxValue - 0.75) < 0.001)
        #expect(first != second)
        #expect(store.issues[runner.id] == "Installing macOS…")
    }

    @Test(arguments: RunnerExecution.allCases)
    func executionConfigurationFitsTheExistingWindow(execution: RunnerExecution) async throws {
        _ = NSApplication.shared
        let runner = try RunnerCore.Runner(repository: "fixture/repository", name: "Mac-fixture", label: "runner-fixture", execution: execution)
        let store = RunnerStore()
        store.runners = [runner]
        let screen = ConfigurationView(store: store, runner: runner).frame(width: 680, height: 450).background(.background)
        let view = NSHostingView(rootView: screen)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 680, height: 450), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(50))
        view.layoutSubtreeIfNeeded()
        let minimum = NSHostingController(rootView: screen).sizeThatFits(in: CGSize(width: 680, height: 450))
        #expect(minimum.width <= 680 && minimum.height <= 450)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL.temporaryDirectory.appendingPathComponent("comet-configuration-\(execution.rawValue).png"))
        func descendants(_ node: NSView) -> [NSView] {
            [node] + node.subviews.flatMap { descendants($0) }
        }
        let scrolls = descendants(view).compactMap { $0 as? NSScrollView }
        #expect(scrolls.count == 1)
        let scroll = try #require(scrolls.first)
        let document = try #require(scroll.documentView)
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(50))
        view.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.maxY >= document.frame.maxY - 1)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scrolled = try #require(bitmap.representation(using: .png, properties: [:]))
        try scrolled.write(to: URL.temporaryDirectory.appendingPathComponent("comet-configuration-\(execution.rawValue)-scrolled.png"))
    }

    @Test func changesOnlyStoppedRunnersAndKeepsTheOldWorkspace() async throws {
        guard MacVirtualMachines.available else { return }
        ExecutionProtocol.state.withLock { $0 = (204, 0) }
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(root: directory)
        let runner = try RunnerCore.Runner(repository: "owner/repo", name: "Mac", label: "test", githubID: 21, runAutomatically: true)
        try paths.save([runner])
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [ExecutionProtocol.self]
        let github = GitHub(session: URLSession(configuration: session), token: "fixture-token")
        let store = RunnerStore(github: github, paths: paths, restore: { false })
        await store.load()
        #expect(await store.shutdown())
        store.operations.insert(runner.id)
        await store.setExecution(.macOSVM, for: runner)
        #expect(store.runners == [runner])
        store.operations.remove(runner.id)
        try FileManager.default.createDirectory(at: paths.directory(runner.id), withIntermediateDirectories: true)
        let workspace = paths.directory(runner.id).appendingPathComponent("keep.txt")
        try Data("preserved".utf8).write(to: workspace)
        let fd = open(paths.directory(runner.id).appendingPathComponent(".host.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        await store.setExecution(.macOSVM, for: runner)
        #expect(store.runners == [runner])
        flock(fd, LOCK_UN)
        ExecutionProtocol.state.withLock { $0.status = 403 }
        await store.setExecution(.macOSVM, for: runner)
        #expect(store.runners == [runner])
        #expect(try paths.load() == [runner])
        #expect(store.error != nil)
        ExecutionProtocol.state.withLock { $0.status = 204 }
        await store.setExecution(.macOSVM, for: runner)
        let changed = try #require(store.runners.first)
        #expect(changed.execution == .macOSVM)
        #expect(changed.id != runner.id)
        #expect(changed.githubID == nil)
        #expect(changed.workflow == runner.workflow)
        #expect(changed.name == runner.name)
        #expect(changed.runAutomatically)
        #expect(store.selectedID == changed.id)
        #expect(try paths.load() == [changed])
        #expect(try String(contentsOf: workspace, encoding: .utf8) == "preserved")
        #expect(ExecutionProtocol.state.withLock { $0.deletes } == 2)
    }
}
