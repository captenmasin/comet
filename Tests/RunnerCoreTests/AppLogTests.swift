import Darwin
import Foundation
import Testing
@testable import Runner

@MainActor
struct AppLogTests {
    @Test func appLogRedactsCredentialsAndKeepsEventsOnOneLine() {
        let safe = AppLog.sanitized("ghp_secret github_pat_secret\nAuthorization: Bearer mcp-secret\r--token temporary")
        for secret in ["ghp_secret", "github_pat_secret", "mcp-secret", "temporary", "\n", "\r"] {
            #expect(!safe.contains(secret))
        }
        #expect(safe.contains("[redacted]"))
        #expect(AppLog.sanitized(String(repeating: "x", count: 10000)).count == 8192)
    }

    @Test func appLogPersistsAcrossWritersAndRotatesWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try AppLogFile(directory: directory, limit: 220)
        try first.append("launch")
        let second = try AppLogFile(directory: directory, limit: 220)
        try second.append("menu bar inserted=false")
        let current = directory.appendingPathComponent("app.log")
        let content = try String(contentsOf: current, encoding: .utf8)
        #expect(content.contains("launch"))
        #expect(content.contains("pid=\(ProcessInfo.processInfo.processIdentifier)"))
        #expect(content.contains("menu bar inserted=false"))
        try first.append(String(repeating: "x", count: 150))
        let previous = directory.appendingPathComponent("app.previous.log")
        #expect(try String(contentsOf: previous, encoding: .utf8) == content)
        try second.append("orderly exit")
        #expect(try String(contentsOf: previous, encoding: .utf8).contains(String(repeating: "x", count: 150)))
        #expect(try String(contentsOf: current, encoding: .utf8).contains("orderly exit"))
        for url in [current, previous, directory.appendingPathComponent("app.lock")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func busyLogFallsBackWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try AppLogFile(directory: directory)
        let lock = try FileHandle(forWritingTo: directory.appendingPathComponent("app.lock"))
        defer { try? lock.close() }
        #expect(flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: POSIXError.self) { try log.append("busy") }
        #expect(flock(lock.fileDescriptor, LOCK_UN) == 0)
        try log.append("recovered")
        #expect(try String(contentsOf: directory.appendingPathComponent("app.log"), encoding: .utf8).contains("recovered"))
    }
}
