import Foundation
import MCP
import Synchronization
import Testing
@testable import Runner
@testable import RunnerCore

private let mcpTestToken = String(repeating: "comet-test-credential", count: 3)

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct MCPTests {
    @Test func staysOffUntilEnabledAndRestoresOnlyTheOptIn() async throws {
        let suite = "comet-mcp-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RunnerStore()
        var reads = 0
        var saved: String?
        let server = MCPServer(store: store, defaults: defaults, port: 0, loadToken: {
            reads += 1
            return saved
        }, saveToken: { saved = $0 })
        await server.restore()
        #expect(!server.isEnabled && server.endpoint == nil && server.connectionConfiguration == nil)
        #expect(reads == 0)
        await server.setEnabled(true)
        #expect(server.endpoint != nil && server.error == nil)
        #expect(defaults.bool(forKey: "mcpEnabled"))
        #expect(try #require(saved).count >= 64)
        let originalToken = saved
        await server.stop()
        #expect(server.endpoint == nil && server.connectionConfiguration == nil)
        #expect(defaults.bool(forKey: "mcpEnabled"))
        await server.restore()
        #expect(server.endpoint != nil && saved == originalToken)
        await server.setEnabled(false)
        #expect(!server.isEnabled && !defaults.bool(forKey: "mcpEnabled"))
        await server.restore()
        #expect(server.endpoint == nil && reads == 2)
    }

    @Test func failedStartDoesNotSaveOptInOrExposeConfiguration() async throws {
        let suite = "comet-mcp-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RunnerStore()
        let server = MCPServer(store: store, defaults: defaults, port: 0, loadToken: { nil }, saveToken: { _ in
            throw RunnerError.message("Keychain is unavailable")
        })
        await server.setEnabled(true)
        #expect(!server.isEnabled && !defaults.bool(forKey: "mcpEnabled"))
        #expect(server.error?.contains("Keychain is unavailable") == true)
        #expect(server.endpoint == nil && server.connectionConfiguration == nil)
    }

    @Test func officialClientCanInitializeAndCallTheFourReadOnlyTools() async throws {
        try await withServer { store, server, endpoint in
            let runner = try #require(store.runners.first)
            let other = try Runner(repository: "fixture/other", name: "Other", label: "other")
            store.runners.append(other)
            store.selectedID = other.id
            store.states[runner.id] = .attention
            let secret = "github_pat_" + String(repeating: "s", count: 100)
            store.issues[runner.id] = "Unable to connect with \(secret)"
            store.logs[runner.id] = String(repeating: "output\n", count: 8000) + secret + "\nfinished"
            let originalRunners = store.runners
            let transport = HTTPClientTransport(endpoint: endpoint, streaming: false, requestModifier: { @Sendable request in
                var request = request
                request.setValue("Bearer \(mcpTestToken)", forHTTPHeaderField: "Authorization")
                return request
            })
            let client = Client(name: "Comet integration test", version: "1")
            do {
                let initialized = try await client.connect(transport: transport)
                #expect(initialized.serverInfo.name == "Comet")
                let listed = try await client.listTools()
                #expect(Set(listed.tools.map(\.name)) == ["list_runners", "get_runner", "get_activity", "get_logs"])
                #expect(listed.tools.allSatisfy { $0.annotations.readOnlyHint == true && $0.annotations.destructiveHint == false })
                let list = try await client.callTool(name: "list_runners")
                #expect(try content(list.content).objectValue?["runners"]?.arrayValue?.count == 2)
                let arguments: [String: Value] = ["runner_id": .string(runner.id.uuidString)]
                let details = try await client.callTool(name: "get_runner", arguments: arguments)
                let detail = try #require(try content(details.content).objectValue)
                #expect(detail["state"] == "Needs attention" && detail["state_is_cached"] == true)
                #expect(detail["issue"]?.stringValue?.contains(secret) == false)
                let logs = try await client.callTool(name: "get_logs", arguments: arguments)
                let log = try #require(try content(logs.content).objectValue)
                #expect(log["truncated"] == true && log["cached"] == true)
                #expect(try #require(log["log"]?.stringValue).utf8.count <= MCPDiagnostics.logLimit)
                #expect(log["log"]?.stringValue?.contains(secret) == false)
                #expect(log["log"]?.stringValue?.hasSuffix("[redacted]\nfinished") == true)
                let activity = try await client.callTool(name: "get_activity", arguments: arguments)
                #expect(activity.isError == false)
                let jobs = try #require(try content(activity.content).objectValue?["jobs"]?.arrayValue)
                #expect(jobs.count == 1 && jobs.first?.objectValue?["id"] == 42)
                #expect(jobs.first?.objectValue?["steps"]?.arrayValue?.count == 1)
                #expect(store.selectedID == other.id && store.runners == originalRunners)
                #expect(store.states[runner.id] == .attention && store.operations.isEmpty)
                #expect(MCPGitHubProtocol.requests.withLock { $0.allSatisfy { $0.httpMethod == "GET" } })
                #expect(!FileManager.default.fileExists(atPath: store.paths.root.path))
                let config = try #require(server.connectionConfiguration)
                let json = try JSONDecoder().decode(Value.self, from: Data(config.utf8))
                #expect(json.objectValue?["mcpServers"]?.objectValue?["comet"]?.objectValue?["url"] == .string(endpoint.absoluteString))
                await client.disconnect()
            } catch {
                await client.disconnect()
                throw error
            }
        }
    }

    @Test func HTTPBoundaryRejectsUnauthorizedBrowserAndMalformedRequests() async throws {
        try await withServer { store, _, endpoint in
            let request: Value = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
            #expect(try await send(endpoint, request, token: nil).status == 401)
            #expect(try await send(endpoint, request, token: "wrong").status == 401)
            #expect(try await send(endpoint, request, headers: ["Origin": "https://attacker.example"]).status == 403)
            #expect(try await send(endpoint, request, headers: ["Origin": "null"]).status == 403)
            #expect(try await send(endpoint, request, headers: ["Host": "attacker.example"]).status == 403)
            #expect(try await send(endpoint.appendingPathComponent("other"), request).status == 404)
            #expect(try await send(endpoint, request, method: "GET").status == 405)
            #expect(try await send(endpoint, request, headers: ["Content-Type": "text/plain"]).status == 415)
            #expect(try await send(endpoint, request, headers: ["Accept": "text/plain"]).status == 406)
            #expect(try await send(endpoint, request, headers: ["MCP-Protocol-Version": "unsupported"]).status == 400)
            #expect(try await send(endpoint, ["invalid": true]).status == 400)
            let tooLarge: Value = ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "padding": .string(String(repeating: "x", count: 65536))]
            #expect(try await send(endpoint, tooLarge).status == 413)
            let invalidCalls: [Value] = [
                ["name": "start_runner", "arguments": [:]],
                ["name": "get_runner", "arguments": ["runner_id": "../outside"]],
                ["name": "get_runner", "arguments": ["runner_id": 12]],
                ["name": "get_runner", "arguments": ["runner_id": .string(store.runners[0].id.uuidString), "extra": true]],
                ["name": "list_runners", "arguments": ["extra": true]]
            ]
            for call in invalidCalls {
                let result = try await send(endpoint, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": call])
                #expect(result.value.objectValue?["error"]?.objectValue?["code"] == -32602)
            }
            let unknown = try await send(endpoint, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_runner", "arguments": ["runner_id": .string(UUID().uuidString)]]])
            #expect(unknown.value.objectValue?["result"]?.objectValue?["isError"] == true)
            let requests = MCPGitHubProtocol.requests.withLock { $0 }
            #expect(requests.isEmpty && store.operations.isEmpty)
        }
    }

    @Test func concurrentClientsCanReuseRequestIDsAndDisablingClosesTheListener() async throws {
        try await withServer { _, server, endpoint in
            let request: Value = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<4 { group.addTask { try await send(endpoint, request).status } }
                for try await status in group { #expect(status == 200) }
            }
            await server.setEnabled(false)
            #expect(server.endpoint == nil && server.connectionConfiguration == nil)
            do {
                _ = try await send(endpoint, request)
                Issue.record("Disabled MCP server still accepted a connection")
            } catch { #expect(error is URLError) }
        }
    }

    @Test func disablingCancelsAnInFlightActivityFetch() async throws {
        try await withServer { store, server, endpoint in
            MCPGitHubProtocol.hold.withLock { $0 = true }
            let runner = try #require(store.runners.first)
            let request = Task {
                try await send(endpoint, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
                    "name": "get_activity", "arguments": ["runner_id": .string(runner.id.uuidString)]
                ]])
            }
            for _ in 0..<100 {
                if MCPGitHubProtocol.requests.withLock({ !$0.isEmpty }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(MCPGitHubProtocol.requests.withLock { $0.count } == 1)
            let started = ContinuousClock.now
            await server.setEnabled(false)
            #expect(started.duration(to: .now) < .seconds(2))
            do {
                _ = try await request.value
                Issue.record("An in-flight request returned data after MCP was disabled")
            } catch { #expect(error is URLError) }
            for _ in 0..<100 {
                if MCPGitHubProtocol.cancellations.withLock({ $0 > 0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(MCPGitHubProtocol.cancellations.withLock { $0 } == 1)
            #expect(store.runners == [runner] && store.operations.isEmpty)
        }
    }

    @Test func unavailableActivityAndMissingLogsAreExplicit() async throws {
        try await withServer { store, _, _ in
            let runner = try #require(store.runners.first)
            let arguments: [String: Value] = ["runner_id": .string(runner.id.uuidString)]
            store.signedIn = false
            let activity = try await MCPDiagnostics.call(.init(name: "get_activity", arguments: arguments), store: store)
            #expect(activity.isError == true)
            let logs = try await MCPDiagnostics.call(.init(name: "get_logs", arguments: arguments), store: store)
            #expect(logs.structuredContent?.objectValue?["available"] == false)
            #expect(MCPGitHubProtocol.requests.withLock { $0.isEmpty })
        }
    }

    @Test func anOccupiedPortLeavesExistingServerIntact() async throws {
        try await withServer { store, _, endpoint in
            let suite = "comet-mcp-conflict-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let conflicting = MCPServer(store: store, defaults: defaults, port: try #require(endpoint.port),
                                        loadToken: { mcpTestToken }, saveToken: { _ in })
            await conflicting.setEnabled(true)
            #expect(conflicting.endpoint == nil && conflicting.error != nil && !conflicting.isEnabled)
            #expect(!defaults.bool(forKey: "mcpEnabled"))
            #expect(try await send(endpoint, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]).status == 200)
        }
    }
}

@MainActor
private func withServer(_ test: (RunnerStore, MCPServer, URL) async throws -> Void) async throws {
    let suite = "comet-mcp-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    MCPGitHubProtocol.requests.withLock { $0 = [] }
    MCPGitHubProtocol.hold.withLock { $0 = false }
    MCPGitHubProtocol.cancellations.withLock { $0 = 0 }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MCPGitHubProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let paths = AppPaths(root: .temporaryDirectory.appendingPathComponent(suite))
    let store = RunnerStore(github: GitHub(session: session, token: "fixture-token"), paths: paths)
    store.runners = [try Runner(repository: "fixture/repo", name: "Mac", label: "mac", githubID: 7)]
    store.signedIn = true
    let server = MCPServer(store: store, defaults: defaults, port: 0,
                           loadToken: { mcpTestToken }, saveToken: { _ in Issue.record("Should reuse the saved credential") })
    await server.setEnabled(true)
    do {
        #expect(server.error == nil)
        let endpoint = try #require(server.endpoint.flatMap(URL.init(string:)))
        try await test(store, server, endpoint)
        await server.stop()
    } catch {
        await server.stop()
        throw error
    }
}

private func content(_ content: [Tool.Content]) throws -> Value {
    guard case .text(let text, _, _) = try #require(content.first) else {
        Issue.record("Expected text content")
        return .null
    }
    return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
}

private func send(_ endpoint: URL, _ value: Value, token: String? = mcpTestToken,
                  method: String = "POST", headers: [String: String] = [:]) async throws -> (status: Int, value: Value) {
    var request = URLRequest(url: endpoint)
    request.httpMethod = method
    request.timeoutInterval = 5
    if method == "POST" { request.httpBody = try JSONEncoder().encode(value) }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await URLSession.shared.data(for: request)
    return (try #require(response as? HTTPURLResponse).statusCode,
            data.isEmpty ? .null : try JSONDecoder().decode(Value.self, from: data))
}

private final class MCPGitHubProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    static let hold = Mutex(false)
    static let cancellations = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        if Self.hold.withLock({ $0 }) { return }
        let payload: String
        if request.url?.path.hasSuffix("/jobs") == true {
            payload = #"{"jobs":[{"id":42,"name":"Build","status":"in_progress","runner_id":7,"html_url":"https://github.com/fixture/repo/actions/runs/1/job/42","steps":[{"number":1,"name":"Checkout","status":"completed","conclusion":"success"}]},{"id":43,"name":"Other runner","status":"completed","runner_id":8,"html_url":"https://github.com/fixture/repo/actions/runs/1/job/43"}]}"#
        } else {
            payload = #"{"workflow_runs":[{"id":1,"name":"CI","head_branch":"main","head_sha":"abcdef0","status":"in_progress","html_url":"https://github.com/fixture/repo/actions/runs/1","created_at":"2026-10-22T10:00:00Z","updated_at":"2026-10-22T10:01:00Z"}]}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.cancellations.withLock { $0 += 1 } }
}
