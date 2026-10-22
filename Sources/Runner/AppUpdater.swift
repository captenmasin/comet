import AppKit
import Combine
import Observation
import Sparkle
import SwiftUI

@MainActor @Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private(set) var canCheckForUpdates = false
    private(set) var waitingForRunners = false
    var automaticallyChecksForUpdates = false {
        didSet {
            if controller?.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
                controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
        }
    }
    var automaticallyDownloadsUpdates = false {
        didSet {
            if controller?.updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates {
                controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            }
        }
    }
    @ObservationIgnored private weak var store: RunnerStore?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: Set<AnyCancellable> = []
    @ObservationIgnored private var pendingInstallation: Task<Void, Never>?

    init(store: RunnerStore) { self.store = store }

    func start() {
        #if !DEBUG
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] value in
            MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = value }
        }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] value in
            MainActor.assumeIsolated { self?.automaticallyDownloadsUpdates = value }
        }.store(in: &observations)
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    func postponeInstallation(_ install: @escaping () -> Void) -> Bool {
        guard store?.canInstallUpdate == false else { return false }
        waitingForRunners = true
        pendingInstallation?.cancel()
        pendingInstallation = Task { [weak self] in
            while !Task.isCancelled, let self, self.store != nil {
                if self.store?.canInstallUpdate == true {
                    self.waitingForRunners = false
                    self.pendingInstallation = nil
                    install()
                    return
                }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
        return true
    }

    func cancelPendingInstallation() {
        pendingInstallation?.cancel()
        pendingInstallation = nil
        waitingForRunners = false
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard postponeInstallation(installHandler) else { return false }
        let alert = NSAlert()
        alert.messageText = "Stop runners to install the update"
        alert.informativeText = "Comet will install the downloaded update after you stop all runners. Your current jobs will keep running."
        alert.runModal()
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        // Keep background updates queued for normal Quit, which already stops runners safely.
        true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) { cancelPendingInstallation() }
}

struct CheckForUpdatesButton: View {
    let updater: AppUpdater
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
