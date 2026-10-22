import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class LoginItem {
    private(set) var status: SMAppService.Status
    private let defaults: UserDefaults
    private let readStatus: () -> SMAppService.Status
    private let updateRegistration: (Bool) throws -> Void

    init(defaults: UserDefaults = .standard,
         readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         updateRegistration: @escaping (Bool) throws -> Void = { enabled in
             if enabled { try SMAppService.mainApp.register() }
             else { try SMAppService.mainApp.unregister() }
         }) {
        self.defaults = defaults
        self.readStatus = readStatus
        self.updateRegistration = updateRegistration
        status = readStatus()
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = readStatus() }

    func takePrompt() -> Bool {
        refresh()
        guard status == .notRegistered, !defaults.bool(forKey: "didAskToLaunchAtLogin") else { return false }
        defaults.set(true, forKey: "didAskToLaunchAtLogin")
        return true
    }

    func setEnabled(_ enabled: Bool) throws {
        defaults.set(true, forKey: "didAskToLaunchAtLogin")
        defer { refresh() }
        try updateRegistration(enabled)
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    func offerIfNeeded() {
        guard takePrompt() else { return }
        let alert = NSAlert()
        alert.messageText = "Launch Comet at login?"
        alert.informativeText = "Comet will start quietly in the menu bar when you log in. You can change this in Settings."
        alert.addButton(withTitle: "Launch at Login")
        alert.addButton(withTitle: "Not Now")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try setEnabled(true)
            if status == .requiresApproval { openSystemSettings() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
