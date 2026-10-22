import Foundation
import Testing
@testable import Runner
@testable import RunnerCore

@MainActor @Test
func updateInstallationWaitsForRunnersAndOperations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RunnerStore(paths: AppPaths(root: root), restore: { false })
    #expect(!store.canInstallUpdate)
    await store.load()
    #expect(store.canInstallUpdate)
    let runner = try Runner(repository: "fixture/repo", name: "fixture", label: "fixture", execution: .macOSVM, watchForJobs: true)
    store.runners = [runner]
    #expect(!store.canInstallUpdate)
    var installed = false
    #expect(store.updates.postponeInstallation { installed = true })
    #expect(store.updates.waitingForRunners)
    await Task.yield()
    #expect(!installed)
    store.runners[0].watchForJobs = false
    store.operations.insert(runner.id)
    #expect(!store.canInstallUpdate)
    store.operations.remove(runner.id)
    store.states[runner.id] = .busy
    #expect(!store.canInstallUpdate)
    store.states[runner.id] = .stopped
    for _ in 0..<150 where !installed { try await Task.sleep(for: .milliseconds(10)) }
    #expect(installed)
    #expect(!store.updates.waitingForRunners)
    #expect(!store.updates.postponeInstallation {})
    #expect(await store.shutdown())
}

@MainActor @Test
func abortedUpdateDoesNotInstallLater() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RunnerStore(paths: AppPaths(root: root), restore: { false })
    await store.load()
    let operation = UUID()
    store.operations.insert(operation)
    var installed = false
    #expect(store.updates.postponeInstallation { installed = true })
    store.updates.cancelPendingInstallation()
    store.operations.remove(operation)
    try await Task.sleep(for: .milliseconds(20))
    #expect(!installed)
    #expect(!store.updates.waitingForRunners)
    #expect(await store.shutdown())
}
