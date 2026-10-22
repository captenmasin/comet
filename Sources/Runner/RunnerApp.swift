import AppKit
import Observation
import Sparkle
import SwiftUI
import RunnerCore

@main
struct Entry {
    #if DEBUG
    static func simulatesRunningJob(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("--simulate-running-job")
    }
    #endif

    @MainActor static func main() async {
        if CommandLine.arguments.count == 3,
           ["--runner-host", "--runner-host-once"].contains(CommandLine.arguments[1]) {
            exit(RunnerProcess.host(directory: URL(fileURLWithPath: CommandLine.arguments[2]),
                                    once: CommandLine.arguments[1] == "--runner-host-once"))
        }
        if CommandLine.arguments.count == 3,
           ["--runner-snapshot", "--runner-stop", "--runner-migrate"].contains(CommandLine.arguments[1]) {
            do {
                let directory = URL(fileURLWithPath: CommandLine.arguments[2])
                if CommandLine.arguments[1] == "--runner-migrate" {
                    try VMConnection.prepareGuestDirectory(home: directory)
                } else if CommandLine.arguments[1] == "--runner-stop" {
                    try await RunnerProcess.stop(directory)
                } else {
                    let snapshot = try await VMSnapshot.read(directory)
                    print(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self))
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(RunnerProcess.sanitized(error.localizedDescription).utf8))
                exit(1)
            }
        }
        AppLog.start()
        RunnerApp.main()
    }
}

@MainActor
struct RunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var store: RunnerStore { delegate.store }

    var body: some Scene {
        @Bindable var delegate = delegate
        Window("Comet", id: "main") {
            MainWindow(store: store)
        }
        .defaultSize(width: 940, height: 650)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(delegate.showMainWindowOnLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: store.updates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Runner…") { store.showSetup = true }
                    .keyboardShortcut("n")
            }
        }
        MenuBarExtra(isInserted: $delegate.menuBarInserted) {
            RunnerPopover(store: store)
        } label: {
            Label { Text("Comet: \(store.menuBarState.rawValue)") } icon: {
                MenuBarStatusIcon(isRunningJob: store.hasRunningJobs, hasFailure: store.hasFailures,
                    successUntil: store.successExpiresAt, animates: false)
            }
            .help("Comet: \(store.menuBarState.rawValue)")
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView(store: store) }
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)
    }
}

@MainActor @Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: RunnerStore
    private(set) var showMainWindowOnLaunch: Bool
    private let defaults: UserDefaults
    private var quitting = false
    private var heartbeat: Task<Void, Never>?
    var menuBarInserted = true {
        didSet {
            guard menuBarInserted != oldValue else { return }
            AppLog.record("menu bar inserted=\(menuBarInserted)", error: !menuBarInserted)
        }
    }

    override convenience init() { self.init(store: RunnerStore()) }

    init(store: RunnerStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        showMainWindowOnLaunch = !defaults.bool(forKey: "hasShownMainWindow")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.record("did finish launching; menu bar inserted=\(menuBarInserted)")
        for name in [NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateDockPresence(_:)), name: name, object: nil)
        }
        if let window = NSApp.mainWindow {
            updateDockPresence(Notification(name: NSWindow.didBecomeMainNotification, object: window))
        }
        store.loginItem.offerIfNeeded()
        Task { await store.load(); await store.mcp.restore(); store.updates.start() }
        if AppLog.isStarted {
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self else { return }
                    self.logStatus("heartbeat")
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLog.record("reopen visibleWindows=\(flag); restoring menu bar icon")
        menuBarInserted = true
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) { logStatus("became active") }
    func applicationDidResignActive(_ notification: Notification) { logStatus("resigned active") }
    func applicationWillTerminate(_ notification: Notification) {
        heartbeat?.cancel()
        logStatus("will terminate (orderly exit)")
    }

    private func logStatus(_ event: String) {
        AppLog.record("\(event); menu bar inserted=\(menuBarInserted) policy=\(NSApp.activationPolicy().rawValue) visibleWindows=\(NSApp.windows.filter(\.isVisible).count) operations=\(store.operations.count)")
    }

    @objc func updateDockPresence(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isAppWindow(window) else { return }
        if notification.name == NSWindow.didBecomeMainNotification {
            showMainWindowOnLaunch = false
            defaults.set(true, forKey: "hasShownMainWindow")
        }
        let hasOpenWindow = notification.name == NSWindow.didBecomeMainNotification
            || NSApp.windows.contains {
                $0 !== window && isAppWindow($0) && ($0.isVisible || $0.isMiniaturized)
            }
        let policy: NSApplication.ActivationPolicy = hasOpenWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let changed = NSApp.setActivationPolicy(policy)
        AppLog.record("activation policy=\(policy.rawValue) succeeded=\(changed) window event=\(notification.name.rawValue)", error: !changed)
    }

    private func isAppWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel), window.canBecomeMain else { return false }
        // Sparkle swaps temporary windows; Dock policy changes between them disrupt other windows.
        guard let controller = window.windowController else { return true }
        return Bundle(for: type(of: controller)) != Bundle(for: SPUUpdater.self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppLog.record("last window closed; keeping app running")
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logStatus("quit requested")
        AppLog.record("quit caller: \(Thread.callStackSymbols.prefix(16).joined(separator: " | "))")
        guard !quitting else { return .terminateLater }
        guard store.canQuit else {
            AppLog.record("quit refused: runner operation in progress")
            let alert = NSAlert()
            alert.messageText = "Comet is still working"
            alert.informativeText = "Wait for setup or the current runner operation to finish before quitting."
            alert.runModal()
            return .terminateCancel
        }
        if store.mightInterruptJob {
            let alert = NSAlert()
            alert.messageText = "Stop runners and quit?"
            alert.informativeText = "Quitting stops all managed runners and may interrupt active jobs."
            alert.addButton(withTitle: "Stop Runners and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                AppLog.record("quit cancelled by user")
                return .terminateCancel
            }
        }
        quitting = true
        Task {
            let stopped = await store.shutdown()
            AppLog.record("quit shutdown completed stopped=\(stopped)", error: !stopped)
            if !stopped { quitting = false }
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
}

extension RunnerState {
    var color: Color {
        switch self {
        case .ready: .green
        case .busy, .starting: runnerAccent
        case .attention: .red
        case .reconnecting, .sleeping: .orange
        case .stopped, .stopping: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .busy: "circle.inset.filled"
        case .attention: "exclamationmark.circle.fill"
        case .reconnecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .sleeping: "moon.zzz"
        default: "circle"
        }
    }
}

struct MenuBarStatusIcon: View {
    let isRunningJob: Bool
    var hasFailure = false
    var successUntil: Date? = nil
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var angle = 0.0
    @State private var successExpired = false
    private static let comet = Bundle.module.image(forResource: "CometTemplate")!
    private static let streaks = Bundle.module.image(forResource: "CometStreaksTemplate")!
    private struct ImageKey: Hashable {
        let isRunningJob: Bool
        let hasFailure: Bool
        let hasSuccess: Bool
        let dark: Bool
    }
    private static var stillImages: [ImageKey: NSImage] = [:]

    var body: some View {
        #if DEBUG
        let isRunningJob = self.isRunningJob || Entry.simulatesRunningJob()
        #endif
        let hasSuccess = !successExpired && (successUntil ?? .distantPast) > Date()
        Group {
            if animates && isRunningJob && !reduceMotion {
                Image(nsImage: Self.image(isRunningJob: true, angle: angle,
                    hasFailure: hasFailure, hasSuccess: hasSuccess, dark: colorScheme == .dark))
                    .renderingMode(hasFailure || hasSuccess ? .original : .template)
                    .onReceive(Timer.publish(every: 1 / 30, on: .main, in: .common).autoconnect()) { date in
                        angle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
                    }
            } else {
                Image(nsImage: Self.image(isRunningJob: isRunningJob,
                    hasFailure: hasFailure, hasSuccess: hasSuccess, dark: colorScheme == .dark))
                    .renderingMode(hasFailure || hasSuccess ? .original : .template)
            }
        }
        .accessibilityHidden(true)
        .task(id: successUntil) {
            successExpired = false
            guard let successUntil, successUntil > Date() else { return }
            do {
                try await Task.sleep(for: .seconds(successUntil.timeIntervalSinceNow))
                successExpired = true
            } catch { }
        }
    }

    // Reuse status images: replacing them during appearance snapshots can feed back into MenuBarExtra.
    static func image(isRunningJob: Bool, angle: Double? = nil, hasFailure: Bool = false,
                      hasSuccess: Bool = false, dark: Bool = false) -> NSImage {
        let hasBadge = hasFailure || hasSuccess
        guard isRunningJob || hasBadge else { return comet }
        let key = ImageKey(isRunningJob: isRunningJob, hasFailure: hasFailure, hasSuccess: hasSuccess, dark: dark)
        if angle == nil, let image = stillImages[key] { return image }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let bounds = NSRect(x: 0, y: 0, width: 18, height: 18)
            (isRunningJob ? streaks : comet).draw(in: bounds)
            if isRunningJob {
                let context = NSGraphicsContext.current!.cgContext
                // Head geometry from Group.svg, with the inset used by generate-icons.swift.
                let center = CGPoint(x: 12.26, y: 12.30)
                context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(1.65)
                context.setLineCap(.round)
                if let angle {
                    context.addArc(center: center, radius: 2.45,
                        startAngle: (90 - angle) * .pi / 180, endAngle: (190 - angle) * .pi / 180, clockwise: false)
                } else {
                    context.addEllipse(in: NSRect(x: center.x - 2.45, y: center.y - 2.45, width: 4.9, height: 4.9))
                }
                context.strokePath()
            }
            if hasBadge {
                // A coloured badge needs a non-template image, including the appearance-correct glyph.
                (dark ? NSColor.white : .black).setFill()
                bounds.fill(using: .sourceIn)
                (hasFailure ? NSColor.systemRed : .systemGreen).setFill()
                NSBezierPath(ovalIn: NSRect(x: 13, y: 0.5, width: 4.5, height: 4.5)).fill()
            }
            return true
        }
        image.isTemplate = !hasBadge
        if angle == nil { stillImages[key] = image }
        return image
    }
}

let runnerAccent = Color(nsColor: NSColor(name: "RunnerAccent") { appearance in
    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
        NSColor(srgbRed: 166 / 255, green: 168 / 255, blue: 1, alpha: 1)
    } else {
        NSColor(srgbRed: 82 / 255, green: 86 / 255, blue: 201 / 255, alpha: 1)
    }
})

#if DEBUG
struct DevelopmentBadge: View {
    var body: some View {
        Text("Dev")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(runnerAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(runnerAccent.opacity(0.12), in: Capsule())
            .accessibilityLabel("Development build")
    }
}
#endif

struct StateLabel: View {
    let state: RunnerState
    var body: some View {
        Label(state.rawValue, systemImage: state.symbol)
            .font(.caption).foregroundStyle(state.color)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct RunnerControl: View {
    let store: RunnerStore
    let runner: Runner
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmStop = false
    var body: some View {
        Group {
            if compact {
                control.buttonStyle(.borderless)
            } else if #available(macOS 26, *) {
                control.buttonStyle(.glass)
            } else {
                control.buttonStyle(.bordered)
            }
        }.controlSize(.small)
    }
    private var control: some View {
        let running = store.isEnabled(runner)
        return Button {
            if running { confirmStop = true }
            else { Task { await store.start(runner) } }
        } label: {
            if compact {
                Image(systemName: running ? "stop.fill" : "play.fill").frame(width: 28, height: 28)
                    .overlay {
                        if running && store.state(runner) == .busy {
                            Image(systemName: "circle.dotted")
                                .font(.system(size: 24))
                                .symbolEffect(.rotate, isActive: !reduceMotion)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            } else {
                Label(running ? "Stop Runner" : needsVMSetup ? "Set Up VM…" : "Start Runner", systemImage: running ? "stop.fill" : "play.fill")
            }
        }
        .disabled(store.operations.contains(runner.id) || (needsVMSetup && !store.virtualMachines.hasInstaller(paths: store.paths)))
        .help(needsVMSetup && !store.virtualMachines.hasInstaller(paths: store.paths)
              ? "Download macOS in Configuration before setting up this VM" : running ? "Stop \(runner.name)" : "Start \(runner.name)")
        .accessibilityLabel(running ? "Stop \(runner.name)" : "Start \(runner.name)")
        .alert("Stop \(runner.name)?", isPresented: $confirmStop) {
            Button("Cancel", role: .cancel) {}
            Button("Stop Runner", role: .destructive) { Task { await store.stop(runner) } }
        } message: {
            Text("Stopping this runner may interrupt an active build. GitHub status can be delayed.")
        }
    }
    private var needsVMSetup: Bool {
        runner.execution == .macOSVM && !FileManager.default.fileExists(atPath:
            store.paths.directory(runner.id).appendingPathComponent("vm/installed").path)
    }
}

struct RunnerPopover: View {
    let store: RunnerStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var hoveredRunner: UUID?
    @FocusState private var focusedRunner: UUID?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label { Text("Comet") } icon: {
                    MenuBarStatusIcon(isRunningJob: store.hasRunningJobs, hasFailure: store.hasFailures,
                        successUntil: store.successExpiresAt)
                }.font(.headline)
                #if DEBUG
                DevelopmentBadge()
                #endif
                Spacer()
                Button { showWindow(); store.showSetup = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Runner").help("Add Runner")
            }.padding(14)
            Divider()
            if store.runners.isEmpty {
                VStack(spacing: 12) {
                    Button("Add Runner…") { showWindow(); store.showSetup = true }
                }.padding(28)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.runners) { runner in
                            HStack(spacing: 11) {
                                RunnerControl(store: store, runner: runner, compact: true)
                                    .frame(width: 32, height: 32)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                Button {
                                    store.selectedID = runner.id
                                    showWindow()
                                } label: {
                                    HStack(spacing: 11) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(runner.repository.components(separatedBy: "/").last ?? runner.name)
                                                .fontWeight(.medium).lineLimit(1)
                                            Text(store.state(runner).context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        StateLabel(state: store.state(runner))
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .focused($focusedRunner, equals: runner.id)
                                    .accessibilityLabel("Open \(runner.name)")
                                    .accessibilityValue("\(runner.repository), \(store.state(runner).rawValue), \(store.state(runner).context)")
                                    .accessibilityAddTraits(store.selectedID == runner.id ? .isSelected : [])
                            }.padding(12)
                                .background(Color.primary
                                    .opacity(store.selectedID == runner.id ? 0.06 : hoveredRunner == runner.id ? 0.04 : 0),
                                    in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    if focusedRunner == runner.id {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .onHover { hoveredRunner = $0 ? runner.id : nil }
                        }
                    }.padding(6)
                }.frame(maxHeight: 340)
            }
            Divider()
            HStack {
                Button("Open Window") { showWindow() }.buttonStyle(.borderless)
                Spacer()
                Menu {
                    Button("Settings…") { dismiss(); openSettings(); NSApplication.shared.activate(ignoringOtherApps: true) }
                    CheckForUpdatesButton(updater: store.updates)
                    Button("Manage GitHub Token…") { NSWorkspace.shared.open(URL(string: "https://github.com/settings/personal-access-tokens")!) }
                    Divider()
                    Button("Quit Comet") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
                    .fixedSize().accessibilityLabel("More actions")
            }.font(.caption).padding(14)
        }.frame(width: 380)
        // MenuBarExtra can propose zero height, which otherwise collapses the scroll view.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(runnerAccent)
    }
    private func showWindow() {
        dismiss()
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
