import Foundation
import ServiceManagement
import Testing
@testable import Runner

@MainActor
struct LoginItemTests {
    private let suite = "Comet.LoginItemTests.\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    @Test func promptIsOfferedOnlyOnceAcrossLaunches() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = LoginItem(defaults: defaults, readStatus: { .notRegistered }, updateRegistration: { _ in
            Issue.record("Prompting must not register a login item")
        })
        #expect(item.takePrompt())
        #expect(!item.isEnabled)
        #expect(!item.takePrompt())
        let relaunched = LoginItem(defaults: defaults, readStatus: { .notRegistered })
        #expect(!relaunched.takePrompt())
    }

    @Test(arguments: [SMAppService.Status.enabled, .requiresApproval, .notFound])
    func alreadyRegisteredOrUnbundledAppsDoNotPrompt(status: SMAppService.Status) {
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = LoginItem(defaults: defaults, readStatus: { status })
        #expect(!item.takePrompt())
    }

    @Test func registrationAndExternalChangesUseSystemStatus() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        var status = SMAppService.Status.notRegistered
        var changes: [Bool] = []
        let item = LoginItem(defaults: defaults, readStatus: { status }, updateRegistration: { enabled in
            changes.append(enabled)
            status = enabled ? .requiresApproval : .notRegistered
        })
        try item.setEnabled(true)
        #expect(item.isEnabled)
        #expect(item.status == .requiresApproval)
        #expect(!item.takePrompt())
        status = .enabled
        item.refresh()
        #expect(item.status == .enabled)
        try item.setEnabled(false)
        #expect(!item.isEnabled)
        #expect(changes == [true, false])
        #expect(!item.takePrompt())
        status = .enabled
        item.refresh()
        #expect(item.isEnabled)
    }

    @Test(arguments: [false, true])
    func failedRegistrationChangesPreserveSystemState(initiallyEnabled: Bool) {
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = LoginItem(defaults: defaults, readStatus: { initiallyEnabled ? .enabled : .notRegistered },
                             updateRegistration: { _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(throws: CocoaError.self) { try item.setEnabled(!initiallyEnabled) }
        #expect(item.isEnabled == initiallyEnabled)
    }
}
