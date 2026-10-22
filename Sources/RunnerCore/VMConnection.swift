import Foundation

public struct VMSnapshot: Codable, Sendable {
    public let running: Bool
    public let registrationID: Int?
    public let log: String
    public var exitCode: Int? = nil

    public static func read(_ directory: URL) async throws -> Self {
        var running = RunnerProcess.locked(directory)
        // The helper acquires its lock just before publishing its process identity.
        if running, RunnerProcess.hostPID(directory) == nil {
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(25))
                running = RunnerProcess.locked(directory)
                if !running || RunnerProcess.hostPID(directory) != nil { break }
            }
        }
        guard !running || RunnerProcess.hostPID(directory) != nil else {
            throw RunnerError.message("The runner folder is locked by an unverified process. Retry Connection before proceeding.")
        }
        let registration = directory.appendingPathComponent(".runner")
        var log = await RunnerProcess.readLog(directory)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("startup.log").path) {
            let startup = await RunnerProcess.readLog(directory, file: "startup.log")
            if !startup.isEmpty { log += "\n" + startup }
        }
        let exit = try? String(contentsOf: directory.appendingPathComponent(".host-exit"), encoding: .utf8)
        return Self(running: running,
                    registrationID: FileManager.default.fileExists(atPath: registration.path) ? try RunnerInstaller.registeredID(directory) : nil,
                    log: RunnerProcess.bounded(log, limit: 32 * 1024),
                    exitCode: exit.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
    }
}

public struct VMConnection: Sendable {
    public static let guestDirectory = "/Users/comet/.comet/runner"
    public static let guestHelper = guestDirectory + "/Comet.app/Contents/MacOS/Comet"
    public let address: String
    public let directory: URL
    public let password: String

    public init(address: String, directory: URL, password: String) throws {
        guard Self.validAddress(address) else { throw RunnerError.message("The VM did not receive a valid IPv4 address.") }
        self.address = address
        self.directory = directory
        self.password = password
    }
    public static func prepareGuestDirectory(home: URL) throws {
        let legacy = home.appendingPathComponent("Library/Application Support/CometRunner")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try AppPaths(root: home.appendingPathComponent(".comet"), runnersRoot: home.appendingPathComponent(".comet/runner"))
            .prepare(migratingFrom: legacy)
    }
    public static func validAddress(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && UInt8(part) != nil
        }
    }
    public static func address(for mac: String, leases: String) -> String? {
        func normalized(_ value: String) -> [UInt8]? {
            let bytes = value.split(separator: ":")
            guard bytes.count == 6 else { return nil }
            let values = bytes.compactMap { UInt8($0, radix: 16) }
            return values.count == 6 ? values : nil
        }
        guard let wanted = normalized(mac) else { return nil }
        for block in leases.components(separatedBy: "}").reversed() {
            var fields: [String: String] = [:]
            for line in block.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            guard let hardware = fields["hw_address"], hardware.hasPrefix("1,"),
                  normalized(String(hardware.dropFirst(2))) == wanted,
                  let address = fields["ip_address"], validAddress(address) else { continue }
            return address
        }
        return nil
    }
    public static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private var options: [String] { ["-F", "/dev/null",
        "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\(directory.appendingPathComponent("known_hosts").path)",
        "-o", "HostKeyAlias=comet-vm", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
        "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1",
        "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes"
    ] }
    private func environment() throws -> [String: String] {
        let askpass = directory.appendingPathComponent("askpass.sh")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$COMET_VM_PASSWORD\"\n".utf8).write(to: askpass, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        return ["SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "comet", "COMET_VM_PASSWORD": password]
    }
    public func command(_ command: String, secrets: [String] = [], input: Data? = nil, timeout: TimeInterval = 300) async throws -> String {
        try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: options + ["comet@\(address)", command],
            directory: directory, secrets: secrets + [password], extraEnvironment: environment(), input: input, timeout: timeout)
    }
    public func copy(_ file: URL, to destination: String) async throws {
        _ = try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/scp"),
            arguments: options + [file.path, "comet@\(address):\(destination)"], directory: directory,
            secrets: [password], extraEnvironment: environment())
    }
    public func snapshot() async throws -> VMSnapshot {
        let output = try await command("\(Self.quote(Self.guestHelper)) --runner-snapshot \(Self.quote(Self.guestDirectory))")
        return try JSONDecoder().decode(VMSnapshot.self, from: Data(output.utf8))
    }
    static func archiveHelper(executable: URL, to archive: URL) async throws {
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let framework = contents.appendingPathComponent("Frameworks/Sparkle.framework")
        guard FileManager.default.fileExists(atPath: framework.path) else {
            throw RunnerError.message("Comet’s helper framework is missing. Build and launch the complete app with scripts/build-app.sh before setting up a VM.")
        }
        guard FileManager.default.fileExists(atPath: contents.appendingPathComponent("Info.plist").path) else {
            throw RunnerError.message("Comet’s app bundle is incomplete. Build and launch the complete app with scripts/build-app.sh before setting up a VM.")
        }
        // Developer ID signatures require the executable's original bundle metadata and resources.
        _ = try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--sequesterRsrc", contents.deletingLastPathComponent().path, archive.path],
            directory: archive.deletingLastPathComponent())
    }
    public func install(_ runner: Runner, github: GitHub, executable: URL,
                        progress: @MainActor @Sendable (String) -> Void) async throws -> Int {
        let helperArchive = directory.appendingPathComponent("Comet-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: helperArchive) }
        try await Self.archiveHelper(executable: executable, to: helperArchive)
        await progress("Preparing the VM workspace…")
        let root = Self.quote(Self.guestDirectory)
        let staging = "/tmp/comet-helper-\(UUID().uuidString)"
        let app = Self.quote(staging + "/Comet.app")
        let helper = Self.quote(staging + "/Comet.app/Contents/MacOS/Comet")
        _ = try await command("umask 077; /bin/mkdir -p \(Self.quote(staging))")
        try await copy(helperArchive, to: staging + "/Comet.zip")
        _ = try await command("""
            set -eu
            /usr/bin/ditto -x -k \(Self.quote(staging + "/Comet.zip")) \(app)
            /usr/bin/codesign --verify --deep --strict \(app)
            \(helper) --runner-migrate /Users/comet
            if [ -e \(root)/Comet.app ]; then /bin/mv \(root)/Comet.app \(Self.quote(staging + "/previous.app")); fi
            /bin/mv \(app) \(root)/Comet.app
            /bin/rm -rf \(Self.quote(staging))
            """)
        if try await command(VMTools.statusScript).trimmingCharacters(in: .whitespacesAndNewlines) != "ready" {
            await progress("Installing Command Line Tools and Homebrew in the VM…")
            _ = try await command(VMTools.installScript, input: Data((password + "\n").utf8), timeout: 3600)
            guard try await command(VMTools.statusScript).trimmingCharacters(in: .whitespacesAndNewlines) == "ready" else {
                throw RunnerError.message("The VM’s developer tools, Homebrew or workflow sudo access are not ready. Check the VM desktop for setup errors or any Apple licence prompt, then start the runner again.")
            }
        }
        await progress("Preparing the Homebrew package catalog…")
        _ = try await command(VMTools.catalogScript, timeout: 1800)
        let configuration = try await command("if [ -f \(root)/.runner ]; then /bin/cat \(root)/.runner; fi")
        if !configuration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try await command("cd \(root) && PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH ./env.sh")
            struct Registration: Decodable { let agentId: Int }
            return try JSONDecoder().decode(Registration.self, from: Data(configuration.utf8)).agentId
        }
        let existing = try await github.runners(repository: runner.repository)
        guard !existing.contains(where: { $0.name == runner.name }) else {
            throw RunnerError.message("A runner named \(runner.name) already exists on GitHub. Recover or remove that registration before retrying.")
        }
        let archive = try await RunnerInstaller.download(architecture: "arm64", github: github, progress: progress)
        defer { try? FileManager.default.removeItem(at: archive) }
        await progress("Copying the verified runner into the VM…")
        try await copy(archive, to: Self.guestDirectory + "/runner.tar.gz")
        _ = try await command("/usr/bin/tar -xzf \(root)/runner.tar.gz -C \(root) && /bin/rm \(root)/runner.tar.gz")
        await progress("Registering the VM runner with GitHub…")
        let token = try await github.registrationToken(repository: runner.repository)
        let arguments = ["--unattended", "--url", "https://github.com/\(runner.repository)", "--token", token,
                         "--name", runner.name, "--labels", runner.label, "--work", "_work"]
        _ = try await command("cd \(root) && PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH ./config.sh " + arguments.map(Self.quote).joined(separator: " "), secrets: [token])
        guard let id = try await snapshot().registrationID else { throw RunnerError.message("The VM runner registration was not saved. Its files have been preserved.") }
        return id
    }

    public func launch() async throws {
        // Only a naturally completed one-job listener can be powered down without cancelling work.
        _ = try await command("rm -f \(Self.quote(Self.guestDirectory + "/.host-exit")) && " + RunnerProcess.backgroundCommand([
            "/usr/bin/env", "-i", "HOME=/Users/comet", "USER=comet", "LOGNAME=comet", "TMPDIR=/tmp",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin", Self.guestHelper, "--runner-host-once", Self.guestDirectory
        ], directory: Self.guestDirectory))
        for _ in 0..<20 {
            let state = try await snapshot()
            if state.running || state.exitCode == 0 { return }
            if state.exitCode != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RunnerError.message("The guest runner did not start. Check Logs and the VM window.")
    }
}
