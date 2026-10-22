import Foundation
import Darwin

public enum RunnerExecution: String, Codable, CaseIterable, Sendable {
    case host, dedicatedUser, macOSVM
    public var title: String {
        switch self {
        case .host: "Current macOS user"
        case .dedicatedUser: "Dedicated user (sudo)"
        case .macOSVM: "macOS VM"
        }
    }
    public var explanation: String {
        switch self {
        case .host: "Workflows run as you, with access to your files, tools, and credentials. Only connect repositories and workflows you trust."
        case .dedicatedUser: "Workflows run as _comet with a separate home, Homebrew installation, and passwordless sudo. They can modify this Mac and access your files as root. First start requires administrator approval."
        case .macOSVM: "Workflows have root access inside the VM. Setup actions can install tools there. The guest has network access; only connect workflows you trust."
        }
    }
}

public struct Runner: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let repository: String
    public let name: String
    public let label: String
    public var githubID: Int?
    public let execution: RunnerExecution
    public var watchForJobs: Bool
    public var runAutomatically: Bool

    public init(id: UUID = UUID(), repository: String, name: String, label: String, githubID: Int? = nil, execution: RunnerExecution = .host, watchForJobs: Bool = false, runAutomatically: Bool = false) throws {
        guard Self.validRepository(repository), Self.validName(name), Self.validName(label) else {
            throw RunnerError.message("Use owner/repository and names or labels containing only letters, numbers, hyphens, underscores, and dots (1–64 characters).")
        }
        self.id = id
        self.repository = repository
        self.name = name
        self.label = label
        self.githubID = githubID
        self.execution = execution
        self.watchForJobs = execution == .macOSVM && watchForJobs
        self.runAutomatically = runAutomatically
    }

    private enum CodingKeys: String, CodingKey { case id, repository, name, label, githubID, execution, watchForJobs, runAutomatically }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      repository: values.decode(String.self, forKey: .repository),
                      name: values.decode(String.self, forKey: .name),
                      label: values.decode(String.self, forKey: .label),
                      githubID: values.decodeIfPresent(Int.self, forKey: .githubID),
                      execution: values.decodeIfPresent(RunnerExecution.self, forKey: .execution) ?? .host,
                      watchForJobs: values.decodeIfPresent(Bool.self, forKey: .watchForJobs) ?? false,
                      runAutomatically: values.decodeIfPresent(Bool.self, forKey: .runAutomatically) ?? false)
    }

    public static func validName(_ value: String) -> Bool { validIdentifier(value, limit: 64) }

    private static func validIdentifier(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95, 46].contains($0)
        } && value != "." && value != ".."
    }

    public static func validRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && validIdentifier(String(parts[0]), limit: 39) && validIdentifier(String(parts[1]), limit: 100)
    }

    public var workflow: String { "runs-on: [self-hosted, macOS, \(label)]" }
}

public enum RunnerState: String, Sendable {
    case stopped = "Stopped", starting = "Starting", ready = "Ready", busy = "Running job"
    case reconnecting = "Reconnecting", attention = "Needs attention", stopping = "Stopping"
    case sleeping = "Sleeping"

    public var context: String {
        switch self {
        case .stopped: "Start when you’re ready"
        case .starting: "Waiting for GitHub to confirm connectivity"
        case .ready: "Waiting for a job"
        case .busy: "A workflow is running"
        case .reconnecting: "Checking runner connectivity"
        case .attention: "Open the window for details"
        case .stopping: "Waiting for the runner to exit"
        case .sleeping: "Wakes for queued jobs"
        }
    }
}

public enum RunnerError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

public struct Repository: Decodable, Identifiable, Sendable {
    public let id: Int
    public let full_name: String
    public let permissions: Permissions?
    public struct Permissions: Decodable, Sendable { public let admin: Bool? }
}

public struct RemoteRunner: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let status: String
    public let busy: Bool
}

public struct WorkflowRun: Decodable, Identifiable, Sendable {
    public let id: Int
    public let name: String?
    public let head_branch: String?
    public let head_sha: String
    public let status: String
    public let conclusion: String?
    public let html_url: URL
    public let created_at: String
    public let updated_at: String
}

public struct Job: Decodable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let status: String
    public let conclusion: String?
    public let runner_id: Int?
    public let html_url: URL
    public let started_at: String?
    public let completed_at: String?
    public let steps: [JobStep]?
    public var labels: [String]? = nil
}

public struct JobStep: Decodable, Sendable {
    public let number: Int
    public let name: String
    public let status: String
    public let conclusion: String?
    public let started_at: String?
    public let completed_at: String?
}

public struct RunnerActivity: Sendable {
    public let job: Job
    public let run: WorkflowRun
}

public struct AppPaths: Sendable {
    public let root: URL
    public let runnersRoot: URL

    public init(root: URL? = nil, runnersRoot: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RunnerBar")
        self.runnersRoot = runnersRoot ?? root?.appendingPathComponent("runners")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".comet/runners")
    }

    public func directory(_ id: UUID) -> URL { runnersRoot.appendingPathComponent(id.uuidString) }

    public func prepare(migratingFrom legacyRunnerDirectory: URL? = nil) throws {
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let legacy = legacyRunnerDirectory ?? root.appendingPathComponent("runners")
        if legacy.standardizedFileURL != runnersRoot.standardizedFileURL {
            try migrateRunners(from: legacy, singleRunner: legacyRunnerDirectory != nil)
        }
        try privateDirectory(runnersRoot)
    }

    private func privateDirectory(_ url: URL) throws {
        let files = FileManager.default
        if let attributes = try? files.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw RunnerError.message("Comet cannot use \(url.path): it must be a directory owned by your account. Existing files were preserved.")
            }
        } else {
            try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func migrateRunners(from legacy: URL, singleRunner: Bool) throws {
        let files = FileManager.default
        let migration = open(root.appendingPathComponent(".migration.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard migration >= 0 else { throw RunnerError.message("Could not lock Comet’s storage for migration.") }
        defer { flock(migration, LOCK_UN); close(migration) }
        guard flock(migration, LOCK_EX | LOCK_NB) == 0 else {
            throw RunnerError.message("Another Comet instance is updating runner storage. Quit it and reopen Comet.")
        }
        try privateDirectory(runnersRoot.deletingLastPathComponent())
        let attributes = try? files.attributesOfItem(atPath: legacy.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            guard try files.destinationOfSymbolicLink(atPath: legacy.path) == runnersRoot.path else {
                throw RunnerError.message("Comet’s previous runner folder is an unexpected symbolic link. Existing files were preserved.")
            }
            return
        }
        if attributes != nil {
            guard !files.fileExists(atPath: runnersRoot.path),
                  (try? files.attributesOfItem(atPath: runnersRoot.path)) == nil else {
                throw RunnerError.message("Both old and new Comet runner folders exist. Existing files were preserved; resolve the storage conflict before reopening Comet.")
            }
            try privateDirectory(legacy)
            var locks: [Int32] = []
            defer { for fd in locks { flock(fd, LOCK_UN); close(fd) } }
            let directories = if singleRunner { [legacy] } else {
                try files.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
                    .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            }
            for directory in directories {
                try privateDirectory(directory)
                let fd = open(directory.appendingPathComponent(".host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw RunnerError.message("Could not lock a runner for migration. Existing files were preserved.") }
                locks.append(fd)
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    throw RunnerError.message("Stop all runners in the previous Comet app, then reopen it to move runner storage. Existing files were preserved.")
                }
            }
            try files.moveItem(at: legacy, to: runnersRoot)
        } else {
            try privateDirectory(runnersRoot)
        }
        // Keep cached tools with embedded paths usable after moving the physical workspace.
        try files.createSymbolicLink(at: legacy, withDestinationURL: runnersRoot)
    }
    public func load() throws -> [Runner] {
        let file = root.appendingPathComponent("runners.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let runners = try JSONDecoder().decode([Runner].self, from: Data(contentsOf: file))
        guard Set(runners.map(\.id)).count == runners.count,
              runners.allSatisfy({ Runner.validRepository($0.repository) && Runner.validName($0.name) && Runner.validName($0.label) }) else {
            throw RunnerError.message("Saved runner configuration is invalid. It has been preserved for recovery.")
        }
        return runners
    }
    public func save(_ runners: [Runner]) throws {
        try prepare()
        let file = root.appendingPathComponent("runners.json")
        // Runner metadata must remain readable while the desktop is locked, like its Keychain token.
        try JSONEncoder().encode(runners).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
