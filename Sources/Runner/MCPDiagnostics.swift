import Foundation
import MCP
import RunnerCore

@MainActor
enum MCPDiagnostics {
    static let logLimit = 32 * 1024
    static let tools: [Tool] = [
        tool("list_runners", "List Comet’s configured runners and last observed states. Does not refresh or start runners.", runner: false),
        tool("get_runner", "Read a runner’s configuration, last observed state and issues. Does not refresh or start it."),
        tool("get_activity", "Fetch jobs assigned to this runner from the repository’s 10 latest workflow runs, up to 20 jobs with 100 steps each. Does not change the app selection."),
        tool("get_logs", "Read the last 32 KiB of Comet’s cached, redacted local runner output. This is not the complete GitHub job log.")
    ]

    private static func tool(_ name: String, _ description: String, runner: Bool = true) -> Tool {
        Tool(name: name, description: description, inputSchema: .object([
            "type": "object",
            "properties": runner ? .object(["runner_id": .object([
                "type": "string", "description": "Runner UUID returned by list_runners."
            ])]) : .object([:]),
            "required": runner ? .array(["runner_id"]) : .array([]),
            "additionalProperties": false
        ]), annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true,
                              openWorldHint: name == "get_activity"))
    }

    static func call(_ parameters: CallTool.Parameters, store: RunnerStore) async throws -> CallTool.Result {
        guard tools.contains(where: { $0.name == parameters.name }) else {
            throw MCPError.invalidParams("Unknown diagnostic tool.")
        }
        let arguments = parameters.arguments ?? [:]
        let payload: Value
        if parameters.name == "list_runners" {
            guard arguments.isEmpty else { throw MCPError.invalidParams("This tool takes no arguments.") }
            payload = .object(["runners": .array(store.runners.map { runner($0, store: store) })])
        } else {
            guard arguments.count == 1, let rawID = arguments["runner_id"]?.stringValue,
                  let id = UUID(uuidString: rawID) else {
                throw MCPError.invalidParams("Provide only runner_id, as a runner UUID.")
            }
            guard let configured = store.runners.first(where: { $0.id == id }) else {
                return failure("This runner is no longer configured. Call list_runners again.")
            }
            switch parameters.name {
            case "get_runner":
                payload = runner(configured, store: store)
            case "get_logs":
                let log = RunnerProcess.sanitized(store.logs[id] ?? "")
                payload = .object([
                    "runner_id": .string(id.uuidString), "cached": true,
                    "available": .bool(store.logs[id] != nil),
                    "log": .string(RunnerProcess.bounded(log, limit: logLimit)),
                    "truncated": .bool(log.utf8.count > logLimit)
                ])
            default:
                guard store.signedIn else { return failure("Connect GitHub in Comet to fetch activity.") }
                do {
                    let activity = try await store.github.activity(configured)
                    try Task.checkCancellation()
                    guard store.runners.contains(configured) else {
                        return failure("The runner changed while activity was loading. Call list_runners again.")
                    }
                    payload = .object([
                        "runner_id": .string(id.uuidString),
                        "fetched_at": .string(Date().ISO8601Format()),
                        "registered": .bool(configured.githubID != nil),
                        "scope": "Assigned jobs from the repository’s 10 latest workflow runs; at most 20 jobs and 100 steps per job.",
                        "truncated": .bool(activity.count > 20 || activity.prefix(20).contains { ($0.job.steps?.count ?? 0) > 100 }),
                        "jobs": .array(activity.prefix(20).map(job))
                    ])
                } catch is CancellationError { throw CancellationError() }
                catch { return failure(error.localizedDescription) }
            }
        }
        let data = try JSONEncoder().encode(payload)
        guard data.count <= 512 * 1024 else { return failure("The diagnostic response is too large to return.") }
        return CallTool.Result(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                               structuredContent: Optional.some(payload), isError: false)
    }

    private static func runner(_ runner: Runner, store: RunnerStore) -> Value {
        .object([
            "id": .string(runner.id.uuidString), "name": .string(runner.name),
            "repository": .string(runner.repository), "label": .string(runner.label),
            "execution": .string(runner.execution.rawValue),
            "github_id": runner.githubID.map(Value.int) ?? .null,
            "state": .string(store.state(runner).rawValue), "state_is_cached": true,
            "context": .string(store.state(runner).context), "issue": text(store.issues[runner.id]),
            "operation_in_progress": .bool(store.operations.contains(runner.id)),
            "watch_for_jobs": .bool(runner.watchForJobs), "run_automatically": .bool(runner.runAutomatically)
        ])
    }

    private static func job(_ activity: RunnerActivity) -> Value {
        let job = activity.job
        let run = activity.run
        return .object([
            "id": .int(job.id), "name": text(job.name), "status": text(job.status),
            "conclusion": text(job.conclusion), "url": text(job.html_url.absoluteString),
            "started_at": text(job.started_at), "completed_at": text(job.completed_at),
            "run": .object([
                "id": .int(run.id), "name": text(run.name), "branch": text(run.head_branch),
                "sha": text(run.head_sha), "status": text(run.status), "conclusion": text(run.conclusion),
                "url": text(run.html_url.absoluteString)
            ]),
            "steps": .array((job.steps ?? []).prefix(100).map { step in .object([
                "number": .int(step.number), "name": text(step.name), "status": text(step.status),
                "conclusion": text(step.conclusion), "started_at": text(step.started_at),
                "completed_at": text(step.completed_at)
            ]) })
        ])
    }

    private static func text(_ value: String?) -> Value {
        value.map { .string(RunnerProcess.bounded(RunnerProcess.sanitized($0), limit: 1024)) } ?? .null
    }

    private static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: RunnerProcess.bounded(RunnerProcess.sanitized(message), limit: 2048), annotations: nil, _meta: nil)], isError: true)
    }
}
