import Foundation
import Darwin

/// One service account; each runner keeps its own persistent directory and helper lock.
public struct DedicatedUser: Sendable {
    public static let username = "_comet"
    public static let home = "/Users/_comet"
    // Equal-length paths also preserve serialized strings embedded in relocated bottles.
    #if arch(arm64)
    public static let homebrew = "/opt/comet-hb"
    #else
    public static let homebrew = "/opt/comet"
    #endif
    static let marker = "/var/db/comet-user"
    @MainActor private static var homebrewSetup: Task<Void, any Error>?
    @MainActor private static var helperSetups: [UUID: Task<Void, any Error>] = [:]
    public let id: UUID
    public var directory: String { Self.home + "/.comet/runners/" + id.uuidString }
    private var helper: String { directory + "/Comet.app/Contents/MacOS/Comet" }
    private var helperSelection: String {
        "helper=\(VMConnection.quote(helper)); [ -x \"$helper\" ] || helper=\(VMConnection.quote(directory + "/Comet")); "
    }

    public init(id: UUID) { self.id = id }

    static var configured: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
              let record = try? String(contentsOfFile: marker, encoding: .utf8),
              let user = getpwnam(username) else { return false }
        return record == "\(getuid()):\(user.pointee.pw_uid)\n"
            && user.pointee.pw_uid >= 400 && user.pointee.pw_uid < 500
            && String(cString: user.pointee.pw_dir) == home
    }

    // Use numeric caller identity so an account name cannot become sudoers syntax.
    static func setupScript(owner: uid_t) throws -> String {
        guard owner >= 500 else { throw RunnerError.message("Set up dedicated-user execution from a regular macOS user account.") }
        return #"""
        set -eu
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        umask 077
        fail() { echo "$1" >&2; exit 1; }
        mkdir /var/run/comet-user-setup.lock 2>/dev/null || fail 'Another Comet account setup is running. Retry when it finishes.'
        policy=''
        trap 'test -z "$policy" || rm -f "$policy"; rmdir /var/run/comet-user-setup.lock' EXIT
        if [ -e /var/db/comet-user ] || [ -L /var/db/comet-user ]; then
            [ ! -L /var/db/comet-user ] && [ "$(stat -f %u /var/db/comet-user)" = 0 ] || fail 'Comet account record has an unexpected owner.'
            IFS=: read -r owner service_uid < /var/db/comet-user
            [ "$owner" = '\#(owner)' ] || fail 'This Comet account belongs to another macOS user.'
            case "$service_uid" in 4[0-9][0-9]) ;; *) fail 'Invalid Comet service UID.' ;; esac
        else
            ! dscl . -read /Users/_comet >/dev/null 2>&1 || fail 'The _comet account already exists and is not managed by Comet.'
            [ ! -e /Users/_comet ] && [ ! -L /Users/_comet ] || fail 'An unmanaged /Users/_comet folder already exists.'
            [ ! -e /private/etc/sudoers.d/comet ] && [ ! -L /private/etc/sudoers.d/comet ] || fail 'An unmanaged Comet sudo policy already exists.'
            service_uid=400
            while dscl . -list /Users UniqueID | awk '{print $NF}' | grep -qx "$service_uid"; do
                service_uid=$((service_uid + 1))
                [ "$service_uid" -lt 500 ] || fail 'No free system user ID is available.'
            done
            printf '%s:%s\n' '\#(owner)' "$service_uid" > /var/db/comet-user
            chmod 644 /var/db/comet-user
        fi
        if dscl . -read /Users/_comet >/dev/null 2>&1; then
            actual_uid=$(dscl . -read /Users/_comet UniqueID 2>/dev/null | awk '{print $2}')
            [ -z "$actual_uid" ] || [ "$actual_uid" = "$service_uid" ] || fail 'The _comet account UID changed. Its files were preserved.'
        else
            ! dscl . -list /Users UniqueID | awk '{print $NF}' | grep -qx "$service_uid" || fail 'The reserved Comet UID is now in use.'
        fi
        dscl . -create /Users/_comet
        dscl . -create /Users/_comet UniqueID "$service_uid"
        dscl . -create /Users/_comet PrimaryGroupID 20
        dscl . -create /Users/_comet NFSHomeDirectory /Users/_comet
        dscl . -create /Users/_comet UserShell /bin/zsh
        dscl . -create /Users/_comet RealName 'Comet Runner'
        dscl . -create /Users/_comet IsHidden 1
        dscl . -create /Users/_comet Password '*'
        for folder in /Users/_comet /Users/_comet/.comet /Users/_comet/.comet/runners /Users/_comet/.tmp /Users/_comet/Library /Users/_comet/Library/Keychains; do
            [ ! -L "$folder" ] || fail 'Comet home contains an unexpected symbolic link.'
            mkdir -p "$folder"
            chown _comet:staff "$folder"
            chmod 700 "$folder"
        done
        mkdir -p /private/etc/sudoers.d
        policy=$(mktemp /private/etc/sudoers.d/.comet.XXXXXX)
        printf '%s\n' '# Comet dedicated-user execution, explicitly grants root access to workflows.' '#\#(owner) ALL=(_comet) NOPASSWD: ALL' '_comet ALL=(root) NOPASSWD: ALL' > "$policy"
        chmod 440 "$policy"
        /usr/sbin/visudo -cf "$policy"
        mv -f "$policy" /private/etc/sudoers.d/comet
        policy=''
        """#
    }

    public static func prepareAccount() async throws {
        if configured,
           (try? await run("/usr/bin/sudo", ["-n", "/usr/bin/id", "-u"]).trimmingCharacters(in: .whitespacesAndNewlines)) == "0" { return }
        let script = try setupScript(owner: getuid())
        _ = try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: [
            "-e", "on run argv\ndo shell script (item 1 of argv) with administrator privileges\nend run", script
        ], directory: URL(fileURLWithPath: "/"))
        guard configured else { throw RunnerError.message("Comet’s dedicated account setup did not complete. Start again to retry.") }
        guard try await run("/usr/bin/sudo", ["-n", "/usr/bin/id", "-u"]).trimmingCharacters(in: .whitespacesAndNewlines) == "0" else {
            throw RunnerError.message("The dedicated account does not have passwordless sudo access.")
        }
    }

    static func homebrewScript(owner: uid_t) throws -> String {
        guard owner >= 500 else { throw RunnerError.message("Set up tools from a regular macOS user account.") }
        return #"""
        set -eu
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        umask 077
        fail() { echo "$1" >&2; exit 1; }
        service_uid=$(id -u _comet)
        record='\#(owner)':"$service_uid"
        [ "$(cat /var/db/comet-user)" = "$record" ] || fail 'The Comet account ownership changed.'
        if [ -e /var/db/comet-homebrew ] || [ -L /var/db/comet-homebrew ]; then
            [ -f /var/db/comet-homebrew ] && [ ! -L /var/db/comet-homebrew ] && [ "$(stat -f %u /var/db/comet-homebrew)" = 0 ] || fail 'The Comet Homebrew ownership record is invalid.'
            [ "$(cat /var/db/comet-homebrew)" = "$record" ] || fail 'Comet Homebrew belongs to another account.'
        else
            [ ! -e \#(homebrew) ] && [ ! -L \#(homebrew) ] || fail 'An unmanaged \#(homebrew) already exists. Its files were preserved.'
            printf '%s\n' "$record" > /var/db/comet-homebrew
            chmod 644 /var/db/comet-homebrew
        fi
        [ ! -L \#(homebrew) ] || fail 'Comet Homebrew cannot be a symbolic link.'
        if [ ! -e \#(homebrew) ]; then
            mkdir -p \#(homebrew)
            chown _comet:staff \#(homebrew)
            chmod 700 \#(homebrew)
        fi
        [ -d \#(homebrew) ] && [ "$(stat -f %u \#(homebrew))" = "$service_uid" ] || fail 'The Comet Homebrew directory ownership changed.'
        """#
    }

    @MainActor public static func prepareHomebrew(github: GitHub,
        progress: @escaping @MainActor @Sendable (String) -> Void) async throws {
        if let homebrewSetup { try await homebrewSetup.value; return }
        let task = Task {
            progress("Preparing the dedicated user and its Homebrew installation…")
            try await prepareAccount()
            _ = try await run("/usr/bin/sudo", ["-n", "/bin/sh", "-c", try homebrewScript(owner: getuid())])
            let ready = homebrew + "/.comet-ready"
            if (try? await run("/bin/test", ["-f", ready])) == nil {
                struct Release: Decodable { let tag_name: String }
                progress("Downloading Homebrew for the dedicated account…")
                let release: Release = try await github.request("/repos/Homebrew/brew/releases/latest", authenticated: false)
                guard Runner.validName(release.tag_name), !release.tag_name.hasPrefix("-") else {
                    throw RunnerError.message("Homebrew returned an invalid release tag. Nothing was installed.")
                }
                let stage = homebrew + "/.install-" + UUID().uuidString
                do {
                    _ = try await run("/usr/bin/git", ["clone", "--depth", "1", "--branch", release.tag_name,
                        "--", "https://github.com/Homebrew/brew.git", stage])
                    _ = try await run("/usr/bin/ditto", [stage, homebrew])
                    _ = try await run("/bin/rm", ["-rf", stage])
                    _ = try await run("/usr/bin/touch", [ready])
                } catch {
                    _ = try? await run("/bin/rm", ["-rf", stage])
                    throw error
                }
            }
            // A release-tag clone must still allow normal Homebrew branch updates.
            _ = try await run("/usr/bin/git", ["-C", homebrew, "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
            let catalog = homebrew + "/Library/Taps/homebrew/homebrew-core"
            if (try? await run("/usr/bin/git", ["-C", catalog, "rev-parse", "--verify", "HEAD"])) == nil {
                progress("Downloading the Homebrew package catalog…")
                let stage = homebrew + "/.catalog-" + UUID().uuidString
                do {
                    _ = try await run("/usr/bin/git", ["clone", "--depth", "1", "--single-branch", "--branch", "main",
                        "--", "https://github.com/Homebrew/homebrew-core.git", stage])
                    _ = try await run("/bin/mkdir", ["-p", homebrew + "/Library/Taps/homebrew"])
                    // Preserve an incomplete catalog from another process instead of nesting or overwriting it.
                    _ = try await run("/bin/test", ["!", "-e", catalog])
                    _ = try await run("/bin/mv", [stage, catalog])
                } catch {
                    _ = try? await run("/bin/rm", ["-rf", stage])
                    throw error
                }
            }
            let prefix = try await run(homebrew + "/bin/brew", ["--prefix"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard prefix == homebrew else { throw RunnerError.message("Homebrew resolved to an unexpected installation. The host installation was not changed.") }
        }
        homebrewSetup = task
        defer { homebrewSetup = nil }
        try await task.value
    }

    static func arguments(_ executable: String, _ arguments: [String]) -> [String] {
        let environment = RunnerProcess.environment(home: URL(fileURLWithPath: home), inherited: [:]).merging([
            "HOME": home, "USER": username, "LOGNAME": username, "TMPDIR": home + "/.tmp/", "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8"
        ]) { _, new in new }
        return ["-n", "-H", "-u", username, "/usr/bin/env", "-i"]
            + environment.keys.sorted().map { "\($0)=\(environment[$0]!)" } + [executable] + arguments
    }

    private static func run(_ executable: String, _ args: [String], secrets: [String] = []) async throws -> String {
        try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/sudo"), arguments: arguments(executable, args),
                                        directory: URL(fileURLWithPath: "/"), secrets: secrets)
    }
    private func shell(_ script: String, secrets: [String] = []) async throws -> String {
        try await Self.run("/bin/sh", ["-c", script], secrets: secrets)
    }

    static func helperInstallScript(executable: URL, directory: String) throws -> String {
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: contents.appendingPathComponent("Info.plist").path),
              FileManager.default.fileExists(atPath: contents.appendingPathComponent("Frameworks/Sparkle.framework/Sparkle").path) else {
            throw RunnerError.message("Comet’s helper app is incomplete. Launch the complete Comet app before setting up a dedicated runner.")
        }
        let root = VMConnection.quote(directory)
        let destination = VMConnection.quote(directory + "/Comet.app")
        let staging = VMConnection.quote(directory + "/.helper-" + UUID().uuidString)
        return """
        set -eu
        umask 077
        /bin/mkdir -p \(root)
        helper_stage=\(staging)
        trap '/bin/rm -rf "$helper_stage"' EXIT
        /usr/bin/ditto \(VMConnection.quote(contents.deletingLastPathComponent().path)) "$helper_stage/Comet.app"
        /usr/sbin/chown -R _comet:staff "$helper_stage"
        /usr/sbin/chown _comet:staff \(root)
        /bin/chmod 700 \(root)
        /usr/bin/sudo -n -H -u _comet "$helper_stage/Comet.app/Contents/MacOS/Comet" --runner-snapshot \(root) >/dev/null
        if [ -e \(destination) ]; then /bin/mv \(destination) "$helper_stage/previous.app"; fi
        if ! /bin/mv "$helper_stage/Comet.app" \(destination); then
            [ ! -e "$helper_stage/previous.app" ] || /bin/mv "$helper_stage/previous.app" \(destination)
            exit 1
        fi
        """
    }

    @MainActor private func prepareHelper(executable: URL) async throws {
        if let task = Self.helperSetups[id] { try await task.value; return }
        let task = Task {
            // Copy the signed bundle intact; a detached release executable cannot pass signature validation.
            _ = try await Self.run("/usr/bin/sudo", ["-n", "/bin/sh", "-c", try Self.helperInstallScript(executable: executable, directory: directory)])
        }
        Self.helperSetups[id] = task
        defer { Self.helperSetups[id] = nil }
        try await task.value
    }

    public func snapshot(registered: Bool) async throws -> VMSnapshot {
        guard Self.configured else {
            guard !registered else { throw RunnerError.message("The Comet account or its permissions changed. Restore dedicated-user setup before managing this registered runner.") }
            return VMSnapshot(running: false, registrationID: nil, log: "")
        }
        guard let executable = Bundle.main.executableURL else { throw RunnerError.message("Could not locate Comet’s runner helper.") }
        let root = VMConnection.quote(directory)
        let command = helperSelection + "if [ -x \"$helper\" ]; then exec \"$helper\" --runner-snapshot \(root); elif [ -e \(root)/.runner ] || [ -e \(root)/.host.lock ]; then echo 'The dedicated runner helper is missing. Its files have been preserved.' >&2; exit 1; else printf '%s' '{\"running\":false,\"log\":\"\"}'; fi"
        let output: String
        do { output = try await shell(command) }
        catch {
            try Task.checkCancellation()
            try await prepareHelper(executable: executable)
            output = try await shell(command)
        }
        let result = try JSONDecoder().decode(VMSnapshot.self, from: Data(output.utf8))
        guard !registered || result.registrationID != nil else {
            throw RunnerError.message("The dedicated runner registration is missing locally. Its GitHub registration and files have been preserved.")
        }
        return result
    }

    public func install(_ runner: Runner, github: GitHub, executable: URL,
                        progress: @escaping @MainActor @Sendable (String) -> Void) async throws -> Int {
        await progress("Setting up the dedicated macOS user. Approve the administrator prompt if shown…")
        try await Self.prepareHomebrew(github: github, progress: progress)
        let snapshot = try await snapshot(registered: runner.githubID != nil)
        guard !snapshot.running else { throw RunnerError.message("The dedicated runner is already running. Retry Connection instead.") }
        let root = VMConnection.quote(directory)
        _ = try await shell("umask 077; /bin/mkdir -p \(root)")
        try await prepareHelper(executable: executable)
        // Existing registrations cached the previous PATH when config.sh ran.
        if snapshot.registrationID != nil { _ = try await shell("cd \(root) && ./env.sh") }
        if let id = snapshot.registrationID { return id }
        guard try await !github.runners(repository: runner.repository).contains(where: { $0.name == runner.name }) else {
            throw RunnerError.message("A runner named \(runner.name) already exists on GitHub. Recover or remove it before retrying.")
        }
        let archive = try await RunnerInstaller.download(architecture: RunnerProcess.architecture, github: github, progress: progress)
        defer { try? FileManager.default.removeItem(at: archive) }
        await progress("Unpacking the verified runner for _comet…")
        let destination = directory + "/runner.tar.gz"
        _ = try await Self.run("/usr/bin/sudo", ["-n", "/bin/cp", archive.path, destination])
        _ = try await Self.run("/usr/bin/sudo", ["-n", "/usr/sbin/chown", "_comet:staff", destination])
        _ = try await Self.run("/usr/bin/tar", ["-xzf", destination, "-C", directory])
        _ = try await Self.run("/bin/rm", [destination])
        await progress("Registering the dedicated-user runner with GitHub…")
        let token = try await github.registrationToken(repository: runner.repository)
        let args = ["--unattended", "--url", "https://github.com/\(runner.repository)", "--token", token,
                    "--name", runner.name, "--labels", runner.label, "--work", "_work"]
        _ = try await shell("cd \(root) && ./config.sh " + args.map(VMConnection.quote).joined(separator: " "), secrets: [token])
        guard let id = try await self.snapshot(registered: true).registrationID else {
            throw RunnerError.message("The dedicated runner registration was not saved. Its files have been preserved.")
        }
        return id
    }

    public func launch() async throws {
        _ = try await shell(RunnerProcess.backgroundCommand([helper, "--runner-host", directory], directory: directory))
        for _ in 0..<20 {
            if try await snapshot(registered: true).running { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RunnerError.message("The dedicated runner did not start.\n" + (try await snapshot(registered: true)).log)
    }

    public func stop() async throws {
        if try await snapshot(registered: false).running {
            // Stop must also reach commands that the workflow elevated with sudo.
            _ = try await Self.run("/usr/bin/sudo", ["-n", "/bin/sh", "-c",
                helperSelection + "exec \"$helper\" --runner-stop \(VMConnection.quote(directory))"])
        }
        guard try await !snapshot(registered: false).running else { throw RunnerError.message("The dedicated runner has not stopped. Its files have been preserved.") }
    }
}
