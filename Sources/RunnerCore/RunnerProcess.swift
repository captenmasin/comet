import Foundation
import CryptoKit
import Darwin

public enum RunnerProcess {
    public static let logLimit = 512 * 1024

    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    public static func environment(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        // Management credentials must never be inherited by workflows.
        var result: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "DEVELOPER_DIR"] {
            result[key] = inherited[key]
        }
        let tools = home.path == DedicatedUser.home
            ? "\(DedicatedUser.homebrew)/bin:\(DedicatedUser.homebrew)/sbin"
            : "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        result["PATH"] = "\(home.path)/.local/bin:\(tools):/usr/bin:/bin:/usr/sbin:/sbin"
        result["RUNNER_LOGSIZE"] = "8"
        result["RUNNER_LOGRETENTION"] = "7"
        result["WORKER_LOGSIZE"] = "8"
        result["WORKER_LOGRETENTION"] = "7"
        return result
    }

    public static func sanitized(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: "[redacted]") }
        for pattern in [#"\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)\b"#,
                        #"(?i)(authorization:\s*(?:bearer|basic)\s+)\S+"#,
                        #"(?i)((?:access_token|refresh_token|--token)[\s=:\"]+)[^\s\",]+"#] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return result
    }

    public static func bounded(_ text: String, limit: Int = logLimit) -> String {
        String(decoding: text.utf8.suffix(limit), as: UTF8.self)
    }

    @concurrent public static func command(_ executable: URL, arguments: [String], directory: URL,
                                           secrets: [String] = [], extraEnvironment: [String: String] = [:],
                                           input: Data? = nil, timeout: TimeInterval = 300) async throws -> String {
        // shortcut: prefilled stdin is limited to PIPE_BUF; use concurrent writes for larger inputs.
        guard (input?.count ?? 0) <= Int(PIPE_BUF) else {
            throw RunnerError.message("Command input exceeds the \(PIPE_BUF)-byte stdin limit.")
        }
        guard timeout.isFinite, timeout > 0 else { throw RunnerError.message("Command timeout must be a positive finite number of seconds.") }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment().merging(extraEnvironment) { _, new in new }
        let inputPipe = input.map { _ in Pipe() }
        defer {
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
        }
        if let input, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try inputPipe.fileHandleForWriting.close()
        }
        process.standardInput = inputPipe?.fileHandleForReading ?? FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = DispatchSource.makeTimerSource(queue: .global())
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler {
            if process.isRunning { kill(-process.processIdentifier, SIGKILL) }
        }
        deadline.resume()
        defer { deadline.cancel() }
        // Drain while the child runs so a full pipe cannot deadlock installation.
        var output = ""
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            output = bounded(output + String(decoding: data, as: UTF8.self))
        }
        process.waitUntilExit()
        let safe = sanitized(output, secrets: secrets)
        guard process.terminationStatus == 0 else {
            throw RunnerError.message("\(executable.lastPathComponent) failed (\(process.terminationStatus)).\n\(safe)")
        }
        return safe
    }

    struct HostRecord: Codable {
        let pid: Int32
        let seconds: UInt64
        let microseconds: UInt64
    }

    private static func identity(_ pid: Int32) -> HostRecord? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return HostRecord(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    public static func locked(_ directory: URL) -> Bool {
        let fd = open(directory.appendingPathComponent(".host.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return errno != ENOENT }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }

    public static func hostPID(_ directory: URL) -> Int32? {
        guard locked(directory),
              let data = try? Data(contentsOf: directory.appendingPathComponent(".host.json")),
              let saved = try? JSONDecoder().decode(HostRecord.self, from: data),
              let current = identity(saved.pid), current.seconds == saved.seconds, current.microseconds == saved.microseconds else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(saved.pid, &buffer, UInt32(buffer.count)) > 0,
              let executable = Bundle.main.executableURL,
              String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == executable.path,
              getpgid(saved.pid) == saved.pid,
              let invocation = arguments(saved.pid)?.suffix(2),
              invocation.last == directory.path,
              ["--runner-host", "--runner-host-once"].contains(invocation.first ?? "") else { return nil }
        return saved.pid
    }

    private static func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 1024 * 1024
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > 4 else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 1024 else { return nil }
        var index = 4
        while index < size && bytes[index] != 0 { index += 1 }
        while index < size && bytes[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<count {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            guard index < size else { return nil }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    public static func launch(_ directory: URL) throws -> Process {
        guard !locked(directory) else { throw RunnerError.message("A runner process already owns this folder. Retry connection instead of starting another.") }
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--runner-host", directory.path]
        process.environment = environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    public static func backgroundCommand(_ arguments: [String], directory: String) -> String {
        // BSD nohup requires a console on macOS; hidden service accounts have none.
        "cd \(VMConnection.quote(directory)) || exit; trap '' HUP; "
            + arguments.map(VMConnection.quote).joined(separator: " ")
            + " </dev/null >\(VMConnection.quote(directory + "/startup.log")) 2>&1 &"
    }

    public static func stop(_ directory: URL) async throws {
        guard let pid = hostPID(directory) else {
            if locked(directory) { throw RunnerError.message("The folder is locked by an unverified process. Comet will not signal it. Check Activity Monitor.") }
            return
        }
        guard kill(-pid, SIGINT) == 0 || errno == ESRCH else { throw RunnerError.message("Unable to stop the runner process.") }
        for _ in 0..<60 {
            if !locked(directory) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        // Recheck identity before escalation; never signal a recycled PID.
        if hostPID(directory) == pid { kill(-pid, SIGKILL) }
        for _ in 0..<20 {
            if !locked(directory) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RunnerError.message("The runner has not exited. Its local files have been preserved.")
    }

    public static func host(directory: URL, once: Bool = false) -> Int32 {
        umask(0o077)
        let fd = open(directory.appendingPathComponent(".host.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return 2 }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard setpgid(0, 0) == 0 else {
            FileHandle.standardError.write(Data("Cannot create the runner process group: \(String(cString: strerror(errno)))\n".utf8))
            return 3
        }
        guard let record = identity(getpid()) else {
            FileHandle.standardError.write(Data("Cannot verify the runner helper’s process identity.\n".utf8))
            return 3
        }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let recordURL = directory.appendingPathComponent(".host.json")
        let exitURL = directory.appendingPathComponent(".host-exit")
        do {
            try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: recordURL) }
            guard chdir(directory.path) == 0 else { throw RunnerError.message("Cannot open the runner folder.") }
            if once, FileManager.default.fileExists(atPath: exitURL.path) {
                try FileManager.default.removeItem(at: exitURL)
            }
            let pipe = Pipe()
            // Foundation Process creates a separate group; spawn directly so Stop reaches the whole job.
            let child = try spawnRunner(directory: directory, pipe: pipe, once: once)
            try pipe.fileHandleForWriting.close()
            let logURL = directory.appendingPathComponent("runner.log")
            var output = ""
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                output = bounded(output + sanitized(String(decoding: data, as: UTF8.self)))
                try output.write(to: logURL, atomically: true, encoding: .utf8)
            }
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            let exitCode: Int32 = status == 0 ? 0 : 1
            if once { try "\(exitCode)\n".write(to: exitURL, atomically: true, encoding: .utf8) }
            return exitCode
        } catch {
            if once { try? "4\n".write(to: exitURL, atomically: true, encoding: .utf8) }
            try? sanitized(error.localizedDescription).write(to: directory.appendingPathComponent("runner.log"), atomically: true, encoding: .utf8)
            return 4
        }
    }

    private static func spawnRunner(directory: URL, pipe: Pipe, once: Bool) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGTERM)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let path = directory.appendingPathComponent("run.sh").path
        let environment = environment()
        var argv = ([path] + (once ? ["--once"] : [])).map { strdup($0) } + [nil]
        var env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: Int32 = 0
        // Setup actions need to read caches they create through sudo.
        let previousUmask = umask(0o022)
        let status = posix_spawn(&pid, path, &actions, &attributes, &argv, &env)
        umask(previousUmask)
        guard status == 0 else { throw RunnerError.message("Cannot launch the runner: \(String(cString: strerror(status)))") }
        return pid
    }

    @concurrent public static func readLog(_ directory: URL, file name: String = "runner.log") async -> String {
        let file = directory.appendingPathComponent(name)
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "No local output yet." }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > UInt64(logLimit) ? size - UInt64(logLimit) : 0)
            return sanitized(String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self))
        } catch { return "Could not read the runner log: \(error.localizedDescription)" }
    }
}

public enum RunnerInstaller {
    public struct Release: Decodable, Sendable {
        public struct Asset: Decodable, Sendable {
            public let name: String
            public let browser_download_url: URL
            public let digest: String?
        }
        public let assets: [Asset]
    }

    @concurrent public static func verify(file: URL, digest: String) async throws {
        guard digest.hasPrefix("sha256:"), digest.count == 71 else { throw RunnerError.message("GitHub did not supply a valid SHA-256 digest. Installation stopped.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == String(digest.dropFirst(7)).lowercased() else { throw RunnerError.message("Runner download failed SHA-256 verification. Nothing was executed.") }
    }

    public static func install(_ runner: Runner, directory: URL, github: GitHub,
                               progress: @MainActor @Sendable (String) -> Void) async throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = directory.appendingPathComponent(".runner")
        if FileManager.default.fileExists(atPath: config.path) { return try registeredID(directory) }
        guard !RunnerProcess.locked(directory) else { throw RunnerError.message("Stop the existing local process before installing.") }
        let remote = try await github.runners(repository: runner.repository)
        guard !remote.contains(where: { $0.name == runner.name }) else {
            throw RunnerError.message("A runner named \(runner.name) already exists on GitHub. Choose another name, or recover/remove that registration in GitHub first.")
        }
        let file = try await download(architecture: RunnerProcess.architecture, github: github, progress: progress)
        defer { try? FileManager.default.removeItem(at: file) }
        await progress("Unpacking the runner…")
        _ = try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", file.path, "-C", directory.path], directory: directory)
        await progress("Registering with GitHub…")
        let token = try await github.registrationToken(repository: runner.repository)
        _ = try await RunnerProcess.command(directory.appendingPathComponent("config.sh"), arguments: [
            "--unattended", "--url", "https://github.com/\(runner.repository)", "--token", token,
            "--name", runner.name, "--labels", runner.label, "--work", "_work"
        ], directory: directory, secrets: [token])
        return try registeredID(directory)
    }

    public static func download(architecture: String, github: GitHub,
                                progress: @MainActor @Sendable (String) -> Void) async throws -> URL {
        await progress("Finding the official GitHub runner…")
        let release: Release = try await github.request("/repos/actions/runner/releases/latest", authenticated: false)
        let prefix = "actions-runner-osx-\(architecture)-"
        guard let asset = release.assets.first(where: { $0.name.hasPrefix(prefix) && $0.name.hasSuffix(".tar.gz") }),
              let digest = asset.digest,
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path.hasPrefix("/actions/runner/releases/download/") else {
            throw RunnerError.message("No verified macOS runner release is available for this architecture.")
        }
        await progress("Downloading \(asset.name)…")
        let (file, response) = try await URLSession.shared.download(from: asset.browser_download_url)
        do {
            try GitHub.validate(response)
            await progress("Verifying SHA-256…")
            try await verify(file: file, digest: digest)
            try Task.checkCancellation()
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    public static func registeredID(_ directory: URL) throws -> Int {
        struct Registration: Decodable { let agentId: Int }
        return try JSONDecoder().decode(Registration.self, from: Data(contentsOf: directory.appendingPathComponent(".runner"))).agentId
    }
}
