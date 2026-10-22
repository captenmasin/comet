import Foundation
import Testing
@testable import RunnerCore

private func vmToolExecutable(_ file: URL, _ contents: String) throws {
    try Data(contents.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
}

@Test(arguments: ["missing-clt", "missing-brew", "wrong-prefix", "sudo-denied", "ready"], ["/bin/bash", "/bin/zsh"])
func vmToolsStatusRequiresWorkingDeveloperToolsAndHomebrew(state: String, shell: String) async throws {
    let root = URL.temporaryDirectory.appendingPathComponent("comet-tools-status-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("bin")
    let developer = root.appendingPathComponent("developer")
    let prefix = root.appendingPathComponent("homebrew")
    for directory in [bin, developer, prefix.appendingPathComponent("bin")] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try vmToolExecutable(bin.appendingPathComponent("xcode-select"), """
    #!/bin/sh
    \(state == "missing-clt" ? "exit 1" : "printf '%s\\n' '\(developer.path)'")
    """)
    try vmToolExecutable(bin.appendingPathComponent("xcrun"), """
    #!/bin/sh
    [ "$1" = --find ] || exit 81
    case "$2" in git|clang) printf '%s\\n' '\(bin.path)'/"$2";; *) exit 82;; esac
    """)
    for tool in ["git", "clang"] {
        try vmToolExecutable(bin.appendingPathComponent(tool), "#!/bin/sh\n[ \"$1\" = --version ]\n")
    }
    try vmToolExecutable(bin.appendingPathComponent("sudo"), """
    #!/bin/sh
    [ "$#" = 3 ] && [ "$1" = -n ] && [ "$2" = -k ] && [ "$3" = /usr/bin/true ] || exit 80
    exit \(state == "sudo-denied" ? 1 : 0)
    """)
    if state != "missing-brew" {
        try vmToolExecutable(prefix.appendingPathComponent("bin/brew"), """
        #!/bin/sh
        [ "$1" = --prefix ] || exit 83
        printf '%s\\n' '\(state == "wrong-prefix" ? root.path : prefix.path)'
        """)
    }
    var script = VMTools.statusScript.replacingOccurrences(of: "/opt/homebrew", with: prefix.path)
    for tool in ["xcode-select", "xcrun", "git", "clang", "sudo"] {
        script = script.replacingOccurrences(of: "/usr/bin/" + tool, with: bin.appendingPathComponent(tool).path)
    }

    let output = try await RunnerProcess.command(URL(fileURLWithPath: shell), arguments: ["-c", script], directory: root)

    #expect(output == (state == "ready" ? "ready\n" : ""))
}

@Test(arguments: ["success", "installer-failure", "retry-success", "retry-failure", "download-failure", "policy-validation-failure", "policy-conflict"], ["/bin/bash", "/bin/zsh"])
func vmToolsBootstrapUsesScopedCredentialsAndCleansUp(result: String, shell: String) async throws {
    let root = URL.temporaryDirectory.appendingPathComponent("comet-tools-install-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = "fixture 'quoted' $(touch injected) `touch injected` \\ password"
    let policyFailure = result == "policy-validation-failure" || result == "policy-conflict"
    let policyDirectory = root.appendingPathComponent("sudoers.d")
    let policy = policyDirectory.appendingPathComponent("comet")
    let expectedPolicy = "# Comet macOS VM runner; grants workflows root access inside this guest.\ncomet ALL=(ALL) NOPASSWD: ALL\n"
    if policyFailure {
        try FileManager.default.createDirectory(at: policyDirectory, withIntermediateDirectories: true)
        try Data("preserved-policy\n".utf8).write(to: policy)
    }
    let developer = root.appendingPathComponent("developer")
    if result == "installer-failure" {
        try FileManager.default.createDirectory(at: developer.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
        for tool in ["git", "clang"] {
            try vmToolExecutable(developer.appendingPathComponent("usr/bin/" + tool), "#!/bin/sh\nexit 0\n")
        }
    }
    try vmToolExecutable(root.appendingPathComponent("xcode-select"), """
    #!/bin/sh
    [ "$1" = -p ] || exit 98
    \(result == "installer-failure" ? "printf '%s\\n' '\(developer.path)'" : "exit 1")
    """)
    try vmToolExecutable(root.appendingPathComponent("id"), "#!/bin/sh\n[ \"$1\" = -un ] || exit 91\nprintf 'comet\\n'\n")
    try vmToolExecutable(root.appendingPathComponent("sudo"), #"""
    #!/bin/sh
    set -eu
    case "$1" in
        -A)
            shift
            [ "$("$SUDO_ASKPASS")" = "$FIXTURE_PASSWORD" ] || exit 92
            exec "$@"
            ;;
        -n)
            [ "$#" = 3 ] && [ "$2" = -k ] && [ "$3" = /usr/bin/true ] &&
                [ -f "$FIXTURE_ROOT/sudoers.d/comet" ]
            ;;
        *) exit 93 ;;
    esac
    """#)
    try vmToolExecutable(root.appendingPathComponent("chown"), #"""
    #!/bin/sh
    set -eu
    [ "$1" = root:wheel ] || exit 94
    case "$2" in "$FIXTURE_ROOT"/sudoers.d/.comet.*) ;; *) exit 95;; esac
    printf '%s\n' "$@" > "$FIXTURE_ROOT/chown-arguments"
    """#)
    try vmToolExecutable(root.appendingPathComponent("visudo"), #"""
    #!/bin/sh
    set -eu
    [ "$1" = -cf ] || exit 96
    [ "$(/usr/bin/stat -f '%Lp' "$2")" = 440 ] || exit 97
    /bin/cp "$2" "$FIXTURE_ROOT/validated-policy"
    if [ "$FIXTURE_RESULT" = policy-validation-failure ]; then echo fixture-policy-invalid >&2; exit 42; fi
    exec /usr/sbin/visudo "$@" >/dev/null
    """#)
    let curl = root.appendingPathComponent("curl")
    try vmToolExecutable(curl, #"""
    #!/bin/sh
    set -eu
    printf '%s\n' "$@" > "$FIXTURE_ROOT/curl-arguments"
    [ "$FIXTURE_RESULT" != download-failure ] || { echo fixture-download-failed >&2; exit 22; }
    destination=''
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then shift; destination=$1; fi
        shift
    done
    [ -n "$destination" ] || exit 84
    /bin/cp "$FIXTURE_ROOT/vendor-installer" "$destination"
    """#)
    try Data(#"""
    #!/bin/bash
    set -eu
    [ "${NONINTERACTIVE:-}" = 1 ] || exit 85
    [ -x "$SUDO_ASKPASS" ] || exit 86
    [ "$COMET_VM_SUDO_PASSWORD" = "$FIXTURE_PASSWORD" ] || exit 87
    [ "$("$SUDO_ASKPASS")" = "$FIXTURE_PASSWORD" ] || exit 88
    [ "$(/usr/bin/stat -f '%Lp' "$SUDO_ASKPASS")" = 700 ] || exit 89
    [ "$(/usr/bin/stat -f '%Lp' "${SUDO_ASKPASS%/*}")" = 700 ] || exit 99
    [ "$(/usr/bin/stat -f '%Lp' "$0")" = 600 ] || exit 100
    if /usr/bin/grep -q -F -- "$FIXTURE_PASSWORD" "$SUDO_ASKPASS" "$0"; then exit 90; fi
    printf '%s\n' "$SUDO_ASKPASS" > "$FIXTURE_ROOT/askpass-path"
    printf 'attempt\n' >> "$FIXTURE_ROOT/installer-attempts"
    attempt=$(/usr/bin/wc -l < "$FIXTURE_ROOT/installer-attempts")
    marker="$FIXTURE_ROOT/shared-marker-$((attempt))"
    : > "$marker"
    [ "$(/usr/bin/stat -f '%Lp' "$marker")" = 644 ] || exit 101
    if [ "$FIXTURE_RESULT" = installer-failure ]; then echo fixture-installer-failed >&2; exit 7; fi
    case "$FIXTURE_RESULT" in
        retry-success|retry-failure)
            if [ "$attempt" -eq 1 ]; then echo fixture-installer-failed >&2; exit 7; fi
            if [ "$FIXTURE_RESULT" = retry-failure ]; then echo fixture-retry-failed >&2; exit 29; fi
            ;;
    esac
    printf 'installed\n'
    """#.utf8).write(to: root.appendingPathComponent("vendor-installer"))
    var script = VMTools.installScript
        .replacingOccurrences(of: "/usr/bin/curl", with: curl.path)
        .replacingOccurrences(of: "/tmp/comet-tools.XXXXXX", with: root.appendingPathComponent("temporary.XXXXXX").path)
        .replacingOccurrences(of: "/private/etc/sudoers.d", with: policyDirectory.path)
    for (path, stub) in [("/usr/bin/id", "id"), ("/usr/bin/sudo", "sudo"),
                         ("/usr/sbin/chown", "chown"), ("/usr/sbin/visudo", "visudo"),
                         ("/usr/bin/xcode-select", "xcode-select")] {
        script = script.replacingOccurrences(of: path, with: root.appendingPathComponent(stub).path)
    }
    let environment = ["FIXTURE_ROOT": root.path, "FIXTURE_RESULT": result, "FIXTURE_PASSWORD": secret]
    do {
        let output = try await RunnerProcess.command(URL(fileURLWithPath: shell), arguments: ["-c", script],
            directory: root, secrets: [secret], extraEnvironment: environment, input: Data((secret + "\n").utf8))
        #expect(result == "success" || result == "retry-success")
        #expect(output.hasSuffix("installed\n"))
        if result == "retry-success" { #expect(output.contains("fixture-installer-failed")) }
    } catch {
        #expect(result != "success" && result != "retry-success")
        #expect(error is RunnerError)
        let (status, message) = switch result {
        case "policy-validation-failure": (42, "fixture-policy-invalid")
        case "policy-conflict": (1, "unmanaged guest sudo policy")
        case "download-failure": (22, "fixture-download-failed")
        case "retry-failure": (29, "fixture-retry-failed")
        default: (7, "fixture-installer-failed")
        }
        #expect(error.localizedDescription.contains("(\(status))"))
        #expect(error.localizedDescription.contains(message))
        if result == "retry-failure" { #expect(error.localizedDescription.contains("fixture-installer-failed")) }
        #expect(!error.localizedDescription.contains(secret))
    }
    let expectedAttempts = result == "retry-success" || result == "retry-failure" ? 2
        : result == "success" || result == "installer-failure" ? 1 : 0
    let attempts = root.appendingPathComponent("installer-attempts")
    if expectedAttempts == 0 {
        #expect(!FileManager.default.fileExists(atPath: attempts.path))
    } else {
        #expect(try String(contentsOf: attempts, encoding: .utf8).split(separator: "\n").count == expectedAttempts)
        for attempt in 1...expectedAttempts {
            let marker = root.appendingPathComponent("shared-marker-\(attempt)")
            #expect(try FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions] as? Int == 0o644)
        }
    }
    if !policyFailure {
        let arguments = try String(contentsOf: root.appendingPathComponent("curl-arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        try #require(arguments.count == 11)
        #expect(Array(arguments.prefix(9)) == ["--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https", "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"])
        #expect(arguments[9] == "-o")
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: arguments[10]).deletingLastPathComponent().path))
    }
    if expectedAttempts > 0 {
        let askpass = try String(contentsOf: root.appendingPathComponent("askpass-path"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: askpass))
    }
    if policyFailure {
        #expect(try String(contentsOf: policy, encoding: .utf8) == "preserved-policy\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("curl-arguments").path))
    } else {
        #expect(try String(contentsOf: policy, encoding: .utf8) == expectedPolicy)
        #expect(try FileManager.default.attributesOfItem(atPath: policy.path)[.posixPermissions] as? Int == 0o440)
    }
    #expect(try String(contentsOf: root.appendingPathComponent("validated-policy"), encoding: .utf8) == expectedPolicy)
    let ownership = try String(contentsOf: root.appendingPathComponent("chown-arguments"), encoding: .utf8)
        .split(separator: "\n")
    #expect(ownership.count == 2 && ownership.first == "root:wheel")
    #expect(try FileManager.default.contentsOfDirectory(atPath: policyDirectory.path) == ["comet"])
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix("temporary.") })
    let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        .allObjects.compactMap { $0 as? URL }
    for file in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains(secret))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
    #expect(!VMTools.installScript.contains("--agree-to-license"))
    #expect(!VMTools.installScript.contains("license accept"))
    #expect(!VMTools.installScript.contains("%admin"))
}
