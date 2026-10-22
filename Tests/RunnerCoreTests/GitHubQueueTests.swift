import Foundation
import Synchronization
import Testing
@testable import RunnerCore

private func queueRun(_ id: Int, status: String) -> [String: Any] { [
    "id": id, "name": "CI", "head_sha": "fixture", "status": status,
    "html_url": "https://github.com/owner/repo/actions/runs/\(id)",
    "created_at": "2026-10-22T12:00:00Z", "updated_at": "2026-10-22T12:00:00Z"
] }

private func queueJob(_ id: Int, status: String = "queued", runnerID: Int? = nil,
                      labels: [String]? = ["self-hosted", "macOS", "ARM64", "runner-test"]) -> [String: Any] {
    var result: [String: Any] = ["id": id, "name": "Build", "status": status,
        "runner_id": runnerID.map { $0 as Any } ?? NSNull(),
        "html_url": "https://github.com/owner/repo/actions/runs/1/job/\(id)"]
    if let labels { result["labels"] = labels }
    return result
}

private final class QueueProtocol: URLProtocol, @unchecked Sendable {
    static let statuses = ["queued", "in_progress", "waiting", "pending", "requested"]
    static let state = Mutex((scenario: "", paths: [String](), fresh: true))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, payload) = Self.state.withLock { state -> (Int, [String: Any]) in
            let url = request.url!
            state.paths.append(url.path + "?" + (url.query ?? ""))
            state.fresh = state.fresh && request.cachePolicy == .reloadIgnoringLocalCacheData
            if state.scenario == "rate-limit" { return (429, ["message": "rate limited"]) }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let status = query.first { $0.name == "status" }?.value ?? ""
            let page = Int(query.first { $0.name == "page" }?.value ?? "1") ?? 1
            if url.path.hasSuffix("/actions/runs") {
                if state.scenario == "cap", status == "in_progress" {
                    return (200, ["total_count": 1001, "workflow_runs": []])
                }
                if state.scenario == "truncated", status == "queued" {
                    return (200, ["total_count": 101, "workflow_runs": page == 1
                        ? (1...100).map { queueRun($0, status: status) } : []])
                }
                if state.scenario == "pagination" {
                    if status == "queued" {
                        return (200, ["total_count": 101, "workflow_runs": (page == 1 ? Array(1...100) : [101]).map { queueRun($0, status: status) }])
                    }
                    if status == "in_progress" { return (200, ["total_count": 1, "workflow_runs": [queueRun(101, status: status)]]) }
                } else if state.scenario == "all-statuses", let index = Self.statuses.firstIndex(of: status) {
                    return (200, ["total_count": 1, "workflow_runs": [queueRun(index + 1, status: status)]])
                } else if state.scenario != "empty", status == "queued" || (state.scenario == "jobs-failure" && status == "in_progress") {
                    return (200, ["total_count": 1, "workflow_runs": [queueRun(status == "queued" ? 1 : 2, status: status)]])
                }
                return (200, ["total_count": 0, "workflow_runs": []])
            }
            let runID = Int(url.path.split(separator: "/").dropLast().last ?? "") ?? 0
            if state.scenario == "jobs-failure", runID == 2 { return (500, ["message": "unavailable"]) }
            if state.scenario == "pagination" {
                if runID != 101 { return (200, ["jobs": []]) }
                return (200, ["jobs": page == 1
                    ? (1...100).map { queueJob($0, status: "in_progress", runnerID: 21) }
                    : [queueJob(999)]])
            }
            if state.scenario == "matching" {
                return (200, ["jobs": [
                    queueJob(1, labels: ["SeLf-HoStEd", "MaCoS", "arm64", "RUNNER-TEST"]),
                    queueJob(2, labels: ["RUNNER-TEST"]), queueJob(3, labels: ["self-hosted", "macOS"]),
                    queueJob(4, labels: ["macos-latest"]), queueJob(5, labels: ["runner-other"]),
                    queueJob(6, labels: ["self-hosted", "X64"]), queueJob(7, runnerID: 21),
                    queueJob(8, status: "in_progress"), queueJob(9, status: "completed"),
                    queueJob(10, runnerID: 22, labels: nil), queueJob(3, labels: ["self-hosted", "macOS"]),
                    queueJob(11, runnerID: 0), queueJob(12, status: "in_progress", runnerID: 0)
                ]])
            }
            return (200, ["jobs": [queueJob(runID, runnerID: state.scenario == "zero-missing-labels" ? 0 : nil,
                labels: ["missing-labels", "zero-missing-labels"].contains(state.scenario) ? nil
                : state.scenario == "empty-labels" ? [] : ["self-hosted", "macOS", "runner-test"])]])
        }
        let headers = code == 429 ? ["Content-Type": "application/json", "Retry-After": "60"] : ["Content-Type": "application/json"]
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        do {
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: payload))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct GitHubQueueTests {
    private func github(_ scenario: String) -> GitHub {
        QueueProtocol.state.withLock { $0 = (scenario, [], true) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueProtocol.self]
        return GitHub(session: URLSession(configuration: configuration), token: "fixture-token")
    }

    @Test func queuePaginatesRunsAndJobsAndDeduplicatesChangingRunStatuses() async throws {
        let jobs = try await github("pagination").queuedJobs(repository: "owner/repo")
        #expect(jobs.map(\.id) == [999])
        let paths = QueueProtocol.state.withLock { $0.paths }
        #expect(paths.contains("/repos/owner/repo/actions/runs?status=queued&per_page=100&page=2"))
        #expect(paths.contains("/repos/owner/repo/actions/runs/101/jobs?per_page=100&page=2"))
        #expect(paths.filter { $0 == "/repos/owner/repo/actions/runs/101/jobs?per_page=100&page=1" }.count == 1)
    }

    @Test func queueIncludesJobsFromEveryActiveRunStatus() async throws {
        let jobs = try await github("all-statuses").queuedJobs(repository: "owner/repo")
        #expect(jobs.map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test func queueMatchesAllEligibleRunnersWithoutHostedOrAssignedJobs() async throws {
        let jobs = try await github("matching").queuedJobs(repository: "owner/repo")
        let runner = try Runner(repository: "owner/repo", name: "Mac", label: "runner-test", execution: .macOSVM)
        let other = try Runner(repository: "owner/repo", name: "Other", label: "runner-other", execution: .macOSVM)
        #expect(jobs.map(\.id) == [1, 2, 3, 4, 5, 6, 11])
        #expect(jobs.filter { GitHub.matchesQueuedJob($0, runner: runner) }.map(\.id) == [1, 2, 3, 11])
        #expect(jobs.filter { GitHub.matchesQueuedJob($0, runner: other) }.map(\.id) == [3, 5])
    }

    @Test(arguments: ["missing-labels", "zero-missing-labels", "empty-labels", "cap", "truncated", "jobs-failure"])
    func uncertainQueuesThrowInsteadOfReturningAnIdleOrPartialResult(scenario: String) async {
        let client = github(scenario)
        await #expect(throws: RunnerError.self) { try await client.queuedJobs(repository: "owner/repo") }
    }

    @Test func queueUsesFreshRequestsAndTheExistingRateLimitCooldown() async throws {
        let client = github("matching")
        #expect(try await !client.queuedJobs(repository: "owner/repo").isEmpty)
        QueueProtocol.state.withLock { $0 = ("empty", [], true) }
        #expect(try await client.queuedJobs(repository: "owner/repo").isEmpty)
        #expect(QueueProtocol.state.withLock { $0.paths.count == 5 && $0.fresh })
        let limited = github("rate-limit")
        for _ in 0..<2 {
            await #expect(throws: RunnerError.self) { try await limited.queuedJobs(repository: "owner/repo") }
        }
        #expect(QueueProtocol.state.withLock { $0.paths.count == 1 })
    }
}
