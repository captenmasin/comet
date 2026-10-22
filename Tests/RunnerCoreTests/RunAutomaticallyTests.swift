import Foundation
import Testing
@testable import Runner
@testable import RunnerCore

@Test(arguments: RunnerExecution.allCases)
func automaticRunPreferenceSurvivesSavingAndDefaultsOffForOldConfiguration(execution: RunnerExecution) throws {
    let runner = try Runner(repository: "fixture/repo", name: "Mac", label: "test", execution: execution, runAutomatically: true)
    let data = try JSONEncoder().encode(runner)
    #expect(try JSONDecoder().decode(Runner.self, from: data) == runner)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "runAutomatically")
    let decoded = try JSONDecoder().decode(Runner.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(!decoded.runAutomatically)
}

@Test @MainActor func automaticRunSettingCommitsOnlyAfterSaving() async throws {
    let paths = AppPaths(root: .temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let runner = try Runner(repository: "fixture/repo", name: "Mac", label: "test")
    try paths.save([runner])
    let store = RunnerStore(paths: paths, restore: { false })
    store.setRunAutomatically(true, for: runner)
    #expect(try paths.load() == [runner])
    await store.load()
    #expect(await store.shutdown())
    store.setRunAutomatically(true, for: runner)
    #expect(store.runners.first?.runAutomatically == true)
    #expect(try paths.load() == store.runners)
    store.operations.insert(runner.id)
    store.setRunAutomatically(false, for: runner)
    #expect(store.runners.first?.runAutomatically == true)
    store.operations.remove(runner.id)
    store.setRunAutomatically(false, for: runner)
    #expect(try paths.load() == [runner])
    let config = paths.root.appendingPathComponent("runners.json")
    try FileManager.default.removeItem(at: config)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
    store.setRunAutomatically(true, for: runner)
    #expect(store.runners == [runner])
    #expect(store.error != nil)
}
