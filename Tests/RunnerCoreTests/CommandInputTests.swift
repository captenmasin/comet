import Foundation
import Darwin
import Testing
@testable import RunnerCore

@Test(arguments: [Data(), Data("stdin 'fixture' $(literal)\n".utf8), Data(repeating: 65, count: Int(PIPE_BUF))])
func commandReadsInputAndReceivesEOF(input: Data) async throws {
    let output = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/cat"), arguments: [],
        directory: .temporaryDirectory, input: input, timeout: 2)
    #expect(output == String(decoding: input, as: UTF8.self))
}

@Test func commandRedactsInputWhenAChildPrintsItAndFails() async throws {
    let secret = "private-input-fixture"
    do {
        _ = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cat >&2; exit 7"],
            directory: .temporaryDirectory, secrets: [secret], input: Data((secret + "\n").utf8))
        Issue.record("Expected the command to fail")
    } catch {
        #expect(error.localizedDescription.contains("(7)"))
        #expect(error.localizedDescription.contains("[redacted]"))
        #expect(!error.localizedDescription.contains(secret))
    }
}

@Test func commandRefusesOversizedInputBeforeLaunching() async throws {
    let marker = URL.temporaryDirectory.appendingPathComponent("comet-command-\(UUID())")
    defer { try? FileManager.default.removeItem(at: marker) }
    await #expect(throws: RunnerError.self) {
        try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path],
            directory: .temporaryDirectory, input: Data(repeating: 65, count: Int(PIPE_BUF) + 1))
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func commandKillsAChildAtTheRequestedDeadline() async throws {
    let clock = ContinuousClock()
    let started = clock.now
    do {
        _ = try await RunnerProcess.command(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf started; exec /bin/sleep 5"], directory: .temporaryDirectory, timeout: 0.1)
        Issue.record("Expected the command to time out")
    } catch {
        #expect(error.localizedDescription.contains("(9)"))
        #expect(error.localizedDescription.contains("started"))
    }
    #expect(started.duration(to: clock.now) < .seconds(3))
}

@Test(arguments: [0.0, -1.0, .infinity, .nan])
func commandRejectsAnInvalidDeadline(timeout: TimeInterval) async {
    await #expect(throws: RunnerError.self) {
        try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
            directory: .temporaryDirectory, timeout: timeout)
    }
}
