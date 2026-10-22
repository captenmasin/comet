import Foundation
import Synchronization
import Testing
@testable import RunnerCore
@testable import Runner

private struct Reply {
    let data: Data
    var status = 200
    var headers: [String: String] = [:]

    init(_ payload: [String: Any], status: Int = 200, headers: [String: String] = [:]) throws {
        data = try JSONSerialization.data(withJSONObject: payload)
        self.status = status
        self.headers = headers
    }
}

private final class RefreshProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = Mutex<[String: RefreshFixture]>([:])
    private var fixture: RefreshFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        fixture = Self.fixtures.withLock { $0[request.value(forHTTPHeaderField: "X-Refresh-Test") ?? ""] }
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        fixture.receive(self)
    }
    override func stopLoading() { fixture?.cancel(self) }
    func finish() {
        do {
            guard let fixture else { return }
            let reply = try fixture.reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

private final class RefreshFixture: Sendable {
    struct State {
        var requests: [URLRequest] = []
        var pending: [RefreshProtocol] = []
        var peak = 0
        var cancellations = 0
    }
    let id = UUID().uuidString
    let state = Mutex(State())
    let hold: @Sendable (URLRequest) -> Bool
    let reply: @Sendable (URLRequest) throws -> Reply

    init(hold: @escaping @Sendable (URLRequest) -> Bool = { _ in false },
         reply: @escaping @Sendable (URLRequest) throws -> Reply) {
        self.hold = hold
        self.reply = reply
    }
    func github() -> GitHub {
        RefreshProtocol.fixtures.withLock { $0[id] = self }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Refresh-Test": id]
        return GitHub(session: URLSession(configuration: configuration), token: "stub-token")
    }
    func receive(_ request: RefreshProtocol) {
        let held = hold(request.request)
        state.withLock {
            $0.requests.append(request.request)
            if held { $0.pending.append(request); $0.peak = max($0.peak, $0.pending.count) }
        }
        if !held { request.finish() }
    }
    func cancel(_ request: RefreshProtocol) {
        state.withLock {
            $0.pending.removeAll { $0 === request }
            $0.cancellations += 1
        }
    }
    func releaseLast() { state.withLock { $0.pending.popLast() }?.finish() }
    func releaseFirst() { state.withLock { $0.pending.removeFirst() }.finish() }
    var pending: Int { state.withLock { $0.pending.count } }
    var requests: [URLRequest] { state.withLock { $0.requests } }
    func close() {
        _ = RefreshProtocol.fixtures.withLock { $0.removeValue(forKey: id) }
        let pending = state.withLock { let pending = $0.pending; $0.pending = []; return pending }
        for request in pending { request.client?.urlProtocol(request, didFailWithError: URLError(.cancelled)) }
    }
}

private func runs(_ count: Int = 1, revision: String = "original", status: String = "completed") -> [String: Any] {
    ["workflow_runs": (1...count).map { id in [
        "id": id, "name": "CI", "head_sha": "abcdef0", "status": status,
        "html_url": "https://github.com/stub/repo/actions/runs/\(id)",
        "created_at": "2026-10-21T10:00:00Z", "updated_at": revision
    ] as [String: Any] }]
}

@Test(arguments: [204, 403]) @MainActor
func removingARunnerPreservesItsWorkspaceAndRequiresDeregistration(status: Int) async throws {
    let fixture = RefreshFixture { request in
        if request.httpMethod == "DELETE" { return try Reply([:], status: status) }
        return try Reply(["runners": [["id": 21, "name": "Mac", "status": "offline", "busy": false]]])
    }
    defer { fixture.close() }
    let paths = AppPaths(root: .temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let runner = try Runner(repository: "fixture/repo", name: "Mac", label: "test", githubID: 21)
    let other = try Runner(repository: "fixture/other", name: "Other", label: "other")
    try paths.save([runner, other])
    let directory = paths.directory(runner.id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let workspace = directory.appendingPathComponent("keep.txt")
    try Data("checkout".utf8).write(to: workspace)
    let store = RunnerStore(github: fixture.github(), paths: paths, restore: { false })
    await store.load()
    #expect(await store.shutdown())

    store.operations.insert(runner.id)
    await store.remove(runner)
    #expect(store.runners == [runner, other])
    store.operations.remove(runner.id)
    await store.remove(runner)

    let expected = status == 204 ? [other] : [runner, other]
    #expect(store.runners == expected)
    #expect(try paths.load() == expected)
    #expect(store.selectedID == (status == 204 ? other.id : runner.id))
    #expect((store.error != nil) == (status != 204))
    #expect(try String(contentsOf: workspace, encoding: .utf8) == "checkout")
    if status == 204 {
        let requests = fixture.requests.count
        await store.remove(runner)
        #expect(fixture.requests.count == requests)
    }
}

private func job(_ id: Int, runner: Int = 21) -> [String: Any] {
    ["id": id, "name": "Build", "status": "completed", "conclusion": "success", "runner_id": runner,
     "html_url": "https://github.com/stub/repo/actions/jobs/\(id)"]
}

@Test(arguments: [false, true]) @MainActor
func retryConnectionRestartsOfflineRunnerAndPreservesWatch(stopFails: Bool) async throws {
    let fixture = RefreshFixture { _ in
        try Reply(["runners": [["id": 21, "name": "Mac", "status": "offline", "busy": false]]])
    }
    defer { fixture.close() }
    let paths = AppPaths(root: .temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let runner = try Runner(repository: "stub/repo", name: "Mac", label: "test", githubID: 21,
                            execution: .macOSVM, watchForJobs: true)
    try paths.save([runner])
    var running = true
    var events: [String] = []
    let runtime = VMRuntime(isRunning: { _ in running }, prepare: { _, _ in
        events.append("start")
        running = true
        return 21
    }, snapshot: { _ in VMSnapshot(running: true, registrationID: 21, log: "") }, launch: { _ in
        Issue.record("Retry should let queue watching launch the guest listener")
    }, stop: { _ in
        events.append("stop")
        if stopFails { throw RunnerError.message("fixture stop failed") }
        running = false
    })
    let store = RunnerStore(github: fixture.github(), paths: paths, vmRuntime: runtime)
    store.runners = [runner]
    store.states[runner.id] = .reconnecting
    await store.retryConnection(runner)
    #expect(events == (stopFails ? ["stop"] : ["stop", "start"]))
    #expect(store.state(runner) == (stopFails ? .attention : .ready))
    #expect(store.issues[runner.id] == (stopFails ? "fixture stop failed" : nil))
    #expect(store.runners.first?.watchForJobs == true)
    #expect(try paths.load().first?.watchForJobs == true)
    #expect(store.operations.isEmpty)
}

@Test(arguments: [false, true]) @MainActor
func retryConnectionChecksDuringPollingAndDoesNotRestartOnlineOrBusyRunner(busy: Bool) async throws {
    let fixture = RefreshFixture(hold: { _ in true }) { _ in
        try Reply(["runners": [["id": 21, "name": "Mac", "status": busy ? "offline" : "online", "busy": busy]]])
    }
    defer { fixture.close() }
    let paths = AppPaths(root: .temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let runner = try Runner(repository: "stub/repo", name: "Mac", label: "test", githubID: 21, execution: .dedicatedUser)
    let store = RunnerStore(github: fixture.github(), paths: paths, readLog: { _ in "" }, dedicatedSnapshot: { _ in
        VMSnapshot(running: true, registrationID: 21, log: "")
    })
    store.runners = [runner]
    let polling = Task { await store.refreshStates() }
    try await waitFor { fixture.pending == 1 }
    let retry = Task { await store.retryConnection(runner) }
    try await waitFor { fixture.pending == 2 }
    #expect(store.operations.contains(runner.id))
    #expect(store.issues[runner.id] == "Checking connection…")
    await store.retryConnection(runner)
    #expect(fixture.requests.count == 2)
    fixture.releaseFirst()
    await polling.value
    #expect(store.issues[runner.id] == "Checking connection…")
    fixture.releaseLast()
    await retry.value
    #expect(store.state(runner) == (busy ? .busy : .ready))
    #expect(store.operations.isEmpty)
}

@Test(arguments: [200, 401]) @MainActor
func retryConnectionPreservesRunnerWhenRegistrationCannotBeVerified(status: Int) async throws {
    let fixture = RefreshFixture { _ in try Reply(["runners": []], status: status) }
    defer { fixture.close() }
    let runner = try Runner(repository: "stub/repo", name: "Mac", label: "test", githubID: 21, execution: .macOSVM)
    let runtime = VMRuntime(isRunning: { _ in true }, prepare: { _, _ in
        Issue.record("Must not start an unverified registration")
        return 21
    }, snapshot: { _ in VMSnapshot(running: true, registrationID: 21, log: "") }, launch: { _ in }, stop: { _ in
        Issue.record("Must not stop an unverified registration")
    })
    let store = RunnerStore(github: fixture.github(), vmRuntime: runtime)
    store.runners = [runner]
    await store.retryConnection(runner)
    #expect(store.state(runner) == .reconnecting)
    #expect(store.issues[runner.id]?.hasPrefix("Could not retry connection:") == true)
    #expect(store.operations.isEmpty)
    #expect(store.runners == [runner])
}

@Test @MainActor func completedJobUpdatesFailureBadgeWithoutSelectingItsRunner() async throws {
    let fixture = RefreshFixture { request in
        if request.url!.path.hasSuffix("/runners") {
            return try Reply(["runners": [["id": 21, "name": "Mac", "status": "online", "busy": false]]])
        }
        if request.url!.path.hasSuffix("/runs") { return try Reply(runs()) }
        var failed = job(1)
        failed["conclusion"] = "failure"
        return try Reply(["jobs": [failed]])
    }
    defer { fixture.close() }
    let paths = AppPaths(root: .temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = RunnerStore(github: fixture.github(), paths: paths, readLog: { _ in "" }, dedicatedSnapshot: { _ in
        VMSnapshot(running: true, registrationID: 21, log: "")
    })
    let runner = try Runner(repository: "stub/repo", name: "Mac", label: "test", githubID: 21, execution: .dedicatedUser)
    store.runners = [runner]
    store.signedIn = true
    store.states[runner.id] = .busy
    await store.refreshStates()
    #expect(store.selectedID == nil)
    #expect(store.state(runner) == .ready)
    #expect(store.activity[runner.id]?.first?.job.conclusion == "failure")
    #expect(store.hasFailures)
}

@MainActor private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
}

@Test @MainActor func activityBoundsConcurrencyPreservesOrderAndPaginationAndCommitsCacheAtomically() async throws {
    let options = Mutex((revision: "original", hold: true, fail: false))
    let fixture = RefreshFixture(hold: { request in
        options.withLock { $0.hold } && request.url!.path.hasSuffix("/jobs")
    }, reply: { request in
        if request.url!.path.hasSuffix("/runs") {
            return try Reply(runs(10, revision: options.withLock { $0.revision }))
        }
        let run = Int(request.url!.pathComponents.dropLast().last!)!
        let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!
        if run == 1, page == "2", options.withLock({ $0.fail }) { return try Reply([:], status: 500) }
        let ids = run == 1 && page == "1" ? Array(1001...1100) : [run == 1 ? 1101 : run * 1000 + 1]
        return try Reply(["jobs": ids.map { job($0) } + (run == 2 ? [job(99999, runner: 22)] : [])])
    })
    defer { fixture.close() }
    let github = fixture.github()
    let runner = try Runner(repository: "stub/repo", name: "Mac", label: "test", githubID: 21)
    let loading = Task { try await github.activity(runner) }
    try await waitFor { fixture.pending == 3 }
    for _ in 0..<11 {
        try await waitFor { fixture.pending > 0 }
        fixture.releaseLast()
    }
    let result = try await loading.value
    #expect(result.map(\.job.id) == Array(1001...1101) + (2...10).map { $0 * 1000 + 1 })
    #expect(fixture.state.withLock { $0.peak } == 3)
    #expect(fixture.requests.count == 12)
    #expect(fixture.requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
    _ = try await github.activity(runner)
    #expect(fixture.requests.count == 13)

    options.withLock { $0 = ("changed", false, true) }
    await #expect(throws: (any Error).self) { try await github.activity(runner) }
    options.withLock { $0 = ("original", false, false) }
    let afterFailure = fixture.requests.count
    #expect(try await github.activity(runner).count == 110)
    #expect(fixture.requests.count == afterFailure + 1)

    options.withLock { $0 = ("changed", true, false) }
    let cancelled = Task { try await github.activity(runner) }
    try await waitFor { fixture.pending == 3 }
    cancelled.cancel()
    await #expect(throws: (any Error).self) { try await cancelled.value }
    try await waitFor { fixture.pending == 0 }
    options.withLock { $0 = ("original", false, false) }
    let afterCancellation = fixture.requests.count
    #expect(try await github.activity(runner).count == 110)
    #expect(fixture.requests.count == afterCancellation + 1)
}

@Test(arguments: [429, 403, 200]) func rateLimitCooldownAlsoBlocksManualRequests(status: Int) async throws {
    let fixture = RefreshFixture { _ in
        try Reply(["message": "API rate limit exceeded"], status: status,
                  headers: status == 429 ? ["Retry-After": "120"] :
                    ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(Date().timeIntervalSince1970) + 120)])
    }
    defer { fixture.close() }
    let github = fixture.github()
    if status == 200 { let _: Empty = try await github.request("/test") }
    else { await #expect(throws: RunnerError.self) { let _: Empty = try await github.request("/test") } }
    await #expect(throws: RunnerError.self) { let _: Empty = try await github.request("/test") }
    #expect(fixture.requests.count == 1)
}

@Test(arguments: [true, false]) func permissionErrorsDoNotTriggerSecondaryRateLimitCooldown(secondary: Bool) async throws {
    let fixture = RefreshFixture { _ in
        try Reply(["message": secondary ? "You have exceeded a secondary rate limit" : "Resource not accessible"], status: 403)
    }
    defer { fixture.close() }
    let github = fixture.github()
    for _ in 0..<2 {
        await #expect(throws: RunnerError.self) { let _: Empty = try await github.request("/test") }
    }
    #expect(fixture.requests.count == (secondary ? 1 : 2))
}

@Test func publicAndAuthenticatedRateLimitQuotasStaySeparate() async throws {
    let fixture = RefreshFixture { _ in
        try Reply([:], headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(Date().timeIntervalSince1970) + 120)])
    }
    defer { fixture.close() }
    let github = fixture.github()
    let _: Empty = try await github.request("/test", authenticated: false)
    let _: Empty = try await github.request("/test")
    #expect(fixture.requests.count == 2)
}

private final class PollSleeper: Sendable {
    let state = Mutex((delays: [Duration](), waiters: [AsyncStream<Void>.Continuation]()))
    func sleep(_ delay: Duration) async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        state.withLock { $0.delays.append(delay); $0.waiters.append(continuation) }
        for await _ in stream { break }
        try Task.checkCancellation()
    }
    func advance() {
        let waiters = state.withLock { let waiters = $0.waiters; $0.waiters = []; return waiters }
        for waiter in waiters { waiter.yield(); waiter.finish() }
    }
}

@Test @MainActor func activityPollIgnoresSlowStateChecksAndBacksOffIndependently() async throws {
    let failing = Mutex(true)
    let fixture = RefreshFixture { request in
        if request.url!.path.hasSuffix("/runs") { return try Reply(runs(status: "in_progress")) }
        return try Reply(["jobs": [job(1)]], status: failing.withLock { $0 } ? 500 : 200)
    }
    defer { fixture.close() }
    let sleeper = PollSleeper()
    let (stateGate, releaseState) = AsyncStream<Void>.makeStream()
    let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let store = RunnerStore(github: fixture.github(), paths: paths, sleep: { try await sleeper.sleep($0) }, readLog: { _ in
        for await _ in stateGate { break }
        return "stub log"
    })
    let runner = try Runner(repository: "stub/repo", name: "Mac", label: "test", githubID: 21)
    store.runners = [runner]; store.selectedID = runner.id; store.signedIn = true
    store.startPolling()
    store.startPolling()
    try await waitFor { sleeper.state.withLock { $0.delays == [.seconds(10)] } }
    #expect(store.activityIssue[runner.id] != nil)
    #expect(store.states.isEmpty)
    failing.withLock { $0 = false }
    #expect(await store.refreshActivity())
    #expect(store.activityIssue[runner.id] == nil)
    #expect(store.activity[runner.id]?.count == 1)
    try await waitFor { sleeper.state.withLock { $0.delays == [.seconds(10), .seconds(5)] } }
    #expect(fixture.requests.filter { $0.url!.path.hasSuffix("/runs") }.count == 2)
    sleeper.advance()
    try await waitFor { sleeper.state.withLock { $0.delays == [.seconds(10), .seconds(5), .seconds(5)] } }
    releaseState.yield(); releaseState.finish()
    try await waitFor { sleeper.state.withLock { $0.delays.count == 4 } }
    #expect(sleeper.state.withLock { $0.delays.last } == .seconds(5))
    #expect(store.state(runner) == .stopped)

    failing.withLock { $0 = true }
    #expect(await store.refreshActivity() == false)
    #expect(store.activity[runner.id]?.map(\.job.id) == [1])
    #expect(store.activityIssue[runner.id] != nil)
    #expect(await store.shutdown())
    let requests = fixture.requests.count
    sleeper.advance()
    await Task.yield()
    #expect(fixture.requests.count == requests)
}

@Test @MainActor func activityCoalescesRequestsAndRejectsCancelledOrRemovedSelections() async throws {
    let fixture = RefreshFixture(hold: { $0.url!.path.hasSuffix("/runs") }) { request in
        if request.url!.path.hasSuffix("/runs") { return try Reply(runs(status: "in_progress")) }
        return try Reply(["jobs": [job(21), job(22, runner: 22)]])
    }
    defer { fixture.close() }
    let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let store = RunnerStore(github: fixture.github(), paths: paths)
    let a = try Runner(repository: "stub/repo", name: "A", label: "test", githubID: 21)
    let b = try Runner(repository: "stub/repo", name: "B", label: "test", githubID: 22)
    store.runners = [a, b]; store.selectedID = a.id; store.signedIn = true
    let first = Task { await store.refreshActivity() }
    try await waitFor { fixture.pending == 1 }
    var joined = false
    let second = Task { joined = true; return await store.refreshActivity() }
    try await waitFor { joined }
    first.cancel()
    #expect(store.refreshingActivity)
    fixture.releaseLast()
    #expect(await first.value)
    #expect(await second.value)
    #expect(fixture.requests.filter { $0.url!.path.hasSuffix("/runs") }.count == 1)
    #expect(store.activity[a.id]?.map(\.job.id) == [21])

    let oldA = Task { await store.refreshActivity() }
    try await waitFor { fixture.pending == 1 }
    store.selectedID = b.id
    let oldB = Task { await store.refreshActivity() }
    try await waitFor { fixture.requests.filter { $0.url!.path.hasSuffix("/runs") }.count == 3 }
    store.selectedID = a.id
    let latestA = Task { await store.refreshActivity() }
    try await waitFor { fixture.requests.filter { $0.url!.path.hasSuffix("/runs") }.count == 4 }
    fixture.releaseLast()
    #expect(await latestA.value)
    _ = await oldA.value; _ = await oldB.value
    #expect(fixture.state.withLock { $0.peak } == 1)
    #expect(store.activity[b.id] == nil)
    #expect(store.activityIssue.isEmpty)

    store.activity.removeValue(forKey: a.id)
    let removed = Task { await store.refreshActivity() }
    try await waitFor { fixture.pending == 1 }
    store.runners = []
    fixture.releaseLast()
    _ = await removed.value
    #expect(store.activity[a.id] == nil)
    #expect(store.activityIssue.isEmpty)

    store.runners = [a]
    let quitting = Task { await store.refreshActivity() }
    try await waitFor { fixture.pending == 1 }
    #expect(await store.shutdown())
    _ = await quitting.value
    #expect(!store.refreshingActivity)
    #expect(store.activityIssue.isEmpty)
    #expect(fixture.pending == 0)
}
