import AppKit
import Foundation
import Observation
import RunnerCore
import Synchronization
import Virtualization

final class RestoreDownloadProgress: NSObject, URLSessionTaskDelegate {
    let report: @MainActor @Sendable (Double?, String) -> Void
    private let observation = Mutex<NSKeyValueObservation?>(nil)
    private let lastUpdate = Mutex((bytes: Int64(-1), percent: -2))
    init(report: @escaping @MainActor @Sendable (Double?, String) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        // The async download API supplies task callbacks, not download-delegate progress callbacks.
        let token = task.observe(\.countOfBytesReceived, options: [.initial, .new]) { [weak self] task, _ in
            self?.update(written: task.countOfBytesReceived, expected: task.countOfBytesExpectedToReceive)
        }
        observation.withLock { $0 = token }
    }

    func update(written: Int64, expected: Int64) {
        guard written >= 0 else { return }
        let fraction = expected > 0 ? min(1, Double(written) / Double(expected)) : nil
        let percent = fraction.map { Int($0 * 100) } ?? -1
        let changed = lastUpdate.withLock { last in
            guard last.bytes < 0 || last.percent != percent || written - last.bytes >= 1_048_576 else { return false }
            last = (written, percent)
            return true
        }
        if changed {
            let received = written.formatted(.byteCount(style: .file))
            let size = if expected > 0 {
                "\(received) of \(expected.formatted(.byteCount(style: .file))) (\(percent)%)"
            } else if written > 0 {
                "\(received) received · total size unavailable"
            } else {
                "Waiting for data from Apple…"
            }
            Task { await report(fraction, size) }
        }
    }
}

@MainActor @Observable
final class MacVirtualMachines {
    private var machines: [UUID: VZVirtualMachine] = [:]
    private var connections: [UUID: VMConnection] = [:]
    private var windows: [UUID: NSWindow] = [:]
    private var downloadTask: Task<URL, any Error>?
    var downloadMessage: String?
    var downloadProgress: Double?
    var downloadSize: String?
    var installationProgress: [UUID: Double] = [:]
    var isDownloading: Bool { downloadTask != nil }
    var isStoppingDownload: Bool { downloadTask?.isCancelled == true }

    static var available: Bool {
        #if arch(arm64)
        if #available(macOS 27, *) { return VZVirtualMachine.isSupported }
        #endif
        return false
    }
    static let requirement = "Automatic VM setup requires Apple Silicon and macOS 27 or later."
    static func installer(paths: AppPaths) -> URL { paths.root.appendingPathComponent("macOS.ipsw") }
    func hasInstaller(paths: AppPaths) -> Bool {
        // Observe download completion so setup controls refresh when the cached file appears.
        !isDownloading && FileManager.default.fileExists(atPath: Self.installer(paths: paths).path)
    }

    func downloadInstaller(paths: AppPaths) async {
        #if arch(arm64)
        guard #available(macOS 27, *), Self.available else { downloadMessage = Self.requirement; return }
        guard downloadTask == nil, !hasInstaller(paths: paths) else { return }
        downloadProgress = nil
        downloadSize = nil
        let task = Task { [self] in
            try paths.prepare()
            let free = try paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard free >= 80 * 1024 * 1024 * 1024 else { throw RunnerError.message("Free at least 80 GB for the installer and a macOS VM.") }
            downloadMessage = "Finding the macOS installer from Apple…"
            let image = try await VZMacOSRestoreImage.latestSupported
            guard image.operatingSystemVersion.majorVersion >= 27 else {
                throw RunnerError.message("Apple has not supplied a compatible macOS 27 restore image. Automatic setup requires macOS 27 or later.")
            }
            try Task.checkCancellation()
            downloadMessage = "Downloading macOS from Apple…"
            let delegate = RestoreDownloadProgress { [weak self] fraction, size in
                guard let self, self.isDownloading, !self.isStoppingDownload else { return }
                self.downloadProgress = fraction
                self.downloadSize = size
            }
            let (file, response) = try await URLSession.shared.download(for: URLRequest(url: image.url), delegate: delegate)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw RunnerError.message("The macOS download failed. Try again when Apple’s download service is reachable.")
            }
            try Task.checkCancellation()
            let destination = Self.installer(paths: paths)
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        }
        downloadTask = task
        defer {
            downloadTask = nil
            downloadProgress = nil
            downloadSize = nil
        }
        do {
            _ = try await task.value
            downloadMessage = "macOS installer downloaded. It will be reused for VM setup."
        } catch is CancellationError {
            downloadMessage = "Download stopped."
        } catch {
            downloadMessage = task.isCancelled ? "Download stopped." : error.localizedDescription
        }
        #else
        downloadMessage = Self.requirement
        #endif
    }
    func cancelDownload() {
        guard let downloadTask, !downloadTask.isCancelled else { return }
        downloadMessage = "Stopping download…"
        downloadTask.cancel()
    }
    func finishCancellingDownload() async {
        cancelDownload()
        _ = try? await downloadTask?.value
    }
    func isRunning(_ id: UUID) -> Bool {
        guard let machine = machines[id] else { return false }
        return machine.state != .stopped && machine.state != .error
    }
    func connection(_ id: UUID) throws -> VMConnection {
        guard isRunning(id), let connection = connections[id] else {
            throw RunnerError.message("The VM is not connected. Stop it and start the runner again.")
        }
        return connection
    }
    func show(_ id: UUID) {
        guard let machine = machines[id] else { return }
        if let window = windows[id] { window.makeKeyAndOrderFront(nil); return }
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Comet · macOS VM"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func stop(_ id: UUID) async throws {
        guard let machine = machines[id] else { return }
        if isRunning(id) {
            if let connection = connections[id] {
                let helper = VMConnection.quote(VMConnection.guestHelper)
                // Normal macOS shutdown also stops jobs if the guest connection has failed.
                _ = try? await connection.command("if [ -x \(helper) ]; then \(helper) --runner-stop \(VMConnection.quote(VMConnection.guestDirectory)); fi; /usr/bin/sudo -n /sbin/shutdown -h now")
            }
            if machine.state != .stopped, machine.state != .stopping {
                guard machine.canRequestStop else { throw RunnerError.message("The VM cannot shut down yet. Open it and try again once it finishes starting.") }
                try machine.requestStop()
            }
            for _ in 0..<120 {
                if machine.state == .stopped { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard machine.state == .stopped else { throw RunnerError.message("macOS has not shut down. Open the VM, finish shutting it down, then retry Stop.") }
        }
        connections[id] = nil
        windows.removeValue(forKey: id)?.close()
        machines[id] = nil
    }
    func start(_ runner: Runner, paths: AppPaths,
               progress: @escaping @MainActor @Sendable (String) -> Void) async throws -> VMConnection {
        #if arch(arm64)
        guard #available(macOS 27, *), Self.available else { throw RunnerError.message(Self.requirement) }
        let directory = paths.directory(runner.id).appendingPathComponent("vm")
        let installed = directory.appendingPathComponent("installed")
        let needsInstall = !FileManager.default.fileExists(atPath: installed.path)
        // Choosing VM execution never starts an installer download.
        guard !needsInstall || hasInstaller(paths: paths) else {
            throw RunnerError.message("Download macOS in Configuration first, then start the runner. No download has been started.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let password: String
        if let saved = try Keychain.load(service: "dev.runnerbar.vm", account: runner.id.uuidString) {
            password = saved
        } else {
            guard needsInstall else { throw RunnerError.message("The VM password is missing from Keychain. Its disk has been preserved for recovery.") }
            password = UUID().uuidString + UUID().uuidString
            try Keychain.save(password, service: "dev.runnerbar.vm", account: runner.id.uuidString)
        }
        let restore = needsInstall ? Self.installer(paths: paths) : nil
        let configuration = try await configuration(directory: directory, restore: restore)
        let machine = VZVirtualMachine(configuration: configuration)
        windows.removeValue(forKey: runner.id)?.close()
        machines[runner.id] = machine
        if let restore {
            progress("Installing macOS in the VM…")
            let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: restore)
            installationProgress[runner.id] = 0
            let updates = Task {
                while !Task.isCancelled {
                    let fraction = installer.progress.fractionCompleted
                    installationProgress[runner.id] = fraction
                    progress("Installing macOS… \(Int(fraction * 100))%")
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer {
                updates.cancel()
                installationProgress[runner.id] = nil
            }
            try await installer.install()
            try Data().write(to: installed, options: .atomic)
        }
        progress("Starting macOS…")
        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.fullName = "Comet Runner"
        provisioning.username = "comet"
        provisioning.password = password
        provisioning.logsInAutomatically = true
        provisioning.enablesRemoteLogin = true
        let options = VZMacOSVirtualMachineStartOptions()
        try options.setGuestProvisioning(provisioning)
        try await machine.start(options: options)
        progress("Waiting for macOS to finish setting up…")
        let mac = configuration.networkDevices[0].macAddress.string
        var lastError = "The VM has not received a network address yet."
        for _ in 0..<180 {
            try Task.checkCancellation()
            guard isRunning(runner.id) else { throw RunnerError.message("The VM stopped during startup. Its disk has been preserved.") }
            if let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8),
               let address = VMConnection.address(for: mac, leases: leases) {
                let connection = try VMConnection(address: address, directory: directory, password: password)
                do {
                    let identity = try await connection.command("/usr/bin/uname -sm")
                    guard identity.trimmingCharacters(in: .whitespacesAndNewlines) == "Darwin arm64" else { throw RunnerError.message("The guest is not an Apple Silicon Mac.") }
                    connections[runner.id] = connection
                    return connection
                } catch { lastError = error.localizedDescription }
            }
            try await Task.sleep(for: .seconds(3))
        }
        show(runner.id)
        throw RunnerError.message("macOS did not become ready. Open the VM to inspect setup, then stop and retry. \(lastError)")
        #else
        throw RunnerError.message(Self.requirement)
        #endif
    }

    #if arch(arm64)
    private struct Identity: Codable {
        let hardware: Data
        let machine: Data
        let mac: String
        let cpuCount: Int
        let memorySize: UInt64
    }
    private func configuration(directory: URL, restore: URL?) async throws -> VZVirtualMachineConfiguration {
        let identityFile = directory.appendingPathComponent("identity.json")
        let identity: Identity
        if let restore {
            let image = try await VZMacOSRestoreImage.image(from: restore)
            guard image.operatingSystemVersion.majorVersion >= 27, let requirements = image.mostFeaturefulSupportedConfiguration else {
                throw RunnerError.message("This installer is incompatible. Download a supported macOS 27 installer before VM setup.")
            }
            if FileManager.default.fileExists(atPath: identityFile.path) {
                identity = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: identityFile))
            } else {
                identity = Identity(hardware: requirements.hardwareModel.dataRepresentation,
                                    machine: VZMacMachineIdentifier().dataRepresentation,
                                    mac: VZMACAddress.randomLocallyAdministered().string,
                                    cpuCount: max(requirements.minimumSupportedCPUCount, min(4, VZVirtualMachineConfiguration.maximumAllowedCPUCount)),
                                    memorySize: max(requirements.minimumSupportedMemorySize, 4 * 1024 * 1024 * 1024))
                try JSONEncoder().encode(identity).write(to: identityFile, options: .atomic)
                _ = try VZMacAuxiliaryStorage(creatingStorageAt: directory.appendingPathComponent("auxiliary"), hardwareModel: requirements.hardwareModel)
            }
        } else {
            identity = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: identityFile))
        }
        guard let hardware = VZMacHardwareModel(dataRepresentation: identity.hardware), hardware.isSupported,
              let identifier = VZMacMachineIdentifier(dataRepresentation: identity.machine),
              let mac = VZMACAddress(string: identity.mac) else { throw RunnerError.message("The VM identity is invalid or incompatible. Its files have been preserved.") }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardware
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: directory.appendingPathComponent("auxiliary"))
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = identity.cpuCount
        configuration.memorySize = identity.memorySize
        let disk = directory.appendingPathComponent("disk.img")
        if !FileManager.default.fileExists(atPath: disk.path) {
            guard FileManager.default.createFile(atPath: disk.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RunnerError.message("Could not create the VM disk.") }
            let handle = try FileHandle(forWritingTo: disk)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 64 * 1024 * 1024 * 1024)
        }
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false))]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.macAddress = mac
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1440, heightInPixels: 900, pixelsPerInch: 110)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        try configuration.validate()
        return configuration
    }
    #endif
}
