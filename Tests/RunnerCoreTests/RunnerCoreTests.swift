import Foundation
import Testing
import CryptoKit
import Darwin
import Synchronization
@testable import RunnerCore

@Test func validatesInputsAndWorkflowLabel() throws {
    let runner = try Runner(repository: "mason/example-app", name: "Mac.local", label: "runner-a1b2c3")
    #expect(Runner.validRepository("owner/" + String(repeating: "a", count: 100)))
    #expect(!Runner.validRepository("owner/" + String(repeating: "a", count: 101)))
    #expect(runner.workflow == "runs-on: [self-hosted, macOS, runner-a1b2c3]")
    for value in ["", "..", ".", "a b", "a/b", "$(id)", "a\nb", String(repeating: "a", count: 65)] {
        #expect(!Runner.validName(value))
    }
    for value in ["/repo", "owner/", "owner/repo/extra", "owner/../repo", "owner/a b"] {
        #expect(!Runner.validRepository(value))
    }
    #expect(throws: RunnerError.self) { try Runner(repository: "bad", name: "safe", label: "safe") }
}

@Test func savesAtomicallyAndRejectsDamagedConfiguration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(root: root)
    #expect(try paths.load().isEmpty)
    let runner = try Runner(repository: "owner/repo", name: "Mac", label: "runner-test")
    try paths.save([runner])
    #expect(try paths.load() == [runner])
    let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("runners.json").path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    try paths.save([runner, runner])
    #expect(throws: RunnerError.self) { try paths.load() }
    try Data("broken".utf8).write(to: root.appendingPathComponent("runners.json"))
    #expect(throws: (any Error).self) { try paths.load() }
    #expect(try String(contentsOf: root.appendingPathComponent("runners.json"), encoding: .utf8) == "broken")
}

@Test func verifiesDownloadBeforeExecution() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let data = Data("verified runner".utf8)
    try data.write(to: file)
    let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try await RunnerInstaller.verify(file: file, digest: digest)
    await #expect(throws: RunnerError.self) { try await RunnerInstaller.verify(file: file, digest: "sha256:" + String(repeating: "0", count: 64)) }
    await #expect(throws: RunnerError.self) { try await RunnerInstaller.verify(file: file, digest: "untrusted") }
}

@Test func redactsKnownManagementCredentialsAndBoundsLogs() {
    let safe = RunnerProcess.sanitized("token ghu_example123 Authorization: Bearer hello\n--token TEMP123\nrefresh_token=ghr_hidden", secrets: ["TEMP123"])
    #expect(!safe.contains("ghu_example123"))
    #expect(!safe.contains("TEMP123"))
    #expect(!safe.contains("hello"))
    #expect(!safe.contains("ghr_hidden"))
    #expect(RunnerProcess.bounded("old\nlatest", limit: 6) == "latest")
    #expect(RunnerProcess.environment()["GITHUB_TOKEN"] == nil)
    #expect(RunnerProcess.environment()["GH_TOKEN"] == nil)
    #expect(RunnerProcess.environment()["PATH"]?.contains("/opt/homebrew/bin") == true)
}

@Test func handlesGitHubErrorsWithoutLoggingResponseSecrets() throws {
    for status in [401, 403, 404, 429, 500] {
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/user")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        #expect(throws: RunnerError.self) { try GitHub.validate(response) }
    }
    let response = HTTPURLResponse(url: URL(string: "https://api.github.com/user")!, statusCode: 204, httpVersion: nil, headerFields: nil)!
    try GitHub.validate(response)
}

@Test func validatesPersonalAccessTokenBeforeSendingIt() async throws {
    try GitHub.validateToken("github_pat_test123")
    try GitHub.validateToken("ghp_classic123")
    for value in ["", "token with spaces", "token\nheader", "token\rheader", String(repeating: "a", count: 1025)] {
        #expect(throws: RunnerError.self) { try GitHub.validateToken(value) }
    }
    let github = GitHub()
    await #expect(throws: RunnerError.self) { try await github.connect(token: "invalid\nheader") }
}

@Test func processLockPreventsDuplicateAndUnsafeStops() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(!RunnerProcess.locked(directory))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(!RunnerProcess.locked(directory))
    try await RunnerProcess.stop(directory)
    let fd = open(directory.appendingPathComponent(".host.lock").path, O_RDWR)
    #expect(fd >= 0)
    defer { flock(fd, LOCK_UN); close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    #expect(RunnerProcess.locked(directory))
    #expect(RunnerProcess.hostPID(directory) == nil)
    #expect(throws: RunnerError.self) { try RunnerProcess.launch(directory) }
    await #expect(throws: RunnerError.self) { try await RunnerProcess.stop(directory) }
}

@Test func drainsProcessOutputAndKeepsFailureDetails() async throws {
    let directory = FileManager.default.temporaryDirectory
    let result = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "i=0; while [ $i -lt 4000 ]; do echo log-line; i=$((i + 1)); done"], directory: directory)
    #expect(result.contains("log-line"))
    do {
        _ = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo SECRET >&2; exit 7"], directory: directory, secrets: ["SECRET"])
        Issue.record("Expected failure")
    } catch {
        #expect(error.localizedDescription.contains("(7)"))
        #expect(!error.localizedDescription.contains("SECRET"))
        #expect(error.localizedDescription.contains("[redacted]"))
    }
}

final class GitHubStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: request.url?.path == "/user" ? 401 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"value":"ok"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func makesDirectAPIRequestAndRequiresSignInForPrivateCalls() async throws {
    struct Value: Decodable, Sendable { let value: String }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GitHubStub.self]
    let github = GitHub(session: URLSession(configuration: configuration))
    let result: Value = try await github.request("/test", authenticated: false)
    #expect(result.value == "ok")
    await #expect(throws: RunnerError.self) {
        let _: Value = try await github.request("/user")
    }
    await #expect(throws: RunnerError.self) { try await github.connect(token: "github_pat_invalid") }
    await #expect(throws: RunnerError.self) {
        let _: Value = try await github.request("/user")
    }
}

final class ActivityStub: URLProtocol, @unchecked Sendable {
    static let counts = Mutex((polls: 0, jobs: 0, fresh: true))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let payload: [String: Any] = Self.counts.withLock { counts in
            counts.fresh = counts.fresh && request.cachePolicy == .reloadIgnoringLocalCacheData
            if request.url?.path.hasSuffix("/runs") == true {
                counts.polls += 1
                let status = [1, 2, 5].contains(counts.polls) ? "in_progress" : "completed"
                let revision = counts.polls < 3 ? "started" : (counts.polls < 5 ? "finished" : (counts.polls < 7 ? "rerun" : "rerun-finished"))
                return ["workflow_runs": [[
                    "id": 123, "name": "CI", "head_branch": "main", "head_sha": "abcdef0",
                    "status": status, "conclusion": NSNull(), "html_url": "https://github.com/owner/repo/actions/runs/123",
                    "created_at": "2026-10-21T10:00:00Z", "updated_at": revision
                ]]]
            }
            counts.jobs += 1
            let running = [1, 2, 5].contains(counts.polls)
            return ["jobs": [21, 22].map { runner in [
                "id": runner, "name": "Build", "status": running ? "in_progress" : "completed",
                "conclusion": running ? NSNull() : "success" as Any,
                "runner_id": runner, "html_url": "https://github.com/owner/repo/actions/runs/123/job/\(runner)",
                "started_at": "2026-10-21T10:00:00Z", "completed_at": NSNull(),
                "steps": [[
                    "number": 2, "name": "Build", "status": running ? (counts.polls == 2 ? "in_progress" : "queued") : "completed",
                    "conclusion": running ? NSNull() : "success" as Any,
                    "started_at": counts.polls == 1 || counts.polls == 5 ? NSNull() : "2026-10-21T10:00:01.000Z" as Any,
                    "completed_at": running ? NSNull() : "2026-10-21T10:00:04.000Z" as Any
                ]]
            ] as [String: Any] }]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        do {
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: payload))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Test func liveActivityRefreshesActiveJobsAndRerunsWhileReusingCompletedJobs() async throws {
    ActivityStub.counts.withLock { $0 = (0, 0, true) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ActivityStub.self]
    let github = GitHub(session: URLSession(configuration: configuration), token: "test-token")
    let runner = try Runner(repository: "owner/repo", name: "Mac", label: "runner-test", githubID: 21)
    let other = try Runner(repository: "owner/repo", name: "Other", label: "runner-other", githubID: 22)

    for expectedStepStatus in ["queued", "in_progress"] {
        let result = try await github.activity(runner)
        #expect(result.count == 1)
        #expect(result.first?.job.status == "in_progress")
        #expect(result.first?.job.steps?.first?.status == expectedStepStatus)
    }
    #expect(ActivityStub.counts.withLock { $0.jobs } == 2)

    let completed = try await github.activity(runner)
    #expect(completed.first?.job.conclusion == "success")
    #expect(completed.first?.job.steps?.first?.conclusion == "success")
    #expect(completed.first?.job.steps?.first?.completed_at == "2026-10-21T10:00:04.000Z")
    let cached = try await github.activity(other)
    #expect(cached.first?.job.runner_id == 22)
    #expect(cached.first?.job.steps?.first?.status == "completed")
    #expect(ActivityStub.counts.withLock { $0.jobs } == 3)

    let rerun = try await github.activity(runner)
    #expect(rerun.first?.job.status == "in_progress")
    #expect(rerun.first?.job.steps?.first?.status == "queued")
    #expect(rerun.first?.job.steps?.first?.started_at == nil)
    let finished = try await github.activity(runner)
    #expect(finished.first?.job.status == "completed")
    #expect(ActivityStub.counts.withLock { $0.jobs } == 5)

    // A rerun can finish entirely between polls; a changed revision must still invalidate history.
    _ = try await github.activity(runner)
    _ = try await github.activity(runner)
    #expect(ActivityStub.counts.withLock { $0.jobs } == 6)
    #expect(ActivityStub.counts.withLock { $0.fresh })
}
