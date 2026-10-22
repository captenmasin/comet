import AppKit
import SwiftUI
import RunnerCore

struct SetupView: View {
    @Bindable var store: RunnerStore
    @Environment(\.dismiss) private var dismiss
    @State private var trusted = false
    @State private var execution: RunnerExecution = .host
    @State private var runAutomatically = false
    @State private var repositories: [Repository] = []
    @State private var repository = ""
    @State private var name = "Mac-\(UUID().uuidString.prefix(6).lowercased())"
    @State private var loading = false
    @State private var installing = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Runner").font(.title2.weight(.semibold))
                Spacer()
                if store.signedIn { Text(store.account).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !store.signedIn {
                        SettingsSection { TokenForm(store: store, enabled: !installing) }
                    }
                    if store.signedIn {
                        SettingsSection {
                            LabeledContent("Repository") {
                                HStack(spacing: 8) {
                                    Picker("Repository", selection: $repository) {
                                        Text("Choose a repository…").tag("")
                                        ForEach(repositories) { Text($0.full_name).tag($0.full_name) }
                                    }.labelsHidden().lineLimit(1).disabled(loading || repositories.isEmpty)
                                    if loading { ProgressView().controlSize(.small) }
                                    Button { Task { await loadRepositories() } } label: { Image(systemName: "arrow.clockwise") }
                                        .buttonStyle(.borderless).accessibilityLabel("Refresh repositories").help("Refresh repositories")
                                        .disabled(loading || installing)
                                }
                            }
                            Text("Only workflows in this repository can use this runner.")
                                .font(.caption).foregroundStyle(.secondary)
                            if repositories.isEmpty && !loading {
                                Text("No repositories with admin access found. Check the token’s resource owner and repository access, then refresh. Organization tokens may need approval.")
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Divider()
                            LabeledContent("Runner name") {
                                TextField("Mac-runner", text: $name).textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.leading).accessibilityLabel("Runner name")
                            }
                            Divider()
                            LabeledContent("Execution") {
                                Picker("Execution", selection: $execution) {
                                    ForEach(RunnerExecution.allCases, id: \.self) { mode in
                                        Text(mode.title).tag(mode).disabled(mode == .macOSVM && !MacVirtualMachines.available)
                                    }
                                }.labelsHidden().fixedSize()
                            }
                            Text(execution.explanation).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                            Toggle("Run automatically", isOn: $runAutomatically).toggleStyle(.checkbox)
                            Text("Start this runner when Comet opens.").font(.caption).foregroundStyle(.secondary)
                            if execution == .macOSVM {
                                Divider()
                                VMInstallerView(store: store)
                            } else if !MacVirtualMachines.available {
                                Text(MacVirtualMachines.requirement).font(.caption).foregroundStyle(.secondary)
                            }
                        }.labeledContentStyle(SettingsFieldStyle()).disabled(installing)
                        Toggle("I trust the workflows in this repository", isOn: $trusted)
                            .toggleStyle(.checkbox).disabled(installing)
                    }
                    if let error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if installing {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.selectedID.flatMap { store.issues[$0] } ?? "Preparing runner…")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            ProgressView(value: store.selectedID.flatMap { store.virtualMachines.installationProgress[$0] })
                                .progressViewStyle(.linear)
                                .accessibilityLabel("Runner progress")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(installing)
                Spacer()
                Button("Add and Start Runner") {
                    installing = true
                    Task {
                        let added = await store.add(repository: repository, name: name, execution: execution, runAutomatically: runAutomatically)
                        installing = false
                        if added { dismiss() }
                        else { error = store.error; store.error = nil }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!trusted || !store.signedIn || repository.isEmpty || !Runner.validName(name) || installing || loading
                          || (execution == .macOSVM && !store.virtualMachines.hasInstaller(paths: store.paths)))
            }.padding(16)
        }.frame(width: 560, height: 460).tint(runnerAccent)
            .interactiveDismissDisabled(installing)
            .task(id: store.signedIn) { if store.signedIn { await loadRepositories() } }
    }
    private func loadRepositories() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            repositories = try await store.github.repositories()
            if !repositories.contains(where: { $0.full_name == repository }) { repository = "" }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct SettingsSection<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TokenForm: View {
    @Bindable var store: RunnerStore
    var enabled = true
    var onConnected: () -> Void = {}
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var connection: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.signedIn ? "Replace GitHub token" : "Connect GitHub").font(.headline)
            Text("Use a fine-grained token with Administration set to Read and write, and Actions set to Read-only.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("Create a token on GitHub ↗", destination: URL(string: "https://github.com/settings/personal-access-tokens/new?name=Comet&description=Manage%20self-hosted%20runners%20on%20this%20Mac&expires_in=30&administration=write&actions=read")!)
                .font(.callout)
            SecureField(store.signedIn ? "Paste a replacement token" : "Paste your personal access token", text: $token)
                .textFieldStyle(.roundedBorder).disabled(connecting || !enabled)
                .accessibilityLabel("GitHub personal access token")
            Text("Saved in macOS Keychain. Select the repositories Comet should manage under one resource owner.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(store.signedIn ? "Replace Token" : "Connect GitHub") { connect() }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connecting || !enabled)
                if connecting { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
        }.onDisappear { connection?.cancel(); token = "" }
    }
    private func connect() {
        let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
        error = nil
        connecting = true
        connection = Task {
            defer { connecting = false; connection = nil }
            do {
                let account = try await store.github.connect(token: candidate)
                store.account = account
                store.signedIn = true
                token = ""
                await store.refresh()
                onConnected()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct TokenReplacementView: View {
    let store: RunnerStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                SettingsSection { TokenForm(store: store, onConnected: { dismiss() }) }.padding(20)
            }.scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }.frame(width: 520, height: 330).tint(runnerAccent)
    }
}

struct SettingsView: View {
    @Bindable var store: RunnerStore
    @State private var replacingToken = false
    @State private var error: String?
    var body: some View {
        @Bindable var updates = store.updates
        let mcp = store.mcp
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection {
                    if store.signedIn {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("GitHub").font(.headline)
                                Text(store.account).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 16)
                            Button("Replace Token…") { replacingToken = true }.controlSize(.small)
                        }
                    } else {
                        TokenForm(store: store)
                    }
                }
                SettingsSection {
                    Text("Startup").font(.headline)
                    Toggle("Launch at Login", isOn: Binding(get: { store.loginItem.isEnabled }, set: { enabled in
                        do { try store.loginItem.setEnabled(enabled) }
                        catch { self.error = error.localizedDescription }
                    })).toggleStyle(.checkbox)
                    if store.loginItem.status == .requiresApproval {
                        Button("Approve in System Settings…") { store.loginItem.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
                SettingsSection {
                    HStack {
                        Text("Updates").font(.headline)
                        Spacer()
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                    Toggle("Automatically download updates", isOn: $updates.automaticallyDownloadsUpdates)
                        .disabled(!updates.automaticallyChecksForUpdates)
                    Text(updates.waitingForRunners ? "Update ready. Stop all runners to install it." : "Downloaded updates install when Comet quits.")
                        .font(.caption).foregroundStyle(.secondary)
                }.toggleStyle(.checkbox)
                SettingsSection {
                    Text("AI diagnostics (MCP)").font(.headline)
                    Toggle("Enable read-only MCP server", isOn: Binding(get: { mcp.isEnabled }, set: { enabled in
                        Task { await mcp.setEnabled(enabled) }
                    })).toggleStyle(.checkbox).disabled(mcp.isChanging)
                    Text("Connected agents can read runner configuration, status, activity and logs while Comet is open.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let endpoint = mcp.endpoint {
                        HStack {
                            Text(endpoint).font(.caption.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button("Copy Connection Config") {
                                guard let configuration = mcp.connectionConfiguration else { return }
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(configuration, forType: .string)
                            }.controlSize(.small)
                                .help("Includes your MCP access token. Keep the copied configuration private.")
                        }
                    }
                    if let error = mcp.error {
                        Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        if mcp.isEnabled {
                            Button("Retry MCP Server") { Task { await mcp.setEnabled(true) } }.controlSize(.small)
                        }
                    }
                }
                SettingsSection {
                    HStack {
                        Text("Runner data").font(.headline)
                        Spacer()
                        Button("Show in Finder") {
                            guard FileManager.default.fileExists(atPath: store.paths.root.path) else {
                                error = "Runner data hasn’t been created yet. Add a runner first."
                                return
                            }
                            NSWorkspace.shared.activateFileViewerSelecting([store.paths.root])
                        }.controlSize(.small)
                    }
                    Text("Closing windows keeps runners active. Quit stops managed runners; force-quit can leave them running.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(20)
        }.scrollBounceBehavior(.basedOnSize)
            .frame(width: 520, height: store.signedIn ? 350 : 570)
            .tint(runnerAccent)
            .onAppear { store.loginItem.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.loginItem.refresh()
            }
            .sheet(isPresented: $replacingToken) { TokenReplacementView(store: store) }
            .alert("Comet needs your attention", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}
