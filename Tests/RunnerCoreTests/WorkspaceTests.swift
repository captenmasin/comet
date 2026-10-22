import Foundation
import Darwin
import Testing
@testable import RunnerCore
@testable import Runner

@Test(arguments: [false, true]) @MainActor
func unavailableWorkspaceShowsAnError(invalidFile: Bool) throws {
    let temporary = URL.temporaryDirectory.appendingPathComponent("comet-reveal-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let paths = AppPaths(root: temporary)
    let runner = try RunnerCore.Runner(repository: "fixture/repo", name: "Mac", label: "fixture")
    let directory = paths.directory(runner.id)
    if invalidFile {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: directory)
    }
    let store = RunnerStore(paths: paths)

    store.showWorkspace(for: runner)

    #expect(store.error?.contains("workspace folder is unavailable") == true)
    #expect(store.error?.contains(directory.path) == true)
    if invalidFile { #expect(try String(contentsOf: directory, encoding: .utf8) == "preserve") }
    else { #expect(!FileManager.default.fileExists(atPath: directory.path)) }
}

@Test func defaultRunnerPathsAvoidApplicationSupport() {
    let id = UUID()
    let paths = AppPaths()
    #expect(paths.directory(id) == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".comet/runners/\(id.uuidString)"))
    #expect(!paths.directory(id).path.contains("Application Support"))
}

@Test func runnerMigrationPreservesRegistrationCredentialsWorkspaceAndIdentity() throws {
    let files = FileManager.default
    let temporary = URL.temporaryDirectory.appendingPathComponent("comet-migration-\(UUID())")
    defer { try? files.removeItem(at: temporary) }
    let settings = temporary.appendingPathComponent("Application Support/RunnerBar")
    let original = AppPaths(root: settings)
    let runner = try Runner(repository: "owner/repo", name: "Mac", label: "runner-test", githubID: 23)
    try original.save([runner])
    let directory = original.directory(runner.id)
    try files.createDirectory(at: directory.appendingPathComponent("_work"), withIntermediateDirectories: true)
    let contents = [".runner": #"{"agentId":23,"workFolder":"_work"}"#, ".credentials": "synthetic-credential", "_work/keep.txt": "checkout"]
    for (file, content) in contents { try Data(content.utf8).write(to: directory.appendingPathComponent(file)) }
    let paths = AppPaths(root: settings, runnersRoot: temporary.appendingPathComponent(".comet/runners"))

    try paths.prepare()
    try paths.prepare()
    try paths.save([runner])

    #expect(try paths.load() == [runner])
    #expect(paths.directory(runner.id).resolvingSymlinksInPath() == paths.directory(runner.id))
    #expect(try files.destinationOfSymbolicLink(atPath: settings.appendingPathComponent("runners").path) == paths.runnersRoot.path)
    for (file, content) in contents {
        #expect(try String(contentsOf: paths.directory(runner.id).appendingPathComponent(file), encoding: .utf8) == content)
        #expect(try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) == content)
    }
    #expect(try files.attributesOfItem(atPath: paths.runnersRoot.path)[.posixPermissions] as? Int == 0o700)
}

@Test func runnerMigrationRefusesActiveRunnersThenRetriesWithoutLosingData() throws {
    let files = FileManager.default
    let temporary = URL.temporaryDirectory.appendingPathComponent("comet-migration-\(UUID())")
    defer { try? files.removeItem(at: temporary) }
    let paths = AppPaths(root: temporary.appendingPathComponent("settings"), runnersRoot: temporary.appendingPathComponent(".comet/runners"))
    let id = UUID()
    let legacy = paths.root.appendingPathComponent("runners/\(id.uuidString)")
    try files.createDirectory(at: legacy, withIntermediateDirectories: true)
    let fd = open(legacy.appendingPathComponent(".host.lock").path, O_CREAT | O_RDWR, 0o600)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: RunnerError.self) { try paths.prepare() }
    #expect(files.fileExists(atPath: legacy.path))
    #expect(!files.fileExists(atPath: paths.runnersRoot.path))
    flock(fd, LOCK_UN)
    try paths.prepare()
    #expect(files.fileExists(atPath: paths.directory(id).path))
}

@Test func runnerMigrationRefusesConflictsAndUnexpectedLinks() throws {
    let files = FileManager.default
    let temporary = URL.temporaryDirectory.appendingPathComponent("comet-migration-\(UUID())")
    defer { try? files.removeItem(at: temporary) }
    let paths = AppPaths(root: temporary.appendingPathComponent("settings"), runnersRoot: temporary.appendingPathComponent(".comet/runners"))
    let legacy = paths.root.appendingPathComponent("runners")
    try files.createDirectory(at: legacy, withIntermediateDirectories: true)
    try files.createDirectory(at: paths.runnersRoot, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: legacy.appendingPathComponent("keep"))
    try Data("new".utf8).write(to: paths.runnersRoot.appendingPathComponent("keep"))
    #expect(throws: RunnerError.self) { try paths.prepare() }
    #expect(try String(contentsOf: legacy.appendingPathComponent("keep"), encoding: .utf8) == "old")
    #expect(try String(contentsOf: paths.runnersRoot.appendingPathComponent("keep"), encoding: .utf8) == "new")

    let linked = AppPaths(root: temporary.appendingPathComponent("linked-settings"), runnersRoot: temporary.appendingPathComponent("other/runners"))
    try files.createDirectory(at: linked.root, withIntermediateDirectories: true)
    try files.createSymbolicLink(at: linked.root.appendingPathComponent("runners"), withDestinationURL: legacy)
    #expect(throws: RunnerError.self) { try linked.prepare() }
    #expect(!files.fileExists(atPath: linked.runnersRoot.path))

    let unsafe = AppPaths(root: temporary.appendingPathComponent("unsafe-settings"), runnersRoot: temporary.appendingPathComponent("unsafe/runners"))
    try files.createSymbolicLink(at: unsafe.runnersRoot.deletingLastPathComponent(), withDestinationURL: paths.runnersRoot.deletingLastPathComponent())
    #expect(throws: RunnerError.self) { try unsafe.prepare() }
}

@Test func newRunnerStorageCanBePreparedRepeatedly() throws {
    let temporary = URL.temporaryDirectory.appendingPathComponent("comet-migration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let paths = AppPaths(root: temporary.appendingPathComponent("settings"), runnersRoot: temporary.appendingPathComponent(".comet/runners"))
    try paths.prepare()
    try paths.prepare()
    #expect(try paths.load().isEmpty)
    #expect(FileManager.default.fileExists(atPath: paths.runnersRoot.path))
}
