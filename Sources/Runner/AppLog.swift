import AppKit
import Darwin
import Foundation
import OSLog
import RunnerCore

@MainActor
enum AppLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Comet")
    private static let logger = Logger(subsystem: "dev.runnerbar.app", category: "app")
    private static var file: AppLogFile?
    private(set) static var isStarted = false

    static func start() {
        isStarted = true
        do { file = try AppLogFile(directory: directory) }
        catch { logger.error("Cannot open app log: \(error.localizedDescription, privacy: .private)") }
        let bundle = Bundle.main
        record("launch version=\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "development") build=\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown") path=\(bundle.bundlePath) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.runnerbar.app")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { record("Other Comet instances are running: \(others.map(\.processIdentifier))", error: true) }
    }

    static func record(_ message: String, error: Bool = false) {
        let safe = sanitized(message)
        if error { logger.error("App error: \(safe, privacy: .private)") }
        else { logger.notice("App event: \(safe, privacy: .private)") }
        do { try file?.append("\(error ? "ERROR" : "NOTICE") \(safe)") }
        catch { logger.error("Cannot write app log: \(error.localizedDescription, privacy: .private)") }
    }

    static func sanitized(_ message: String) -> String {
        String(RunnerProcess.sanitized(message).prefix(8192))
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    }

    static func showInFinder() { NSWorkspace.shared.open(directory) }
}

// A separate lock file keeps append and rotation safe when two app copies are running.
@MainActor
final class AppLogFile {
    private let directory: URL
    private let limit: Int
    private let lock: FileHandle

    init(directory: URL, limit: Int = 1024 * 1024) throws {
        self.directory = directory
        self.limit = limit
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        lock = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func append(_ message: String) throws {
        // Never stall the UI behind a suspended second instance; unified logging still records the event.
        guard flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(lock.fileDescriptor, LOCK_UN) }
        let url = directory.appendingPathComponent("app.log")
        let data = Data("\(Date().ISO8601Format()) pid=\(ProcessInfo.processInfo.processIdentifier) \(message)\n".utf8)
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let size = (try manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > limit {
                let previous = directory.appendingPathComponent("app.previous.log")
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                try manager.moveItem(at: url, to: previous)
            }
        }
        let fd = Darwin.open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }
}
