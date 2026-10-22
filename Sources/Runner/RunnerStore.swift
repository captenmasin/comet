import AppKit
import Foundation
import Observation
import RunnerCore

@MainActor
struct VMRuntime {
    let isRunning: (UUID) -> Bool
    let prepare: (Runner, @escaping @MainActor @Sendable (String) -> Void) async throws -> Int
    let snapshot: (UUID) async throws -> VMSnapshot
    let launch: (UUID) async throws -> Void
    let stop: (UUID) async throws -> Void
}

@MainActor @Observable
final class RunnerStore {
    let github: GitHub
    let paths: AppPaths
    let virtualMachines = MacVirtualMachines()
    let loginItem = LoginItem()
    @ObservationIgnored lazy var updates = AppUpdater(store: self)
    @ObservationIgnored lazy var mcp = MCPServer(store: self)
    var runners: [Runner] = []
    var selectedID: UUID? {
        didSet {
            if selectedID != oldValue {
                activityFailures = 0
                activityRefresh?.task.cancel()
            }
        }
    }
    var states: [UUID: RunnerState] = [:] {
        didSet {
            for (id, state) in states where oldValue[id] != state {
                AppLog.record("runner=\(id) state=\(state.rawValue)")
            }
        }
    }
    var issues: [UUID: String] = [:] {
        didSet {
            for (id, issue) in issues where oldValue[id] != issue {
                AppLog.record("runner=\(id) issue=\(issue)", error: states[id] == .attention || !operations.contains(id))
            }
        }
    }
    var logs: [UUID: String] = [:]
    var activity: [UUID: [RunnerActivity]] = [:]
    var activityIssue: [UUID: String] = [:] {
        didSet {
            for (id, issue) in activityIssue where oldValue[id] != issue {
                AppLog.record("runner=\(id) activity issue=\(issue)", error: true)
            }
        }
    }
    var operations: Set<UUID> = []
    var signedIn = false
    var account = "Not signed in"
    var error: String? {
        didSet { if let error, error != oldValue { AppLog.record("app error: \(error)", error: true) } }
    }
    var showSetup = false
    private var hosts: [UUID: Process] = [:]
    private var dedicatedRunning: [UUID: Bool] = [:]
    private var poll: Task<Void, Never>?
    private var activityPoll: Task<Void, Never>?
    private var refreshInProgress = false
    private var configurationLoaded = false
    private var failures = 0
    private var activityFailures = 0
    private var activityRefresh: (runner: Runner, task: Task<Bool, Never>)?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let readLog: @Sendable (URL) async -> String
    private let restore: @Sendable () async throws -> Bool
    private let dedicatedSnapshot: @Sendable (Runner) async throws -> VMSnapshot
    private let vmRuntime: VMRuntime
    private let now: @Sendable () -> Date
    private var idleSince: [UUID: Date] = [:]
    private var listeningFor: [UUID: Int] = [:]
    private var failedVMSetup: Set<UUID> = []
    private var nextQueueCheck = Date.distantPast
    private var vmRefreshInProgress = false
    private var shuttingDown = false

    init(github: GitHub = GitHub(), paths: AppPaths = AppPaths(),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         readLog: @escaping @Sendable (URL) async -> String = { await RunnerProcess.readLog($0) },
         restore: (@Sendable () async throws -> Bool)? = nil,
         vmRuntime: VMRuntime? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         dedicatedSnapshot: @escaping @Sendable (Runner) async throws -> VMSnapshot = {
             try await DedicatedUser(id: $0.id).snapshot(registered: $0.githubID != nil)
         }) {
        self.github = github
        self.paths = paths
        self.sleep = sleep
        self.readLog = readLog
        self.restore = restore ?? { try await github.restore() }
        self.dedicatedSnapshot = dedicatedSnapshot
        self.now = now
        let machines = virtualMachines
        self.vmRuntime = vmRuntime ?? VMRuntime(
            isRunning: { machines.isRunning($0) },
            prepare: { runner, progress in
                let connection = try await machines.start(runner, paths: paths, progress: progress)
                guard let executable = RunnerProcess.executableURL else { throw RunnerError.message("Could not locate Comet’s guest helper.") }
                let id = try await connection.install(runner, github: github, executable: executable, progress: progress)
                _ = try await connection.command("rm -f \(VMConnection.quote(VMConnection.guestDirectory + "/.host-exit"))")
                return id
            },
            snapshot: { try await machines.connection($0).snapshot() },
            launch: { try await machines.connection($0).launch() },
            stop: { try await machines.stop($0) })
    }

    var selected: Runner? { runners.first { $0.id == selectedID } }
    var refreshingActivity: Bool { activityRefresh != nil }
    var hasRunningJobs: Bool { runners.contains { state($0) == .busy } }
    var successExpiresAt: Date? {
        runners.compactMap { runner -> Date? in
            guard let latest = activity[runner.id]?.first(where: { $0.job.status == "completed" }),
                  latest.job.conclusion == "success",
                  let completed = ActivityDuration.date(latest.job.completed_at), completed <= now() else { return nil }
            return completed.addingTimeInterval(120)
        }.max()
    }
    var hasFailures: Bool {
        error != nil || runners.contains { runner in
            state(runner) == .attention || (issues[runner.id] != nil && !operations.contains(runner.id))
                || activityIssue[runner.id] != nil
                || ["failure", "timed_out", "startup_failure"].contains(
                    activity[runner.id]?.first { $0.job.status == "completed" }?.job.conclusion ?? "")
        }
    }
    var menuBarState: RunnerState {
        if hasFailures { return .attention }
        let current = runners.map { state($0) }
        return [.attention, .busy, .reconnecting, .starting, .stopping, .ready, .sleeping]
            .first { current.contains($0) } ?? .stopped
    }
    var canQuit: Bool { operations.isEmpty }
    var canInstallUpdate: Bool {
        configurationLoaded && canQuit && !mightInterruptJob && !virtualMachines.isDownloading && !runners.contains(where: isEnabled)
    }
    var mightInterruptJob: Bool {
        runners.contains { [.busy, .reconnecting, .starting].contains(state($0)) }
    }
    func state(_ runner: Runner) -> RunnerState { states[runner.id] ?? .stopped }
    func isEnabled(_ runner: Runner) -> Bool {
        hasHost(runner) || runners.contains { $0.id == runner.id && $0.watchForJobs }
    }
    func showWorkspace(for runner: Runner) {
        let directory = paths.directory(runner.id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "The workspace folder is unavailable. Set up or start this runner first.\n\n\(directory.path)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
    func hasHost(_ runner: Runner) -> Bool {
        switch runner.execution {
        case .host: RunnerProcess.locked(paths.directory(runner.id))
        case .macOSVM: vmRuntime.isRunning(runner.id)
        // Unknown cross-user status must never enable duplicate starts or removal.
        case .dedicatedUser: dedicatedRunning[runner.id] ?? true
        }
    }

    @discardableResult
    private func checkDedicated(_ runner: Runner, polling: Bool = false) async throws -> VMSnapshot {
        let snapshot = try await dedicatedSnapshot(runner)
        if polling, operations.contains(runner.id) { return snapshot }
        if let expected = runner.githubID, let actual = snapshot.registrationID, expected != actual {
            throw RunnerError.message("The dedicated workspace belongs to a different GitHub registration. Its files have been preserved.")
        }
        dedicatedRunning[runner.id] = snapshot.running
        logs[runner.id] = snapshot.log
        let directory = paths.directory(runner.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(snapshot.log.utf8).write(to: directory.appendingPathComponent("runner.log"), options: .atomic)
        return snapshot
    }

    func load() async {
        AppLog.record("loading configuration and credentials")
        do {
            try paths.prepare()
            runners = try paths.load()
            configurationLoaded = true
            selectedID = runners.first?.id
            for runner in runners {
                states[runner.id] = hasHost(runner) ? .reconnecting : runner.watchForJobs ? .sleeping : .stopped
            }
            signedIn = try await restore()
        } catch { self.error = error.localizedDescription }
        if signedIn {
            await identify()
            await withTaskGroup(of: Void.self) { group in
                for runner in runners where runner.runAutomatically && !runner.watchForJobs {
                    group.addTask { await self.start(runner) }
                }
            }
        }
        startPolling()
        AppLog.record("load completed runners=\(runners.count) signedIn=\(signedIn)")
    }

    func startPolling() {
        guard poll == nil else { return }
        let sleep = sleep
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStates()
                guard let failures = self?.failures else { return }
                do { try await sleep(.seconds(min(240, 5 * (1 << failures)))) }
                catch { return }
            }
        }
        startActivityPolling()
    }

    private func startActivityPolling(waitFirst: Bool = false) {
        activityPoll?.cancel()
        let sleep = sleep
        activityPoll = Task { [weak self] in
            var waitFirst = waitFirst
            while !Task.isCancelled {
                if !waitFirst { await self?.fetchActivity() }
                waitFirst = false
                guard let failures = self?.activityFailures else { return }
                do { try await sleep(.seconds(min(240, 5 * (1 << failures)))) }
                catch { return }
            }
        }
    }

    func identify() async {
        struct User: Decodable, Sendable { let login: String }
        do {
            let user: User = try await github.request("/user")
            account = user.login
            signedIn = true
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        nextQueueCheck = .distantPast
        async let stateRefresh: Void = refreshStates()
        await refreshActivity()
        await stateRefresh
    }

    func retryConnection(_ runner: Runner) async {
        guard let runner = runners.first(where: { $0.id == runner.id }),
              !operations.contains(runner.id), !shuttingDown else { return }
        operations.insert(runner.id)
        issues[runner.id] = "Checking connection…"
        defer { operations.remove(runner.id) }
        do {
            let remote = try await github.runners(repository: runner.repository)
            try Task.checkCancellation()
            guard !shuttingDown else { return }
            guard let match = remote.first(where: { $0.id == runner.githubID }) else {
                throw RunnerError.message("This registration no longer exists on GitHub. Stop and remove the local runner, then add it again.")
            }
            if match.busy || match.status == "online" {
                states[runner.id] = match.busy ? .busy
                    : hasHost(runner) ? .ready : runner.watchForJobs ? .sleeping : .stopped
                issues[runner.id] = nil
                return
            }
            await stopRunner(runner, preservingWatch: true)
            guard state(runner) == .stopped, !Task.isCancelled, !shuttingDown else { return }
            await startRunner(runner)
        } catch {
            states[runner.id] = hasHost(runner) ? .reconnecting : .attention
            issues[runner.id] = "Could not retry connection: \(error.localizedDescription)"
        }
    }

    func refreshStates() async {
        guard !refreshInProgress, !shuttingDown, !Task.isCancelled else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        let busy = Set(runners.filter { state($0) == .busy }.map(\.id))
        var failed = false
        var snapshots: [String: [RemoteRunner]] = [:]
        for runner in runners where runner.execution != .macOSVM && !operations.contains(runner.id) {
            let directory = paths.directory(runner.id)
            logs[runner.id] = await readLog(directory)
            guard !operations.contains(runner.id) else { continue }
            if runner.execution == .dedicatedUser {
                do {
                    try await checkDedicated(runner, polling: true)
                    guard !operations.contains(runner.id) else { continue }
                } catch {
                    guard !operations.contains(runner.id) else { continue }
                    failed = true
                    dedicatedRunning[runner.id] = nil
                    states[runner.id] = .attention
                    issues[runner.id] = error.localizedDescription
                    continue
                }
            }
            guard hasHost(runner) else {
                if let host = hosts.removeValue(forKey: runner.id), !host.isRunning, host.terminationStatus != 0 {
                    AppLog.record("runner=\(runner.id) helper pid=\(host.processIdentifier) exited status=\(host.terminationStatus) reason=\(host.terminationReason.rawValue)", error: true)
                    issues[runner.id] = "The local runner exited unexpectedly. Check Logs, then start it again."
                    states[runner.id] = .attention
                } else if state(runner) != .attention { states[runner.id] = .stopped }
                continue
            }
            guard runner.execution != .host || RunnerProcess.hostPID(directory) != nil else {
                states[runner.id] = .attention
                issues[runner.id] = "The runner folder is locked by an unverified process. Check Activity Monitor before proceeding."
                continue
            }
            do {
                let remote: [RemoteRunner]
                if let cached = snapshots[runner.repository] {
                    remote = cached
                } else {
                    remote = try await github.runners(repository: runner.repository)
                    snapshots[runner.repository] = remote
                }
                guard !operations.contains(runner.id), hasHost(runner) else { continue }
                guard let match = remote.first(where: { $0.id == runner.githubID }) else {
                    states[runner.id] = .attention
                    issues[runner.id] = "This registration no longer exists on GitHub. Stop and remove the local runner, then add it again."
                    continue
                }
                states[runner.id] = match.status == "online" ? (match.busy ? .busy : .ready) : .reconnecting
                issues[runner.id] = match.status == "online" ? nil : "The process is running, but GitHub reports it offline."
            } catch {
                guard !operations.contains(runner.id) else { continue }
                failed = true
                states[runner.id] = .reconnecting
                issues[runner.id] = error.localizedDescription
            }
        }
        if await refreshVMs() { failed = true }
        for runner in runners where signedIn && !operations.contains(runner.id)
            && [.ready, .stopped, .sleeping].contains(state(runner))
            && (busy.contains(runner.id) || activityIssue[runner.id] != nil) {
            do {
                let result = try await github.activity(runner)
                guard !Task.isCancelled, !shuttingDown, signedIn, runners.contains(runner) else { continue }
                activity[runner.id] = result
                activityIssue[runner.id] = nil
            } catch {
                guard !Task.isCancelled, !shuttingDown, signedIn, runners.contains(runner) else { continue }
                activityIssue[runner.id] = error.localizedDescription
                failed = true
            }
        }
        failures = failed ? min(failures + 1, 6) : 0
    }

    @discardableResult
    func refreshVMs() async -> Bool {
        guard !vmRefreshInProgress, !shuttingDown, !Task.isCancelled else { return false }
        vmRefreshInProgress = true
        defer { vmRefreshInProgress = false }
        let checkingQueue = signedIn && now() >= nextQueueCheck
        var queued: [String: [Job]] = [:]
        var queueErrors: [String: String] = [:]
        if checkingQueue {
            nextQueueCheck = now().addingTimeInterval(30)
            for repository in Set(runners.filter(\.watchForJobs).map(\.repository)) {
                do { queued[repository] = try await github.queuedJobs(repository: repository) }
                catch { queueErrors[repository] = error.localizedDescription }
            }
        }
        var failed = !queueErrors.isEmpty
        var claimed = Set(listeningFor.values)
        for runner in runners where runner.execution == .macOSVM && runner.watchForJobs {
            guard watching(runner.id) else { continue }
            guard !failedVMSetup.contains(runner.id) else { failed = true; continue }
            do {
                if hasHost(runner) {
                    let snapshot = try await vmRuntime.snapshot(runner.id)
                    guard watching(runner.id), hasHost(runner) else { continue }
                    logs[runner.id] = snapshot.log
                    try Data(snapshot.log.utf8).write(to: paths.directory(runner.id).appendingPathComponent("runner.log"), options: .atomic)
                    if snapshot.running {
                        idleSince[runner.id] = nil
                        // A listener may receive work after GitHub reports idle. Never stop it on that sample.
                        let remote = try await github.runners(repository: runner.repository)
                        guard watching(runner.id), hasHost(runner) else { continue }
                        guard let match = remote.first(where: { $0.id == runner.githubID }) else {
                            throw RunnerError.message("This registration no longer exists on GitHub. Stop and remove the local runner, then add it again.")
                        }
                        states[runner.id] = match.busy ? .busy : match.status == "online" ? .ready : .reconnecting
                        issues[runner.id] = queueErrors[runner.repository]
                            ?? (match.status == "online" ? nil : "The process is running, but GitHub reports it offline.")
                        continue
                    }
                    guard snapshot.exitCode == 0 || (snapshot.exitCode == nil && idleSince[runner.id] != nil) else {
                        throw RunnerError.message("The guest runner exited unexpectedly. Check Logs, then stop and start this runner.")
                    }
                    if let job = listeningFor.removeValue(forKey: runner.id) { claimed.remove(job) }
                    if idleSince[runner.id] == nil { idleSince[runner.id] = now() }
                    states[runner.id] = .ready
                } else {
                    if let job = listeningFor.removeValue(forKey: runner.id) { claimed.remove(job) }
                    states[runner.id] = .sleeping
                }
                if let issue = queueErrors[runner.repository] {
                    issues[runner.id] = issue
                    continue
                }
                guard let jobs = queued[runner.repository] else { continue }
                issues[runner.id] = nil
                if jobs.contains(where: { !claimed.contains($0.id) && GitHub.matchesQueuedJob($0, runner: runner) }) {
                    var available = jobs
                    if !hasHost(runner) {
                        await start(runner)
                        guard watching(runner.id), hasHost(runner), state(runner) == .ready, issues[runner.id] == nil else { continue }
                        // Boot can take a while; avoid listening forever for a job cancelled during startup.
                        available = try await github.queuedJobs(repository: runner.repository)
                    }
                    guard watching(runner.id), let job = available.first(where: {
                        !claimed.contains($0.id) && GitHub.matchesQueuedJob($0, runner: runner)
                    }) else { continue }
                    claimed.insert(job.id)
                    listeningFor[runner.id] = job.id
                    operations.insert(runner.id)
                    defer { operations.remove(runner.id) }
                    try await vmRuntime.launch(runner.id)
                    idleSince[runner.id] = nil
                    states[runner.id] = .reconnecting
                    // shortcut: a job cancelled after launch can leave --once waiting; keep the VM on rather than risk cancelling newly assigned work.
                } else if hasHost(runner), let since = idleSince[runner.id], now().timeIntervalSince(since) >= 60 {
                    operations.insert(runner.id)
                    defer { operations.remove(runner.id) }
                    states[runner.id] = .stopping
                    try await vmRuntime.stop(runner.id)
                    idleSince[runner.id] = nil
                    states[runner.id] = .sleeping
                }
            } catch {
                guard watching(runner.id) else { continue }
                failed = true
                issues[runner.id] = error.localizedDescription
                states[runner.id] = .attention
            }
        }
        return failed
    }

    private func watching(_ id: UUID) -> Bool {
        !shuttingDown && !Task.isCancelled && !operations.contains(id)
            && runners.contains { $0.id == id && $0.watchForJobs }
    }

    @discardableResult
    func refreshActivity() async -> Bool {
        guard !Task.isCancelled else { return true }
        let updated = await fetchActivity()
        // A manual recovery must not leave the poll asleep on its previous failure backoff.
        if let poll, !poll.isCancelled { startActivityPolling(waitFirst: true) }
        return updated
    }

    @discardableResult
    private func fetchActivity() async -> Bool {
        guard !Task.isCancelled else { return true }
        while let refresh = activityRefresh {
            if refresh.runner == selected, !refresh.task.isCancelled { return await refresh.task.value }
            refresh.task.cancel()
            _ = await refresh.task.value
            guard !Task.isCancelled else { return true }
        }
        guard let runner = selected, runner.githubID != nil, signedIn, !operations.contains(runner.id) else { return true }
        let task = Task { [weak self] in
            guard let self else { return true }
            defer { activityRefresh = nil }
            do {
                let result = try await github.activity(runner)
                try Task.checkCancellation()
                guard selected == runner, signedIn, !operations.contains(runner.id) else { return true }
                activity[runner.id] = result
                activityIssue[runner.id] = nil
                activityFailures = 0
                return true
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                      (error as? URLError)?.code != .cancelled, selected == runner,
                      signedIn, !operations.contains(runner.id) else { return true }
                activityIssue[runner.id] = error.localizedDescription
                activityFailures = min(activityFailures + 1, 6)
                return false
            }
        }
        activityRefresh = (runner, task)
        return await task.value
    }

    func setRunAutomatically(_ enabled: Bool, for runner: Runner) {
        guard configurationLoaded, !operations.contains(runner.id),
              let index = runners.firstIndex(where: { $0.id == runner.id }) else { return }
        var next = runners
        next[index].runAutomatically = enabled
        do {
            try paths.save(next)
            runners = next
        } catch { self.error = error.localizedDescription }
    }

    func setExecution(_ execution: RunnerExecution, for runner: Runner) async {
        guard configurationLoaded, !operations.contains(runner.id),
              let current = runners.first(where: { $0.id == runner.id }), current.execution != execution else { return }
        if execution == .macOSVM, !MacVirtualMachines.available { error = MacVirtualMachines.requirement; return }
        operations.insert(runner.id)
        defer { operations.remove(runner.id) }
        do {
            if current.execution == .dedicatedUser { try await checkDedicated(current) }
            guard !isEnabled(current) else { return }
            // A new identity preserves the old workspace and cannot reuse stale registration files.
            let replacement = try Runner(repository: current.repository, name: current.name, label: current.label,
                                         execution: execution, runAutomatically: current.runAutomatically)
            let next = runners.map { $0.id == current.id ? replacement : $0 }
            // Verify persistence before removing the existing GitHub registration.
            try paths.save(runners)
            let directory = paths.directory(current.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // If interrupted after deregistration, do not launch the old guest credentials again.
            try Data().write(to: directory.appendingPathComponent("execution-change"), options: .atomic)
            if current.githubID != nil { try await github.remove(current) }
            else if try await github.runners(repository: current.repository).contains(where: { $0.name == current.name }) {
                throw RunnerError.message("A matching registration exists on GitHub. Remove it there before changing execution.")
            }
            try paths.save(next)
            runners = next
            if execution == .dedicatedUser { dedicatedRunning[replacement.id] = false }
            selectedID = replacement.id
        } catch { self.error = error.localizedDescription }
    }

    func prepareDedicatedAccount(for runner: Runner) async {
        guard runner.execution == .dedicatedUser, !operations.contains(runner.id) else { return }
        operations.insert(runner.id)
        defer { operations.remove(runner.id) }
        do {
            try await DedicatedUser.prepareHomebrew(github: github) { [weak self] message in
                self?.issues[runner.id] = message
            }
            try await checkDedicated(runner)
            states[runner.id] = hasHost(runner) ? .reconnecting : .stopped
            issues[runner.id] = nil
        } catch { self.error = error.localizedDescription }
    }

    func add(repository: String, name: String, execution: RunnerExecution = .host, runAutomatically: Bool = false) async -> Bool {
        guard configurationLoaded else { error = "Saved configuration could not be loaded. Resolve that error before adding runners."; return false }
        do {
            guard execution != .macOSVM || MacVirtualMachines.available else { throw RunnerError.message(MacVirtualMachines.requirement) }
            let runner = try Runner(repository: repository, name: name, label: "runner-\(UUID().uuidString.prefix(8).lowercased())",
                                    execution: execution, runAutomatically: runAutomatically)
            let next = runners + [runner]
            try paths.save(next)
            runners = next
            if execution == .dedicatedUser { dedicatedRunning[runner.id] = false }
            selectedID = runner.id
            await start(runner)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func start(_ runner: Runner) async {
        guard let runner = runners.first(where: { $0.id == runner.id }) else { return }
        guard !operations.contains(runner.id), !shuttingDown else { return }
        if runner.execution != .dedicatedUser, hasHost(runner) { return }
        operations.insert(runner.id)
        defer { operations.remove(runner.id) }
        await startRunner(runner)
    }

    private func startRunner(_ runner: Runner) async {
        states[runner.id] = .starting
        issues[runner.id] = nil
        idleSince[runner.id] = nil
        listeningFor[runner.id] = nil
        do {
            guard !FileManager.default.fileExists(atPath: paths.directory(runner.id).appendingPathComponent("execution-change").path) else {
                throw RunnerError.message("An execution change was interrupted. Select the new execution option again, or remove and re-add this runner. Its files have been preserved.")
            }
            let progress: @MainActor @Sendable (String) -> Void = { [weak self] message in
                self?.issues[runner.id] = message
            }
            let id: Int
            if runner.execution == .macOSVM {
                id = try await vmRuntime.prepare(runner, progress)
            } else if runner.execution == .dedicatedUser {
                guard !(try await checkDedicated(runner)).running else {
                    states[runner.id] = .reconnecting
                    issues[runner.id] = "The dedicated runner is already running. Retry Connection."
                    return
                }
                guard let executable = RunnerProcess.executableURL else { throw RunnerError.message("Could not locate Comet’s runner helper.") }
                id = try await DedicatedUser(id: runner.id).install(runner, github: github, executable: executable, progress: progress)
            } else {
                id = try await RunnerInstaller.install(runner, directory: paths.directory(runner.id), github: github, progress: progress)
            }
            guard let index = runners.firstIndex(where: { $0.id == runner.id }) else { return }
            var next = runners
            next[index].githubID = id
            if runner.execution == .macOSVM { next[index].watchForJobs = true }
            try paths.save(next)
            runners = next
            if runner.execution == .macOSVM {
                idleSince[runner.id] = now()
                failedVMSetup.remove(runner.id)
                nextQueueCheck = .distantPast
                states[runner.id] = .ready
                issues[runner.id] = nil
                return
            } else if runner.execution == .dedicatedUser {
                try await DedicatedUser(id: runner.id).launch()
                dedicatedRunning[runner.id] = true
            } else {
                hosts[runner.id] = try RunnerProcess.launch(paths.directory(runner.id))
            }
            for _ in 0..<30 {
                try await Task.sleep(for: .seconds(2))
                if runner.execution == .dedicatedUser {
                    guard try await checkDedicated(next[index]).running else { throw RunnerError.message("The dedicated runner exited during startup. Check Logs, then retry.") }
                } else {
                    guard let host = hosts[runner.id], host.isRunning else { throw RunnerError.message("The runner exited during startup. Check Logs, then retry.") }
                }
                let remote = try await github.runners(repository: runner.repository)
                if let match = remote.first(where: { $0.id == id }), match.status == "online" {
                    states[runner.id] = match.busy ? .busy : .ready
                    issues[runner.id] = nil
                    return
                }
            }
            states[runner.id] = .reconnecting
            issues[runner.id] = "The runner process started, but GitHub has not confirmed it online. Retry Connection."
        } catch {
            if runner.execution == .dedicatedUser {
                do { try await checkDedicated(runners.first(where: { $0.id == runner.id }) ?? runner) }
                catch { dedicatedRunning[runner.id] = nil }
            }
            if runner.execution == .macOSVM { failedVMSetup.insert(runner.id) }
            states[runner.id] = runner.execution == .macOSVM ? .attention : hasHost(runner) ? .reconnecting : .attention
            issues[runner.id] = error.localizedDescription
        }
        logs[runner.id] = await RunnerProcess.readLog(paths.directory(runner.id))
    }

    func stop(_ runner: Runner, preservingWatch: Bool = false) async {
        guard !operations.contains(runner.id) else { return }
        operations.insert(runner.id)
        defer { operations.remove(runner.id) }
        await stopRunner(runner, preservingWatch: preservingWatch)
    }

    private func stopRunner(_ runner: Runner, preservingWatch: Bool) async {
        states[runner.id] = .stopping
        do {
            if runner.execution == .macOSVM {
                if !preservingWatch {
                    var next = runners
                    if let index = next.firstIndex(where: { $0.id == runner.id }) { next[index].watchForJobs = false }
                    try paths.save(next)
                    runners = next
                }
                idleSince[runner.id] = nil
                listeningFor[runner.id] = nil
                try await vmRuntime.stop(runner.id)
                failedVMSetup.remove(runner.id)
            }
            else if runner.execution == .dedicatedUser {
                try await DedicatedUser(id: runner.id).stop()
                dedicatedRunning[runner.id] = false
            }
            else { try await RunnerProcess.stop(paths.directory(runner.id)) }
            hosts[runner.id] = nil
            states[runner.id] = .stopped
            issues[runner.id] = nil
        } catch {
            states[runner.id] = .attention
            issues[runner.id] = error.localizedDescription
        }
    }

    func remove(_ runner: Runner) async {
        guard let runner = runners.first(where: { $0.id == runner.id }),
              !operations.contains(runner.id), configurationLoaded else { return }
        operations.insert(runner.id)
        defer { operations.remove(runner.id) }
        do {
            var registered = runner
            if runner.execution == .dedicatedUser {
                let snapshot = try await checkDedicated(runner)
                guard !snapshot.running else { return }
                if registered.githubID == nil { registered.githubID = snapshot.registrationID }
            }
            guard !isEnabled(runner) else { return }
            if registered.githubID == nil {
                let config = paths.directory(runner.id).appendingPathComponent(".runner")
                if FileManager.default.fileExists(atPath: config.path) {
                    registered.githubID = try RunnerInstaller.registeredID(paths.directory(runner.id))
                } else {
                    // Failed registration may have reached GitHub before the local file was written.
                    let remote = try await github.runners(repository: runner.repository)
                    guard !remote.contains(where: { $0.name == runner.name }) else {
                        throw RunnerError.message("A matching GitHub registration exists. Remove it on GitHub first; local files have been preserved.")
                    }
                }
            }
            if registered.githubID != nil { try await github.remove(registered) }
            let next = runners.filter { $0.id != runner.id }
            try paths.save(next)
            runners = next
            if selectedID == runner.id { selectedID = runners.first?.id }
        } catch { self.error = error.localizedDescription }
    }

    func shutdown() async -> Bool {
        shuttingDown = true
        await virtualMachines.finishCancellingDownload()
        for runner in runners where hasHost(runner) { await stop(runner, preservingWatch: true) }
        let remaining = runners.filter { hasHost($0) }
        let stopped = remaining.isEmpty
        if stopped {
            await mcp.stop()
            poll?.cancel()
            activityPoll?.cancel()
            activityRefresh?.task.cancel()
            _ = await activityRefresh?.task.value
        }
        if !stopped {
            shuttingDown = false
            selectedID = remaining.first?.id
            error = "Some runners could not be stopped.\n\n" + remaining.map {
                "\($0.name) (\($0.repository)): \(issues[$0.id] ?? "The runner is still running or its status could not be verified.")"
            }.joined(separator: "\n\n")
        }
        return stopped
    }
}
