import AppKit
import SwiftUI
import Testing
@testable import Runner
@testable import RunnerCore

private let start = "2026-10-21T10:00:00Z"
private let finish = "2026-10-21T10:00:03Z"
private let now = Date(timeIntervalSince1970: 1_792_576_810)

@Test(arguments: [-60.0, 0, 86_399, 86_400, 86_401, 172_800])
@MainActor func jobStartShowsDateOnlyAfter24Hours(age: TimeInterval) {
    let started = now.addingTimeInterval(-age)
    let time = started.formatted(date: .omitted, time: .shortened)
    let dateAndTime = started.formatted(date: .abbreviated, time: .shortened)
    let label = JobRow.startedTime(started, at: now)
    #expect(label == (age > 86_400 ? dateAndTime : time))
}

private func progressJob(steps: Any? = nil) throws -> Job {
    var payload: [String: Any] = [
        "id": 10, "name": "Build", "status": "in_progress", "runner_id": 21,
        "html_url": "https://github.com/fixture/repo/actions/jobs/10", "started_at": start
    ]
    payload["steps"] = steps
    return try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: payload))
}

@Test func acceptsAbsentNullAndEmptySteps() throws {
    #expect(try progressJob().steps == nil)
    #expect(try progressJob(steps: NSNull()).steps == nil)
    #expect(try progressJob(steps: []).steps?.isEmpty == true)
}

@Test func decodesStepsWithoutInventingMissingStepsOrTimes() throws {
    let job = try progressJob(steps: [
        ["number": 7, "name": "Build", "status": "queued"],
        ["number": 2, "name": "Build", "status": "completed", "conclusion": "failure",
         "started_at": start, "completed_at": finish],
        ["number": 9, "name": "Cleanup", "status": "completed", "conclusion": "skipped",
         "started_at": NSNull(), "completed_at": NSNull()]
    ])
    let steps = try #require(job.steps)
    #expect(steps.map(\.number) == [7, 2, 9])
    #expect(steps.map(\.name) == ["Build", "Build", "Cleanup"])
    #expect(steps.first?.started_at == nil)
    #expect(steps[1].completed_at == finish)
    #expect(steps[2].conclusion == "skipped")
    #expect(steps[2].completed_at == nil)
}

@Test(arguments: [
    ("2026-10-21T10:00:00Z", "2026-10-21T10:00:03Z", 3.0),
    ("2026-10-21T10:00:00.250Z", "2026-10-21T10:00:03.750Z", 3.5),
    ("2026-10-21T11:00:00.000+01:00", "2026-10-21T10:00:03Z", 3.0),
    ("2026-10-21T10:00:00Z", "2026-10-21T10:00:00Z", 0.0)
])
@MainActor func completedDurationsAreFixed(start: String, end: String, seconds: Double) {
    let display = ActivityDuration(status: "completed", conclusion: "success", startedAt: start, completedAt: end)
    #expect(display.timing(at: now) == .elapsed(seconds))
    #expect(display.timing(at: now.addingTimeInterval(60)) == .elapsed(seconds))
}

@Test @MainActor func onlyLiveRunningWorkGetsATimer() throws {
    let display = ActivityDuration(status: "in_progress", conclusion: nil, startedAt: start, completedAt: nil)
    let date = try #require(ActivityDuration.date(start))
    #expect(display.timing(at: now) == .running(date))
    #expect(display.timing(at: date.addingTimeInterval(-1)) == .unavailable)
    var stale = display
    stale.isLive = false
    #expect(stale.timing(at: now) == .unavailable)
}

@Test(arguments: ["success", "failure", "cancelled", "skipped", "timed_out"])
@MainActor func terminalWorkNeverKeepsTicking(conclusion: String) {
    for status in ["completed", "in_progress"] {
        let missingEnd = ActivityDuration(status: status, conclusion: conclusion, startedAt: start, completedAt: nil)
        #expect(missingEnd.timing(at: now) == .unavailable)
        let ended = ActivityDuration(status: status, conclusion: conclusion, startedAt: start, completedAt: finish, isLive: false)
        #expect(ended.timing(at: now) == .elapsed(3))
    }
}

@Test(arguments: [
    (nil, nil), (nil, finish), ("invalid", finish), (start, "invalid"),
    (start, ""), (start, "2026-10-21T09:59:59Z")
] as [(String?, String?)])
@MainActor func invalidTimesHaveNoDuration(start: String?, end: String?) {
    let display = ActivityDuration(status: "in_progress", conclusion: nil, startedAt: start, completedAt: end)
    #expect(display.timing(at: now) == .unavailable)
}

@Test(arguments: ["queued", "pending", "waiting", "completed", "new_status"])
@MainActor func nonRunningStatesNeverStartATimer(status: String) {
    let display = ActivityDuration(status: status, conclusion: nil, startedAt: start, completedAt: nil)
    #expect(display.timing(at: now) == .unavailable)
}

@Test(arguments: [
    ("in_progress", nil, "Running", "circle.inset.filled"),
    ("queued", nil, "Pending", "circle"),
    ("completed", "success", "Succeeded", "checkmark.circle.fill"),
    ("completed", "failure", "Failed", "xmark.circle.fill"),
    ("completed", "timed_out", "Timed out", "xmark.circle.fill"),
    ("completed", "cancelled", "Cancelled", "minus.circle"),
    ("completed", "skipped", "Skipped", "arrow.right.circle"),
    ("completed", nil, "Completed", "circle"),
    ("new_status", nil, "new_status", "circle"),
    ("completed", "new_result", "new_result", "circle")
] as [(String, String?, String, String)])
func outcomesPreserveReportedResults(status: String, conclusion: String?, label: String, symbol: String) {
    let outcome = ActivityStatus(status: status, conclusion: conclusion)
    #expect(outcome.label == label)
    #expect(outcome.symbol == symbol)
}

@Suite(.serialized) @MainActor
struct ActivityRenderingTests {
    @Test(arguments: [false, true], [false, true])
    func rendersReportedStepsAndStaleProgress(dark: Bool, stale: Bool) async throws {
        _ = NSApplication.shared
        let runner = try RunnerCore.Runner(repository: "fixture/repo", name: "Fixture", label: "fixture", githubID: 21)
        let store = RunnerStore()
        store.runners = [runner]
        store.states[runner.id] = .busy
        let job = try progressJob(steps: [
            ["number": 20, "name": "Deploy", "status": "queued"],
            ["number": 1, "name": "Set up job", "status": "completed", "conclusion": "success", "started_at": start, "completed_at": finish],
            ["number": 7, "name": "Build and test a long project name that should wrap without hiding the status or duration", "status": "in_progress", "started_at": start],
            ["number": 3, "name": "Build", "status": "completed", "conclusion": "failure", "started_at": start, "completed_at": finish],
            ["number": 4, "name": "Build", "status": "completed", "conclusion": "cancelled"],
            ["number": 5, "name": "Optional step", "status": "completed", "conclusion": "skipped"]
        ])
        let run = try JSONDecoder().decode(WorkflowRun.self, from: JSONSerialization.data(withJSONObject: [
            "id": 1, "name": "CI", "head_branch": "main", "head_sha": "abcdef0123", "status": "in_progress",
            "html_url": "https://github.com/fixture/repo/actions/runs/1", "created_at": start, "updated_at": start
        ]))
        store.activity[runner.id] = [RunnerActivity(job: job, run: run)]
        if stale { store.activityIssue[runner.id] = "GitHub is unavailable. Try again when the connection recovers." }
        let view = NSHostingView(rootView: ActivityView(store: store, runner: runner)
            .frame(width: 590, height: 640).background(.background)
            .environment(\.colorScheme, dark ? .dark : .light))
        view.setFrameSize(view.fittingSize)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: view.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(30))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 1000)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("runner-bar-progress-check")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("activity-\(dark ? "dark" : "light")-\(stale ? "stale" : "live").png"))
    }
}
