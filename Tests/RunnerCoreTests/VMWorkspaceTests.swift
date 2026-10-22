import Foundation
import Darwin
import Testing
@testable import RunnerCore

@Test func guestRunnerDirectoryAvoidsSpaces() {
    #expect(VMConnection.guestDirectory == "/Users/comet/.comet/runner")
    #expect(!VMConnection.guestDirectory.contains(" "))
}

@Test func guestRunnerStorageCanBePreparedWithoutAnOldParentAndRepeatedly() throws {
    let files = FileManager.default
    let home = URL.temporaryDirectory.appendingPathComponent("comet-guest-\(UUID())")
    defer { try? files.removeItem(at: home) }
    let legacy = home.appendingPathComponent("Library/Application Support/CometRunner")
    let destination = home.appendingPathComponent(".comet/runner")
    #expect(!files.fileExists(atPath: legacy.deletingLastPathComponent().path))

    try VMConnection.prepareGuestDirectory(home: home)
    try VMConnection.prepareGuestDirectory(home: home)

    #expect(try files.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType == .typeDirectory)
    #expect(try files.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int == 0o700)
    #expect(try files.destinationOfSymbolicLink(atPath: legacy.path) == destination.path)
}

@Test func guestRunnerMigrationPreservesRegistrationCredentialsWorkspaceAndCaches() throws {
    let files = FileManager.default
    let home = URL.temporaryDirectory.appendingPathComponent("comet-guest-\(UUID())")
    defer { try? files.removeItem(at: home) }
    let legacy = home.appendingPathComponent("Library/Application Support/CometRunner")
    let destination = home.appendingPathComponent(".comet/runner")
    let contents = [
        ".runner": #"{"agentId":23,"workFolder":"_work"}"#,
        ".credentials": "synthetic-credential",
        "_work/repo/repo/keep.txt": "checkout",
        "_work/_tool/php/8.4.1/bin/php": "cached tool using \(legacy.path)"
    ]
    for (file, content) in contents {
        let url = legacy.appendingPathComponent(file)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    try VMConnection.prepareGuestDirectory(home: home)
    try VMConnection.prepareGuestDirectory(home: home)

    #expect(try RunnerInstaller.registeredID(destination) == 23)
    #expect(destination.resolvingSymlinksInPath().path == destination.path)
    #expect(try files.attributesOfItem(atPath: legacy.path)[.type] as? FileAttributeType == .typeSymbolicLink)
    #expect(try files.destinationOfSymbolicLink(atPath: legacy.path) == destination.path)
    for (file, content) in contents {
        #expect(try String(contentsOf: destination.appendingPathComponent(file), encoding: .utf8) == content)
        #expect(try String(contentsOf: legacy.appendingPathComponent(file), encoding: .utf8) == content)
    }
}

@Test func migratedGuestActionRunsWithAnUnquotedScriptPath() async throws {
    let files = FileManager.default
    let home = URL.temporaryDirectory.appendingPathComponent("comet-guest-\(UUID())")
    defer { try? files.removeItem(at: home) }
    #expect(!home.path.contains(" "))
    let action = "_work/_actions/setup-php/run.sh"
    let legacy = home.appendingPathComponent("Library/Application Support/CometRunner")
    let script = legacy.appendingPathComponent(action)
    try files.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/bash\nprintf '%s\\n' fixture\n".utf8).write(to: script)

    await #expect(throws: RunnerError.self) {
        try await RunnerProcess.command(URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "/bin/bash " + script.path], directory: home)
    }
    try VMConnection.prepareGuestDirectory(home: home)
    let migrated = home.appendingPathComponent(".comet/runner").appendingPathComponent(action)
    let output = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/bash"),
        arguments: ["-c", "/bin/bash " + migrated.path], directory: home)
    #expect(output == "fixture\n")
}

@Test func guestRunnerMigrationRefusesAnActiveRunnerAndRetriesAfterItStops() throws {
    let files = FileManager.default
    let home = URL.temporaryDirectory.appendingPathComponent("comet-guest-\(UUID())")
    defer { try? files.removeItem(at: home) }
    let legacy = home.appendingPathComponent("Library/Application Support/CometRunner")
    let destination = home.appendingPathComponent(".comet/runner")
    try files.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("preserved".utf8).write(to: legacy.appendingPathComponent("keep.txt"))
    let fd = open(legacy.appendingPathComponent(".host.lock").path, O_CREAT | O_RDWR, 0o600)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)

    #expect(throws: RunnerError.self) { try VMConnection.prepareGuestDirectory(home: home) }

    #expect(!files.fileExists(atPath: destination.path))
    #expect(try String(contentsOf: legacy.appendingPathComponent("keep.txt"), encoding: .utf8) == "preserved")
    flock(fd, LOCK_UN)
    try VMConnection.prepareGuestDirectory(home: home)
    #expect(try String(contentsOf: destination.appendingPathComponent("keep.txt"), encoding: .utf8) == "preserved")
}

@Test(arguments: [false, true])
func guestRunnerMigrationRefusesConflictingStorageAndUnexpectedLinks(unexpectedLink: Bool) throws {
    let files = FileManager.default
    let home = URL.temporaryDirectory.appendingPathComponent("comet-guest-\(UUID())")
    defer { try? files.removeItem(at: home) }
    let legacy = home.appendingPathComponent("Library/Application Support/CometRunner")
    let destination = home.appendingPathComponent(".comet/runner")
    let original = unexpectedLink ? home.appendingPathComponent("unexpected") : legacy
    try files.createDirectory(at: original, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: original.appendingPathComponent("keep.txt"))
    if unexpectedLink {
        try files.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: legacy, withDestinationURL: original)
    } else {
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: destination.appendingPathComponent("keep.txt"))
    }

    #expect(throws: RunnerError.self) { try VMConnection.prepareGuestDirectory(home: home) }

    #expect(try String(contentsOf: original.appendingPathComponent("keep.txt"), encoding: .utf8) == "old")
    if unexpectedLink {
        #expect(!files.fileExists(atPath: destination.path))
        #expect(try files.destinationOfSymbolicLink(atPath: legacy.path) == original.path)
    } else {
        #expect(try String(contentsOf: destination.appendingPathComponent("keep.txt"), encoding: .utf8) == "new")
    }
}
