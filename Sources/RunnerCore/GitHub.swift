import Foundation
import Security

public enum Keychain {
    private static func query(service: String, account: String) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account
    ] }
    public static func load(service: String = "dev.runnerbar.github", account: String = "account") throws -> String? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        guard let token = String(data: data, encoding: .utf8) else { throw RunnerError.message("Stored GitHub token could not be read. Replace it in Settings.") }
        return token
    }
    public static func save(_ token: String, service: String = "dev.runnerbar.github", account: String = "account") throws {
        let query = query(service: service, account: account)
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> RunnerError {
        .message("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "Unable to access credentials")")
    }
}

public actor GitHub {
    private let session: URLSession
    private var token: String?
    private var completedJobs: [String: [Int: (revision: String, jobs: [Job])]] = [:]
    private var retryAfter: [Bool: Date] = [:]
    public init(session: URLSession = .shared) { self.session = session }
    init(session: URLSession, token: String) {
        self.session = session
        self.token = token
    }
    public func restore() throws -> Bool {
        token = try Keychain.load()
        return token != nil
    }

    public static func validateToken(_ token: String) throws {
        guard !token.isEmpty, token.utf8.count <= 1024, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw RunnerError.message("Paste a valid GitHub personal access token without spaces or line breaks.")
        }
    }

    public func connect(token candidate: String) async throws -> String {
        try Self.validateToken(candidate)
        let user = try await user(token: candidate)
        try Task.checkCancellation()
        try Keychain.save(candidate)
        token = candidate
        completedJobs.removeAll()
        return user
    }

    private func user(token: String) async throws -> String {
        struct User: Decodable { let login: String }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Comet/0.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try JSONDecoder().decode(User.self, from: data).login
    }

    public func request<T: Decodable & Sendable>(_ path: String, method: String = "GET", authenticated: Bool = true) async throws -> T {
        try Task.checkCancellation()
        if let retryAfter = retryAfter[authenticated], retryAfter > Date() {
            throw RunnerError.message("GitHub is rate limiting requests. Wait before retrying.")
        }
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Comet/0.1", forHTTPHeaderField: "User-Agent")
        if authenticated {
            guard let token else { throw RunnerError.message("Connect a GitHub personal access token first.") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse {
            let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
            let retry = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
            let message = http.statusCode == 403 ?
                (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String : nil
            if remaining == "0" || http.statusCode == 429 ||
                (http.statusCode == 403 && (retry != nil || message?.localizedCaseInsensitiveContains("rate limit") == true)) {
                let deadline: Date
                if remaining == "0", let reset {
                    deadline = max(Date(timeIntervalSince1970: reset), Date().addingTimeInterval(retry ?? 0))
                } else { deadline = Date().addingTimeInterval(retry ?? 60) }
                retryAfter[authenticated] = max(retryAfter[authenticated] ?? .distantPast, deadline)
            }
        }
        try Self.validate(response)
        if T.self == Empty.self { return Empty() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RunnerError.message("No response from GitHub.") }
        guard (200..<300).contains(http.statusCode) else {
            let hint: String = switch http.statusCode {
            case 401: "Replace your GitHub token in Settings; it may have expired or been revoked."
            case 403: "Check repository admin access and the token’s Administration permission. GitHub may also be rate limiting requests."
            case 404: "Check the token’s selected repositories, resource owner, and Administration permission. Organization tokens may need approval."
            case 429: "GitHub is rate limiting requests. Wait before retrying."
            default: "Try again when the connection recovers."
            }
            throw RunnerError.message("GitHub returned \(http.statusCode). \(hint)")
        }
    }

    public func repositories() async throws -> [Repository] {
        var result: [Repository] = []
        var page = 1
        while true {
            let batch: [Repository] = try await request("/user/repos?per_page=100&page=\(page)&sort=full_name&affiliation=owner,organization_member,collaborator")
            result += batch.filter { $0.permissions?.admin == true }
            if batch.count < 100 { break }
            page += 1
        }
        return result.sorted { $0.full_name.localizedStandardCompare($1.full_name) == .orderedAscending }
    }

    public func runners(repository: String) async throws -> [RemoteRunner] {
        struct Response: Decodable, Sendable { let runners: [RemoteRunner] }
        var result: [RemoteRunner] = []
        var page = 1
        while true {
            let batch: Response = try await request("/repos/\(repository)/actions/runners?per_page=100&page=\(page)")
            result += batch.runners
            if batch.runners.count < 100 { return result }
            page += 1
        }
    }

    public func registrationToken(repository: String) async throws -> String {
        struct Response: Decodable, Sendable { let token: String }
        let response: Response = try await request("/repos/\(repository)/actions/runners/registration-token", method: "POST")
        return response.token
    }

    public func remove(_ runner: Runner) async throws {
        guard let id = runner.githubID else { throw RunnerError.message("Recover the runner’s registration before removing it.") }
        // A successful list proves access, so a missing registration is safe to forget locally.
        guard try await runners(repository: runner.repository).contains(where: { $0.id == id }) else { return }
        let _: Empty = try await request("/repos/\(runner.repository)/actions/runners/\(id)", method: "DELETE")
    }

    public func queuedJobs(repository: String) async throws -> [Job] {
        struct Runs: Decodable, Sendable {
            let total_count: Int
            let workflow_runs: [WorkflowRun]
        }
        let credential = token
        var result: [Job] = []
        var seenRuns: Set<Int> = []
        var seenJobs: Set<Int> = []
        for status in ["queued", "in_progress", "waiting", "pending", "requested"] {
            var page = 1
            while true {
                let batch: Runs = try await request("/repos/\(repository)/actions/runs?status=\(status)&per_page=100&page=\(page)")
                // GitHub caps filtered workflow-run searches at 1,000 results.
                guard (0...1000).contains(batch.total_count) else {
                    throw RunnerError.message("GitHub returned too many active workflow runs to check the queue safely for \(repository).")
                }
                guard batch.workflow_runs.count == min(100, max(0, batch.total_count - (page - 1) * 100)) else {
                    throw RunnerError.message("GitHub returned an incomplete workflow-run page. The queue could not be checked safely.")
                }
                for run in batch.workflow_runs where seenRuns.insert(run.id).inserted {
                    for job in try await jobs(repository: repository, runID: run.id)
                        where job.status == "queued" && (job.runner_id ?? 0) == 0 {
                        guard let labels = job.labels, !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty }) else {
                            throw RunnerError.message("GitHub did not provide labels for a queued job. The queue could not be checked safely.")
                        }
                        if seenJobs.insert(job.id).inserted { result.append(job) }
                    }
                }
                if batch.workflow_runs.count < 100 || page * 100 >= batch.total_count { break }
                page += 1
            }
        }
        try Task.checkCancellation()
        guard credential == token else { throw CancellationError() }
        return result
    }

    public static func matchesQueuedJob(_ job: Job, runner: Runner) -> Bool {
        guard job.status == "queued", (job.runner_id ?? 0) == 0,
              let labels = job.labels, !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        let available = Set(["self-hosted", "macos", "arm64", runner.label.lowercased()])
        return Set(labels.map { $0.lowercased() }).isSubset(of: available)
    }

    public func activity(_ runner: Runner) async throws -> [RunnerActivity] {
        guard runner.githubID != nil else { return [] }
        struct Runs: Decodable, Sendable { let workflow_runs: [WorkflowRun] }
        let credential = token
        let runs: Runs = try await request("/repos/\(runner.repository)/actions/runs?per_page=10")
        let cache = completedJobs[runner.repository] ?? [:]
        let jobsByRun = try await withThrowingTaskGroup(of: (Int, [Job]).self) { group in
            var result = [[Job]](repeating: [], count: runs.workflow_runs.count)
            var pending = 0
            for (index, run) in runs.workflow_runs.enumerated() {
                if run.status == "completed", let cached = cache[run.id], cached.revision == run.updated_at {
                    result[index] = cached.jobs
                } else {
                    if pending == 3, let (finished, jobs) = try await group.next() {
                        result[finished] = jobs
                        pending -= 1
                    }
                    try Task.checkCancellation()
                    group.addTask { (index, try await self.jobs(repository: runner.repository, runID: run.id)) }
                    pending += 1
                }
            }
            for try await (index, jobs) in group { result[index] = jobs }
            return result
        }
        try Task.checkCancellation()
        guard credential == token else { throw CancellationError() }
        var result: [RunnerActivity] = []
        var nextCache: [Int: (revision: String, jobs: [Job])] = [:]
        for (run, jobs) in zip(runs.workflow_runs, jobsByRun) {
            if run.status == "completed" {
                nextCache[run.id] = (run.updated_at, jobs)
            }
            result += jobs.filter { $0.runner_id == runner.githubID }.map { RunnerActivity(job: $0, run: run) }
        }
        completedJobs[runner.repository] = nextCache
        return result
    }

    private func jobs(repository: String, runID: Int) async throws -> [Job] {
        struct Jobs: Decodable, Sendable { let jobs: [Job] }
        var result: [Job] = []
        var page = 1
        while true {
            let batch: Jobs = try await request("/repos/\(repository)/actions/runs/\(runID)/jobs?per_page=100&page=\(page)")
            result += batch.jobs
            if batch.jobs.count < 100 { return result }
            page += 1
        }
    }
}

public struct Empty: Decodable, Sendable {}
