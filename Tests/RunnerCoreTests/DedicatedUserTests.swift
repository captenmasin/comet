import Foundation
import Darwin
import Synchronization
import Testing
@testable import RunnerCore
@testable import Runner

@Test func dedicatedExecutionPersistsAndKeepsWorkflowLabels() throws {
    let runner = try RunnerCore.Runner(repository: "owner/repo", name: "Mac", label: "runner-test", execution: .dedicatedUser)
    #expect(try JSONDecoder().decode(RunnerCore.Runner.self, from: JSONEncoder().encode(runner)) == runner)
    #expect(runner.workflow == "runs-on: [self-hosted, macOS, runner-test]")
    #expect(DedicatedUser(id: runner.id).directory == "/Users/_comet/.comet/runners/\(runner.id.uuidString)")
    #expect(RunnerExecution.dedicatedUser.explanation.contains("root"))
}

@Test func dedicatedCommandsUseTheServiceHomeAndAnEmptyEnvironment() {
    let literal = "spaces 'quotes' $(id); `id`"
    let arguments = DedicatedUser.arguments("/bin/echo", [literal])
    #expect(Array(arguments.prefix(7)) == ["-n", "-H", "-u", "_comet", "/usr/bin/env", "-i", "HOME=/Users/_comet"])
    #expect(arguments.contains("TMPDIR=/Users/_comet/.tmp/"))
    #expect(arguments.contains("USER=_comet"))
    #expect(arguments.contains("PATH=/Users/_comet/.local/bin:\(DedicatedUser.homebrew)/bin:\(DedicatedUser.homebrew)/sbin:/usr/bin:/bin:/usr/sbin:/sbin"))
    #expect(!arguments.contains(where: { $0.hasPrefix("PATH=") && ($0.contains("/opt/homebrew/") || $0.contains("/usr/local/")) }))
    #expect(!arguments.contains(where: { $0.contains("TOKEN=") || $0.hasPrefix("DISPLAY=") || $0.hasPrefix("SSH_AUTH_SOCK=") }))
    #expect(Array(arguments.suffix(2)) == ["/bin/echo", literal])
}

@Test func dedicatedHelperCopyPreservesTheCompleteAppAndRefusesActiveRunners() async throws {
    let root = URL.temporaryDirectory.appendingPathComponent("comet helper ' \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("Comet.app/Contents/MacOS/Comet")
    let framework = root.appendingPathComponent("Comet.app/Contents/Frameworks/Sparkle.framework")
    let version = framework.appendingPathComponent("Versions/B")
    try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
    try Data("fixture framework".utf8).write(to: version.appendingPathComponent("Sparkle"))
    try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path,
                                             withDestinationPath: "B")
    try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Sparkle").path,
                                             withDestinationPath: "Versions/Current/Sparkle")
    let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n[ ! -e \"$2/active\" ] || exit 1\necho snapshot\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    try Data("fixture plist".utf8).write(to: contents.appendingPathComponent("Info.plist"))
    let resources = contents.appendingPathComponent("_CodeSignature")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try Data("fixture seal".utf8).write(to: resources.appendingPathComponent("CodeResources"))
    let directory = root.appendingPathComponent("runners/Mac")
    let destination = directory.appendingPathComponent("Comet.app/Contents/Frameworks/Sparkle.framework")
    let script = try DedicatedUser.helperInstallScript(executable: executable, directory: directory.path)
        .replacingOccurrences(of: "/usr/sbin/chown", with: "/usr/bin/true")
        .replacingOccurrences(of: "/usr/bin/sudo -n -H -u _comet ", with: "")
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], directory: root)
    #expect(try String(contentsOf: destination.appendingPathComponent("Sparkle"), encoding: .utf8) == "fixture framework")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("Versions/Current").path) == "B")
    #expect(try String(contentsOf: directory.appendingPathComponent("Comet.app/Contents/Info.plist"), encoding: .utf8) == "fixture plist")
    #expect(try String(contentsOf: directory.appendingPathComponent("Comet.app/Contents/_CodeSignature/CodeResources"), encoding: .utf8) == "fixture seal")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Comet.app/Contents/MacOS/Comet").path))
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    let failed = try DedicatedUser.helperInstallScript(executable: executable, directory: directory.path)
        .replacingOccurrences(of: "/usr/sbin/chown", with: "/usr/bin/false")
    await #expect(throws: RunnerError.self) {
        try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", failed], directory: root)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Comet.app"])
    try Data().write(to: directory.appendingPathComponent("active"))
    await #expect(throws: RunnerError.self) {
        try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], directory: root)
    }
    #expect(try String(contentsOf: destination.appendingPathComponent("Sparkle"), encoding: .utf8) == "fixture framework")
    try FileManager.default.removeItem(at: directory.appendingPathComponent("active"))
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], directory: root)
    try FileManager.default.removeItem(at: framework)
    #expect(throws: RunnerError.self) {
        try DedicatedUser.helperInstallScript(executable: executable, directory: directory.path)
    }
    #expect(try String(contentsOf: destination.appendingPathComponent("Sparkle"), encoding: .utf8) == "fixture framework")
}

@Test func dedicatedHomebrewBootstrapKeepsOwnershipAndRefusesExistingInstallations() async throws {
    let root = URL(fileURLWithPath: "/tmp/comet-homebrew-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("bin")
    for directory in [bin, root.appendingPathComponent("var/db"), root.appendingPathComponent("opt")] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let owner = root.appendingPathComponent("var/db/comet-user")
    try Data("501:400\n".utf8).write(to: owner)
    for (name, content) in ["id": "#!/bin/sh\necho 400\n", "chown": "#!/bin/sh\nexit 0\n",
        "stat": "#!/bin/sh\ncase \"$3\" in *\(DedicatedUser.homebrew)) echo 400;; *) echo 0;; esac\n"] {
        let file = bin.appendingPathComponent(name)
        try Data(content.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    let script = try DedicatedUser.homebrewScript(owner: 501)
        .replacingOccurrences(of: "/var/", with: root.path + "/var/")
        .replacingOccurrences(of: "/opt/", with: root.path + "/opt/")
        .replacingOccurrences(of: "export PATH=", with: "export PATH=\(bin.path):")
    let prefix = root.appendingPathComponent(String(DedicatedUser.homebrew.dropFirst()))
    // An existing path must never be adopted, even if it appears empty.
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    await #expect(throws: RunnerError.self) {
        try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], directory: root)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("var/db/comet-homebrew").path))
    try FileManager.default.removeItem(at: prefix)
    for _ in 0..<2 {
        _ = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], directory: root)
    }
    #expect(try FileManager.default.attributesOfItem(atPath: prefix.path)[.posixPermissions] as? Int == 0o700)
    #expect(try String(contentsOf: root.appendingPathComponent("var/db/comet-homebrew"), encoding: .utf8) == "501:400\n")
    try Data("502:400\n".utf8).write(to: owner)
    await #expect(throws: RunnerError.self) {
        try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], directory: root)
    }
    #if arch(arm64)
    #expect(DedicatedUser.homebrew.utf8.count == "/opt/homebrew".utf8.count)
    #else
    #expect(DedicatedUser.homebrew.utf8.count == "/usr/local".utf8.count)
    #endif
}

@Test func backgroundLaunchSurvivesHangupAndCapturesStartupErrors() async throws {
    let root = URL.temporaryDirectory.appendingPathComponent("comet launch ' \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = root.appendingPathComponent("helper ' script")
    try Data("""
    #!/bin/sh
    echo $$ > child.pid
    echo startup-output
    attempt=0
    while [ "$attempt" -lt 100 ]; do
        [ ! -e finish ] || { echo completed; exit 0; }
        attempt=$((attempt + 1))
        sleep 0.05
    done
    exit 1
    """.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let command = RunnerProcess.backgroundCommand([helper.path, "--runner-host", root.path], directory: root.path)
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], directory: root)
    let pidFile = root.appendingPathComponent("child.pid")
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: pidFile.path) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(pid, SIGHUP) == 0)
    try Data().write(to: root.appendingPathComponent("finish"))
    for _ in 0..<100 {
        if try await VMSnapshot.read(root).log.contains("completed") { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await VMSnapshot.read(root).log.contains("completed"))
    // A launch failure before the helper exists must be visible in the same log snapshot.
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
        RunnerProcess.backgroundCommand([root.appendingPathComponent("missing-helper").path], directory: root.path)
    ], directory: root)
    for _ in 0..<100 {
        if try await VMSnapshot.read(root).log.contains("missing-helper") { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await VMSnapshot.read(root).log.contains("missing-helper"))
}

@Test func snapshotRetriesTheGapBetweenLockAndProcessRecord() async throws {
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fd = open(root.appendingPathComponent(".host.lock").path, O_CREAT | O_RDWR, 0o600)
    defer { close(fd) }
    #expect(fd >= 0)
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    let release = Task {
        try await Task.sleep(for: .milliseconds(50))
        flock(fd, LOCK_UN)
    }
    let snapshot = try await VMSnapshot.read(root)
    try await release.value
    #expect(!snapshot.running)
    #expect(snapshot.registrationID == nil)
}

@Test func accountSetupCreatesValidatedSudoRulesAndRefusesUnmanagedAccounts() async throws {
    // Exercise the real setup script in a temporary filesystem with directory-service/ownership stubs.
    let root = URL(fileURLWithPath: "/tmp/comet-account-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("bin")
    for path in [bin, root.appendingPathComponent("var/db"), root.appendingPathComponent("var/run")] {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    let state = root.appendingPathComponent("account").path
    let dscl = #"""
    #!/bin/sh
    state='\#(state)'
    if [ "$2" = '-list' ]; then
        echo 'existing 400'
        if [ -f "$state.uid" ]; then printf '_comet %s\n' "$(cat "$state.uid")"; fi
        exit 0
    fi
    if [ "$2" = '-read' ]; then
        [ -f "$state" ] || exit 1
        if [ "${4-}" = UniqueID ]; then printf 'UniqueID: %s\n' "$(cat "$state.uid")"; fi
        exit 0
    fi
    if [ "$2" = '-create' ]; then
        touch "$state"
        if [ "${4-}" = UniqueID ]; then printf '%s' "$5" > "$state.uid"; fi
        exit 0
    fi
    exit 1
    """#
    for (name, content) in ["dscl": dscl, "chown": "#!/bin/sh\nexit 0\n", "stat": "#!/bin/sh\necho 0\n"] {
        let file = bin.appendingPathComponent(name)
        try Data(content.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    let original = try DedicatedUser.setupScript(owner: 501)
    let script = original
        .replacingOccurrences(of: "/var/", with: root.path + "/var/")
        .replacingOccurrences(of: "/Users/", with: root.path + "/Users/")
        .replacingOccurrences(of: "/private/etc/", with: root.path + "/private/etc/")
        .replacingOccurrences(of: "export PATH=", with: "export PATH=\(bin.path):")
    let file = root.appendingPathComponent("setup.sh")
    try Data(script.utf8).write(to: file)
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-n", file.path], directory: root)
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: [file.path], directory: root)
    let policy = root.appendingPathComponent("private/etc/sudoers.d/comet")
    let text = try String(contentsOf: policy, encoding: .utf8)
    #expect(text.contains("#501 ALL=(_comet) NOPASSWD: ALL"))
    #expect(text.contains("_comet ALL=(root) NOPASSWD: ALL"))
    #expect(!text.contains("%admin"))
    #expect(try String(contentsOf: root.appendingPathComponent("var/db/comet-user"), encoding: .utf8) == "501:401\n")
    #expect(try FileManager.default.attributesOfItem(atPath: policy.path)[.posixPermissions] as? Int == 0o440)
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/usr/sbin/visudo"), arguments: ["-cf", policy.path], directory: root)
    // Retrying a managed setup is idempotent and must keep the same UID.
    _ = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: [file.path], directory: root)
    #expect(try String(contentsOf: root.appendingPathComponent("var/db/comet-user"), encoding: .utf8) == "501:401\n")
    let otherOwner = root.appendingPathComponent("other-owner.sh")
    try Data(script.replacingOccurrences(of: "'501'", with: "'502'").utf8).write(to: otherOwner)
    await #expect(throws: RunnerError.self) {
        try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: [otherOwner.path], directory: root)
    }
    try FileManager.default.removeItem(at: root.appendingPathComponent("var/db/comet-user"))
    await #expect(throws: RunnerError.self) {
        try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: [file.path], directory: root)
    }
    #expect(try String(contentsOf: policy, encoding: .utf8) == text)
    #expect(throws: RunnerError.self) { try DedicatedUser.setupScript(owner: 0) }
}

@Test @MainActor func dedicatedRecoveryRefusesDuplicateStartsAndUncertainExecutionChanges() async throws {
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(root: root)
    let runner = try RunnerCore.Runner(repository: "owner/repo", name: "Mac", label: "runner-test", githubID: 21, execution: .dedicatedUser)
    try paths.save([runner])
    let fail = Mutex(false)
    let store = RunnerStore(paths: paths, restore: { false }, dedicatedSnapshot: { _ in
        if fail.withLock({ $0 }) { throw RunnerError.message("fixture permission denied") }
        return VMSnapshot(running: true, registrationID: 21, log: "fixture runner log")
    })
    await store.load()
    #expect(store.hasHost(runner))
    await store.start(runner)
    #expect(store.logs[runner.id] == "fixture runner log")
    #expect(store.issues[runner.id]?.contains("already running") == true)
    await store.setExecution(.host, for: runner)
    #expect(store.runners == [runner])
    fail.withLock { $0 = true }
    for _ in 0..<100 {
        await store.refresh()
        if store.state(runner) == .attention { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.hasHost(runner))
    #expect(store.state(runner) == .attention)
    await store.remove(runner)
    #expect(store.runners == [runner])
    #expect(try paths.load() == [runner])
    #expect(store.error?.contains("fixture permission denied") == true)
    // Stop the fixture polls without invoking privileged commands against the real machine.
    store.runners = []
    #expect(await store.shutdown())
}
