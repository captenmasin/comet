import Foundation
import Synchronization
import Testing
@testable import RunnerCore
@testable import Runner

private final class IdleQueueProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = Mutex<[String: IdleQueue]>([:])
    private var fixture: IdleQueue?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        fixture = Self.fixtures.withLock { $0[request.value(forHTTPHeaderField: "X-Idle-Test") ?? ""] }
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let held = fixture.state.withLock {
            $0.requests += 1
            if $0.hold { $0.pending.append(self) }
            return $0.hold
        }
        if !held { finish() }
    }
    override func stopLoading() {
        fixture?.state.withLock { $0.pending.removeAll { $0 === self } }
    }
    func finish() {
        guard let fixture else { return }
        do {
            let data: Data
            if request.url!.path == "/user" {
                data = Data(#"{"login":"fixture"}"#.utf8)
            } else if request.url!.path.hasSuffix("/runs") {
                let malformed = fixture.state.withLock { $0.malformed }
                if malformed { data = Data("{}".utf8) }
                else {
                    let status = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "status" }?.value
                    let runs: [[String: Any]] = status == "queued" ? [[
                        "id": 1, "name": "CI", "head_sha": "abcdef0", "status": "queued",
                        "html_url": "https://github.com/fixture/repo/actions/runs/1",
                        "created_at": "2026-10-22T12:00:00Z", "updated_at": "2026-10-22T12:00:00Z"
                    ]] : []
                    data = try JSONSerialization.data(withJSONObject: ["total_count": runs.count, "workflow_runs": runs])
                }
            } else if request.url!.path.hasSuffix("/jobs") {
                data = fixture.state.withLock { $0.jobs }
            } else {
                data = try JSONSerialization.data(withJSONObject: ["runners": [
                    ["id": 21, "name": "Mac", "status": "online", "busy": false],
                    ["id": 22, "name": "Other", "status": "online", "busy": false]
                ]])
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

private final class IdleQueue: Sendable {
    struct State {
        var jobs = Data("{\"jobs\":[]}".utf8)
        var malformed = false
        var hold = false
        var pending: [IdleQueueProtocol] = []
        var requests = 0
    }
    let id = UUID().uuidString
    let state = Mutex(State())

    func github() -> GitHub {
        IdleQueueProtocol.fixtures.withLock { $0[id] = self }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdleQueueProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Idle-Test": id]
        return GitHub(session: URLSession(configuration: configuration), token: "stub-token")
    }
    func enqueue(labels: [String]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["jobs": [[
            "id": 7, "name": "Build", "status": "queued", "labels": labels,
            "html_url": "https://github.com/fixture/repo/actions/jobs/7"
        ]]])
        state.withLock { $0.jobs = data }
    }
    func release() {
        let pending = state.withLock {
            $0.hold = false
            let pending = $0.pending
            $0.pending = []
            return pending
        }
        for request in pending { request.finish() }
    }
    func close() {
        _ = IdleQueueProtocol.fixtures.withLock { $0.removeValue(forKey: id) }
        release()
    }
}

private final class IdleClock: Sendable {
    let date = Mutex(Date(timeIntervalSince1970: 1_000))
    func now() -> Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

@MainActor private final class IdleVM {
    var running: Set<UUID> = []
    var snapshots: [UUID: VMSnapshot] = [:]
    var snapshotFails = false
    var prepareFails = false
    var stopFails = false
    var prepared: [UUID] = []
    var launched: [UUID] = []
    var stopped: [UUID] = []

    var runtime: VMRuntime {
        VMRuntime(isRunning: { self.running.contains($0) }, prepare: { runner, _ in
            self.prepared.append(runner.id)
            self.running.insert(runner.id)
            self.snapshots[runner.id] = VMSnapshot(running: false, registrationID: runner.githubID ?? 21, log: "")
            if self.prepareFails { throw RunnerError.message("Guest preparation failed") }
            return runner.githubID ?? 21
        }, snapshot: { id in
            if self.snapshotFails { throw RunnerError.message("SSH unavailable") }
            return self.snapshots[id] ?? VMSnapshot(running: false, registrationID: 21, log: "", exitCode: 0)
        }, launch: {
            self.launched.append($0)
            self.snapshots[$0] = VMSnapshot(running: true, registrationID: 21, log: "")
        }, stop: {
            self.stopped.append($0)
            if self.stopFails { throw RunnerError.message("macOS has not shut down") }
            self.running.remove($0)
        })
    }
}

@MainActor private final class IdleHarness {
    let paths = AppPaths(root: .temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let queue = IdleQueue()
    let clock = IdleClock()
    let vm = IdleVM()
    let store: RunnerStore

    init(_ runners: [Runner]) throws {
        store = RunnerStore(github: queue.github(), paths: paths, readLog: { _ in "" }, restore: { false },
                            vmRuntime: vm.runtime, now: clock.now)
        try paths.save(runners)
        for runner in runners {
            try FileManager.default.createDirectory(at: paths.directory(runner.id), withIntermediateDirectories: true)
        }
        store.runners = runners
        store.signedIn = true
    }
    func close() {
        queue.close()
        try? FileManager.default.removeItem(at: paths.root)
    }
}

private func idleRunner(label: String = "runner-idle", githubID: Int = 21, watching: Bool = true) throws -> Runner {
    try Runner(repository: "fixture/repo", name: "Mac", label: label, githubID: githubID,
               execution: .macOSVM, watchForJobs: watching)
}

@Test(arguments: RunnerExecution.allCases, [(false, false), (false, true), (true, false), (true, true)]) @MainActor
func launchStartsOnlyOptedInRunnersWithRestoredCredentials(execution: RunnerExecution, preferences: (Bool, Bool)) async throws {
    let (enabled, restored) = preferences
    let runner = try Runner(repository: "fixture/repo", name: "Mac", label: "test", execution: execution, runAutomatically: enabled)
    let paths = AppPaths(root: .temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try paths.save([runner])
    try FileManager.default.createDirectory(at: paths.directory(runner.id), withIntermediateDirectories: true)
    // Prevent real provisioning while verifying that launch reaches the shared start path.
    try Data().write(to: paths.directory(runner.id).appendingPathComponent("execution-change"))
    let queue = IdleQueue()
    defer { queue.close() }
    let store = RunnerStore(github: queue.github(), paths: paths, restore: { restored }, dedicatedSnapshot: { _ in
        VMSnapshot(running: false, registrationID: nil, log: "")
    })
    await store.load()
    #expect(store.issues[runner.id]?.contains("execution change was interrupted") == (enabled && restored ? true : nil))
    #expect(try paths.load() == [runner])
    #expect(await store.shutdown())
}

@Test @MainActor func launchPreparesAutomaticVMsAndKeepsExistingQueueWatchersAsleep() async throws {
    let automatic = try Runner(repository: "fixture/repo", name: "Mac", label: "test", execution: .macOSVM, runAutomatically: true)
    let watching = try Runner(repository: "fixture/repo", name: "Other", label: "other", execution: .macOSVM,
                              watchForJobs: true, runAutomatically: true)
    let stopped = try idleRunner(watching: false)
    let harness = try IdleHarness([automatic, watching, stopped])
    defer { harness.close() }
    let store = RunnerStore(github: harness.queue.github(), paths: harness.paths, restore: { true }, vmRuntime: harness.vm.runtime)
    await store.load()
    #expect(harness.vm.prepared == [automatic.id])
    #expect(store.runners.first?.watchForJobs == true)
    #expect(store.runners.first?.runAutomatically == true)
    #expect(!store.hasHost(watching))
    #expect(!store.hasHost(stopped))
    #expect(await store.shutdown())
    #expect(try harness.paths.load().first?.runAutomatically == true)
    let relaunched = RunnerStore(github: harness.queue.github(), paths: harness.paths, restore: { true }, vmRuntime: harness.vm.runtime)
    await relaunched.load()
    #expect(harness.vm.prepared == [automatic.id])
    #expect(await relaunched.shutdown())
}

@Test(arguments: [59.0, 60.0]) @MainActor
func idleVMStopsOnlyAfterSixtySeconds(seconds: Double) async throws {
    let runner = try idleRunner()
    let harness = try IdleHarness([runner])
    defer { harness.close() }
    harness.vm.running.insert(runner.id)
    await harness.store.refreshVMs()
    harness.clock.advance(seconds)
    await harness.store.refreshVMs()
    #expect(harness.vm.stopped == (seconds == 60 ? [runner.id] : []))
    #expect(harness.store.runners.first?.watchForJobs == true)
    #expect(try harness.paths.load().first?.watchForJobs == true)
    if seconds == 60 {
        #expect(harness.store.state(runner) == .sleeping)
        #expect(harness.store.isEnabled(runner))
    }
}

@Test @MainActor func queuedMatchingJobWakesAnUnselectedVMOnly() async throws {
    let a = try idleRunner(label: "runner-a")
    let b = try idleRunner(label: "runner-b", githubID: 22)
    let selected = try Runner(repository: "fixture/other", name: "Host", label: "host")
    let harness = try IdleHarness([selected, a, b])
    defer { harness.close() }
    harness.store.selectedID = selected.id
    try harness.queue.enqueue(labels: ["SELF-HOSTED", "macOS", "ARM64", "RUNNER-B"])
    await harness.store.refreshVMs()
    #expect(harness.vm.prepared == [b.id])
    #expect(harness.vm.launched == [b.id])
    #expect(!harness.vm.running.contains(a.id))
    harness.clock.advance(30)
    await harness.store.refreshVMs()
    #expect(harness.vm.prepared == [b.id])
    #expect(harness.vm.launched == [b.id])
}

@Test @MainActor func oneQueuedJobDoesNotWakeTwoCompatibleVMs() async throws {
    let a = try idleRunner(label: "runner-a")
    let b = try idleRunner(label: "runner-b", githubID: 22)
    let harness = try IdleHarness([a, b])
    defer { harness.close() }
    try harness.queue.enqueue(labels: ["self-hosted", "macOS", "ARM64"])
    await harness.store.refreshVMs()
    #expect(harness.vm.prepared.count == 1)
    #expect(harness.vm.launched == harness.vm.prepared)
    harness.clock.advance(30)
    await harness.store.refreshVMs()
    #expect(harness.vm.prepared.count == 1)
    #expect(harness.vm.launched.count == 1)
}

@Test(arguments: [true, false]) @MainActor
func uncertainOrBusyVMNeverPowersOff(snapshotFails: Bool) async throws {
    let runner = try idleRunner()
    let harness = try IdleHarness([runner])
    defer { harness.close() }
    harness.vm.running.insert(runner.id)
    harness.vm.snapshots[runner.id] = VMSnapshot(running: true, registrationID: 21, log: "")
    harness.vm.snapshotFails = snapshotFails
    await harness.store.refreshVMs()
    harness.clock.advance(600)
    await harness.store.refreshVMs()
    #expect(harness.vm.stopped.isEmpty)
    #expect(harness.vm.launched.isEmpty)
    #expect(harness.vm.running.contains(runner.id))
}

@Test @MainActor func finishingAJobStartsAFreshIdleGracePeriod() async throws {
    let runner = try idleRunner()
    let harness = try IdleHarness([runner])
    defer { harness.close() }
    harness.vm.running.insert(runner.id)
    await harness.store.refreshVMs()
    harness.clock.advance(30)
    harness.vm.snapshots[runner.id] = VMSnapshot(running: true, registrationID: 21, log: "")
    await harness.store.refreshVMs()
    harness.clock.advance(60)
    harness.vm.snapshots[runner.id] = VMSnapshot(running: false, registrationID: 21, log: "", exitCode: 0)
    await harness.store.refreshVMs()
    #expect(harness.vm.stopped.isEmpty)
    harness.clock.advance(30)
    await harness.store.refreshVMs()
    #expect(harness.vm.stopped.isEmpty)
    harness.clock.advance(30)
    await harness.store.refreshVMs()
    #expect(harness.vm.stopped == [runner.id])
}

@Test @MainActor func missingExitStatusAfterListeningRequiresAttention() async throws {
    let runner = try idleRunner()
    let harness = try IdleHarness([runner])
    defer { harness.close() }
    try harness.queue.enqueue(labels: ["self-hosted", runner.label])
    await harness.store.refreshVMs()
    try #require(harness.vm.launched == [runner.id])
    harness.vm.snapshots[runner.id] = VMSnapshot(running: false, registrationID: 21, log: "")
    harness.clock.advance(60)
    await harness.store.refreshVMs()
    #expect(harness.store.state(runner) == .attention)
    #expect(harness.vm.stopped.isEmpty)
    #expect(harness.vm.launched == [runner.id])
}

@Test @MainActor func failedPreparationCannotLaunchAListenerInThePoweredOnVM() async throws {
    let runner = try idleRunner()
    let harness = try IdleHarness([runner])
    defer { harness.close() }
    harness.vm.prepareFails = true
    try harness.queue.enqueue(labels: ["self-hosted", runner.label])
    await harness.store.refreshVMs()
    #expect(harness.vm.running.contains(runner.id))
    #expect(harness.vm.launched.isEmpty)
    #expect(harness.store.issues[runner.id]?.contains("Guest preparation failed") == true)
    // A previous boot may have left a successful exit marker before tool preparation failed.
    harness.vm.snapshots[runner.id] = VMSnapshot(running: false, registrationID: 21, log: "", exitCode: 0)
    harness.clock.advance(30)
    await harness.store.refreshVMs()
    #expect(harness.vm.launched.isEmpty)
}

@Test @MainActor func failedListenerExitRequiresAttentionAndPreservesVM() async throws {
    let runner = try idleRunner()
    let harness = try IdleHarness([runner])
    defer { harness.close() }
    harness.vm.running.insert(runner.id)
    harness.vm.snapshots[runner.id] = VMSnapshot(running: false, registrationID: 21, log: "failed", exitCode: 1)
    await harness.store.refreshVMs()
    harness.clock.advance(600)
    await harness.store.refreshVMs()
    #expect(harness.vm.stopped.isEmpty)
    #expect(harness.store.state(runner) == .attention)
    #expect(harness.store.issues[runner.id] != nil)
    try harness.queue.enqueue(labels: ["self-hosted", runner.label])
    harness.clock.advance(30)
    await harness.store.refreshVMs()
    #expect(harness.vm.launched.isEmpty)
    await harness.store.stop(runner)
    await harness.store.start(runner)
    #expect(harness.vm.prepared == [runner.id])
    #expect(harness.vm.snapshots[runner.id]?.exitCode == nil)
    #expect(harness.store.state(runner) == .ready)
    #expect(try harness.paths.load().first?.watchForJobs == true)
}

@Test @MainActor func malformedQueueResponseCannotPowerOffAnIdleVM() async throws {
    let runner = try idleRunner()
    let harness = try IdleHarness([runner])
    defer { harness.close() }
    harness.vm.running.insert(runner.id)
    await harness.store.refreshVMs()
    harness.clock.advance(60)
    harness.queue.state.withLock { $0.malformed = true }
    await harness.store.refreshVMs()
    #expect(harness.vm.stopped.isEmpty)
    #expect(harness.vm.running.contains(runner.id))
    #expect(harness.store.issues[runner.id] != nil)
}

@Test @MainActor func manualStopWhileSleepingPersistsAndCancelsAnInFlightWake() async throws {
    let runner = try idleRunner()
    let harness = try IdleHarness([runner])
    defer { harness.close() }
    try harness.queue.enqueue(labels: ["self-hosted", runner.label])
    harness.queue.state.withLock { $0.hold = true }
    let refresh = Task { await harness.store.refreshVMs() }
    for _ in 0..<400 {
        if harness.queue.state.withLock({ !$0.pending.isEmpty }) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(harness.queue.state.withLock { !$0.pending.isEmpty })
    await harness.store.stop(runner)
    harness.queue.release()
    _ = await refresh.value
    #expect(harness.vm.prepared.isEmpty)
    #expect(harness.vm.launched.isEmpty)
    #expect(harness.store.runners.first?.watchForJobs == false)
    #expect(try harness.paths.load().first?.watchForJobs == false)
    #expect(!harness.store.isEnabled(runner))
    #expect(harness.store.state(runner) == .stopped)
}

@Test @MainActor func manualStartEnablesWatchingWithoutOpeningAnIdleListener() async throws {
    let runner = try idleRunner(watching: false)
    let harness = try IdleHarness([runner])
    defer { harness.close() }
    await harness.store.start(runner)
    #expect(harness.vm.prepared == [runner.id])
    #expect(harness.vm.launched.isEmpty)
    #expect(harness.store.runners.first?.watchForJobs == true)
    #expect(try harness.paths.load().first?.watchForJobs == true)
}

@Test @MainActor func quittingPreservesWatchingButStopsTheVMAndFutureWakes() async throws {
    let runner = try idleRunner()
    let harness = try IdleHarness([runner])
    defer { harness.close() }
    harness.vm.running.insert(runner.id)
    #expect(await harness.store.shutdown())
    #expect(harness.vm.stopped == [runner.id])
    #expect(try harness.paths.load().first?.watchForJobs == true)
    try harness.queue.enqueue(labels: ["self-hosted", runner.label])
    harness.clock.advance(60)
    await harness.store.refreshVMs()
    #expect(harness.vm.prepared.isEmpty)
    #expect(harness.vm.launched.isEmpty)
}

@Test @MainActor func failedQuitNamesTheRunnerAndCanBeRetried() async throws {
    let runner = try idleRunner()
    let other = try idleRunner(label: "other", githubID: 22)
    let harness = try IdleHarness([runner, other])
    defer { harness.close() }
    harness.vm.running.insert(runner.id)
    harness.vm.stopFails = true
    harness.store.selectedID = other.id

    #expect(await !harness.store.shutdown())
    #expect(harness.store.selectedID == runner.id)
    #expect(harness.store.error?.contains("\(runner.name) (\(runner.repository))") == true)
    #expect(harness.store.error?.contains("macOS has not shut down") == true)
    #expect(harness.store.isEnabled(runner))
    #expect(harness.store.runners.first?.watchForJobs == true)

    harness.vm.stopFails = false
    #expect(await harness.store.shutdown())
    #expect(!harness.vm.running.contains(runner.id))
    #expect(harness.vm.stopped == [runner.id, runner.id])
}

@Test @MainActor func anUnexpectedVMStopReleasesItsQueuedJobClaim() async throws {
    let runner = try idleRunner()
    let harness = try IdleHarness([runner])
    defer { harness.close() }
    try harness.queue.enqueue(labels: [runner.label])
    await harness.store.refreshVMs()
    #expect(harness.vm.launched == [runner.id])
    harness.vm.running.remove(runner.id)
    harness.clock.advance(30)
    await harness.store.refreshVMs()
    #expect(harness.vm.prepared == [runner.id, runner.id])
    #expect(harness.vm.launched == [runner.id, runner.id])
}

@Test func olderRunnerConfigurationDoesNotEnableAutomaticVMStarts() throws {
    let original = try idleRunner(watching: true)
    var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    fields.removeValue(forKey: "watchForJobs")
    let decoded = try JSONDecoder().decode(Runner.self, from: JSONSerialization.data(withJSONObject: fields))
    #expect(!decoded.watchForJobs)
}
