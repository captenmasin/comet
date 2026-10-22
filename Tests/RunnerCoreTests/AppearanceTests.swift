import AppKit
import SwiftUI
import Testing
@testable import Runner
@testable import RunnerCore

@Suite(.serialized) @MainActor
struct AppearanceTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func compactStopShowsJobActivity(scheme: ColorScheme) async throws {
        _ = NSApplication.shared
        let runner = try RunnerCore.Runner(repository: "fixture/repo", name: "Mac", label: "fixture",
                                           execution: .macOSVM, watchForJobs: true)
        let store = RunnerStore()
        store.runners = [runner]
        let view = NSHostingView(rootView: RunnerControl(store: store, runner: runner, compact: true)
            .frame(width: 32, height: 32).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme))
        view.setFrameSize(CGSize(width: 32, height: 32))
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var images: [Data] = []
        for state in [RunnerState.ready, .busy, .ready] {
            store.states[runner.id] = state
            try await Task.sleep(for: .milliseconds(30))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            images.append(try #require(bitmap.representation(using: .png, properties: [:])))
        }
        #expect(images[0] != images[1])
        #expect(images[0] == images[2])
    }

    @Test(arguments: [
        ([RunnerState](), RunnerState.stopped), ([.stopped], .stopped),
        ([.ready, .stopped], .ready), ([.ready, .busy], .busy),
        ([.busy, .starting], .busy), ([.ready, .starting], .starting),
        ([.ready, .stopping], .stopping), ([.ready, .reconnecting], .reconnecting),
        ([.attention, .busy], .attention), ([.sleeping, .stopped], .sleeping), ([.sleeping, .ready], .ready)
    ])
    func menuBarSummarizesAllRunners(states: [RunnerState], expected: RunnerState) throws {
        let store = RunnerStore()
        for (index, state) in states.enumerated() {
            let runner = try RunnerCore.Runner(repository: "fixture/runner-\(index)", name: "Mac-\(index)", label: "fixture")
            store.runners.append(runner)
            store.states[runner.id] = state
        }
        // Removed runners must not leave a stale warning in the menu bar.
        store.states[UUID()] = .attention
        store.states[UUID()] = .busy
        #expect(store.menuBarState == expected)
        #expect(store.hasRunningJobs == states.contains(.busy))
        #expect(store.hasFailures == states.contains(.attention))
        store.runners.reverse()
        #expect(store.menuBarState == expected)
    }

    @Test(arguments: ["failure", "timed_out", "startup_failure", "success", "cancelled", "skipped"])
    func menuBarBadgesTheLatestCompletedJob(conclusion: String) throws {
        let store = RunnerStore()
        let runner = try RunnerCore.Runner(repository: "fixture/repo", name: "Mac", label: "fixture")
        store.runners = [runner]
        store.states[runner.id] = .busy
        let job = try JSONDecoder().decode(Job.self, from: Data("""
            {"id":1,"name":"Build","status":"completed","conclusion":"\(conclusion)",
             "html_url":"https://github.com/fixture/repo/actions/jobs/1"}
            """.utf8))
        let run = try JSONDecoder().decode(WorkflowRun.self, from: Data("""
            {"id":1,"head_sha":"abc","status":"completed","html_url":"https://github.com/fixture/repo/actions/runs/1",
             "created_at":"2026-10-22T10:00:00Z","updated_at":"2026-10-22T10:01:00Z"}
            """.utf8))
        let oldFailure = try JSONDecoder().decode(Job.self, from: Data("""
            {"id":0,"name":"Older build","status":"completed","conclusion":"failure",
             "html_url":"https://github.com/fixture/repo/actions/jobs/0"}
            """.utf8))
        store.activity[runner.id] = [RunnerActivity(job: job, run: run), RunnerActivity(job: oldFailure, run: run)]
        let failed = ["failure", "timed_out", "startup_failure"].contains(conclusion)
        #expect(store.hasFailures == failed)
        #expect(store.menuBarState == (failed ? .attention : .busy))
        #expect(store.hasRunningJobs)
        store.activity[runner.id] = []
        #expect(!store.hasFailures)
        store.runners = []
        store.activity[runner.id] = [RunnerActivity(job: job, run: run)]
        #expect(!store.hasFailures)
    }

    @Test func menuBarClearsResolvedErrors() throws {
        let store = RunnerStore()
        let runner = try RunnerCore.Runner(repository: "fixture/repo", name: "Mac", label: "fixture")
        store.runners = [runner]
        store.error = "Setup failed"
        #expect(store.hasFailures && store.menuBarState == .attention)
        store.error = nil
        store.issues[runner.id] = "Runner disconnected"
        #expect(store.hasFailures)
        store.issues[runner.id] = nil
        store.activityIssue[runner.id] = "GitHub unavailable"
        #expect(store.hasFailures)
        store.activityIssue[runner.id] = nil
        #expect(!store.hasFailures)
    }

    @Test(arguments: [RunnerState.starting, .stopped, .reconnecting])
    func setupProgressDoesNotShowAFailure(state: RunnerState) throws {
        let store = RunnerStore()
        let runner = try RunnerCore.Runner(repository: "fixture/repo", name: "Mac", label: "fixture")
        store.runners = [runner]
        store.states[runner.id] = state
        store.operations.insert(runner.id)
        store.issues[runner.id] = "Preparing the VM workspace…"
        #expect(!store.hasFailures)
        #expect(store.menuBarState == state)
        store.states[runner.id] = .attention
        #expect(store.hasFailures)
        store.states[runner.id] = state
        store.activityIssue[runner.id] = "GitHub unavailable"
        #expect(store.hasFailures)
        store.activityIssue[runner.id] = nil
        store.error = "Setup failed"
        #expect(store.hasFailures)
        store.error = nil
        store.operations.remove(runner.id)
        #expect(store.hasFailures)
        store.issues[runner.id] = nil
        #expect(!store.hasFailures)
    }

    @Test(arguments: ["success", "failure", "cancelled", "skipped"], [0.0, 119, 120, 121, -1])
    func menuBarSuccessUsesTheJobCompletionTime(conclusion: String, age: TimeInterval) throws {
        let now = Date(timeIntervalSince1970: 1_792_670_400)
        let store = RunnerStore(now: { now })
        let runner = try RunnerCore.Runner(repository: "fixture/repo", name: "Mac", label: "fixture")
        store.runners = [runner]
        let completed = now.addingTimeInterval(-age)
        let job = try JSONDecoder().decode(Job.self, from: Data("""
            {"id":1,"name":"Build","status":"completed","conclusion":"\(conclusion)",
             "completed_at":"\(completed.ISO8601Format())","html_url":"https://github.com/fixture/repo/actions/jobs/1"}
            """.utf8))
        let run = try JSONDecoder().decode(WorkflowRun.self, from: Data("""
            {"id":1,"head_sha":"abc","status":"completed","html_url":"https://github.com/fixture/repo/actions/runs/1",
             "created_at":"2026-10-22T10:00:00Z","updated_at":"2026-10-22T10:01:00Z"}
            """.utf8))
        store.activity[runner.id] = [RunnerActivity(job: job, run: run)]
        #expect(store.successExpiresAt == (conclusion == "success" && age >= 0
            ? completed.addingTimeInterval(120) : nil))
        #expect(((store.successExpiresAt ?? .distantPast) > now)
            == (conclusion == "success" && age >= 0 && age < 120))
        store.runners = []
        #expect(store.successExpiresAt == nil)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func accentHasReadableContrast(scheme: ColorScheme) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let accent = runnerAccent.resolve(in: environment)
        #expect(accent.opacity == 1)
        for background in [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)] {
            let surface = background.resolve(in: environment)
            let foregroundLuminance = luminance(accent)
            let backgroundLuminance = luminance(surface)
            let contrast = (max(foregroundLuminance, backgroundLuminance) + 0.05)
                / (min(foregroundLuminance, backgroundLuminance) + 0.05)
            #expect(contrast >= 4.5)
        }
        var otherAppearance = environment
        otherAppearance.colorScheme = scheme == .dark ? .light : .dark
        #expect(accent != runnerAccent.resolve(in: otherAppearance))
        #expect(RunnerState.busy.color.resolve(in: environment) == accent)
    }

    @Test(arguments: [false, true], [false, true])
    func compactScreensFitBothAppearances(dark: Bool, increasedContrast: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RunnerStore(paths: AppPaths(root: root))
        let runners = try ["a-repository-with-a-long-name-that-must-not-hide-the-runner-controls", "ready", "attention"].map {
            try RunnerCore.Runner(repository: "fixture/\($0)", name: "Mac-\($0.prefix(48))", label: "fixture")
        }
        store.runners = runners
        store.selectedID = runners[0].id
        store.states = [runners[0].id: .busy, runners[1].id: .ready, runners[2].id: .attention]
        let appearance: NSAppearance.Name = increasedContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        let screens: [(String, AnyView, CGSize)] = [
            ("popover", AnyView(RunnerPopover(store: store)), CGSize(width: 380, height: 340)),
            ("main", AnyView(MainWindow(store: store)), CGSize(width: 800, height: 570)),
            ("setup", AnyView(SetupView(store: store)), CGSize(width: 560, height: 460))
        ]
        for (name, screen, size) in screens {
            let view = NSHostingView(rootView: screen.background(name == "popover" ? Color.clear : Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            defer { window.close() }
            view.setFrameSize(size)
            try await Task.sleep(for: .milliseconds(50))
            view.layoutSubtreeIfNeeded()
            if name == "main" {
                func descendants(_ node: NSView) -> [NSView] { [node] + node.subviews.flatMap(descendants) }
                let content = try #require(descendants(view).compactMap { $0 as? NSScrollView }
                    .max { $0.convert($0.bounds, to: view).midX < $1.convert($1.bounds, to: view).midX })
                let frame = content.convert(content.bounds, to: view)
                let bottomGap = view.isFlipped ? view.bounds.maxY - frame.maxY : frame.minY - view.bounds.minY
                #expect(abs(bottomGap) < 1)
            }
            let minimum = NSHostingController(rootView: screen).sizeThatFits(in: size)
            #expect(minimum.width <= size.width)
            #expect(minimum.height <= size.height)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if name == "popover" {
                // The popover itself must block the desktop behind its text.
                let surface = try #require(bitmap.colorAt(x: 2, y: 2))
                #expect(surface.alphaComponent >= 0.99)
            }
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(data.count > 1000)
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("comet-appearance-check")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light")-\(increasedContrast ? "contrast" : "standard").png"))
        }
    }

    private func luminance(_ color: Color.Resolved) -> Float {
        0.2126 * color.linearRed + 0.7152 * color.linearGreen + 0.0722 * color.linearBlue
    }
}
