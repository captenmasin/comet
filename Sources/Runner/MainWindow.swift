import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RunnerCore

struct MainWindow: View {
    @Bindable var store: RunnerStore
    @State private var section = "Activity"
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Runners").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.showSetup = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Add Runner").accessibilityLabel("Add Runner")
                }.padding(16)
                List(selection: $store.selectedID) {
                    ForEach(store.runners) { runner in
                        HStack(spacing: 11) {
                            RunnerControl(store: store, runner: runner, compact: true)
                                .frame(width: 32, height: 32)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(runner.repository.components(separatedBy: "/").last ?? runner.name)
                                    .fontWeight(.medium).lineLimit(1)
                                Text(store.state(runner).rawValue).font(.caption)
                            }
                        }.padding(.vertical, 2).tag(runner.id)
                    }
                }.listStyle(.sidebar)
                Divider()
                HStack {
                    Image(systemName: "person.crop.circle")
                    Text(store.account).lineLimit(1)
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                }.font(.caption).foregroundStyle(.secondary).padding(16)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 280)
        } detail: {
            if let runner = store.selected {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(runner.repository.components(separatedBy: "/").last ?? runner.name).font(.title2.weight(.semibold))
                                Text("\(runner.repository) · \(runner.name)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            StateLabel(state: store.state(runner))
                            RunnerControl(store: store, runner: runner)
                        }
                        if let issue = store.issues[runner.id] {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(issue).font(.callout).textSelection(.enabled)
                                if store.operations.contains(runner.id) {
                                    ProgressView(value: store.virtualMachines.installationProgress[runner.id])
                                        .progressViewStyle(.linear)
                                        .accessibilityLabel("Runner progress")
                                }
                                else if store.isEnabled(runner) {
                                    Button("Retry Connection") { Task { await store.retryConnection(runner) } }
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                        Picker("Detail section", selection: $section) {
                            ForEach(["Activity", "Logs", "Configuration"], id: \.self) { Text($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340, alignment: .leading)
                    }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
                    Divider()
                    Group {
                        switch section {
                        case "Logs": LogsView(store: store, runner: runner).padding(24)
                        case "Configuration": ConfigurationView(store: store, runner: runner)
                        default: ActivityView(store: store, runner: runner)
                        }
                    }
                    .id("\(runner.id)/\(section)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                ContentUnavailableView {
                    Label("No runners", systemImage: "terminal")
                } actions: {
                    Button("Add Runner…") { store.showSetup = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 570).tint(runnerAccent)
        .sheet(isPresented: $store.showSetup) { SetupView(store: store) }
        .alert("Comet needs your attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task(id: store.selectedID) { _ = await store.refreshActivity() }
    }
}

struct ActivityView: View {
    let store: RunnerStore
    let runner: Runner
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let isLive = store.activityIssue[runner.id] == nil
                if let issue = store.activityIssue[runner.id] {
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                }
                if let current = store.activity[runner.id]?.first(where: { $0.job.status == "in_progress" }), store.state(runner) == .busy {
                    Text(isLive ? "Running now" : "Last known progress").font(.caption).foregroundStyle(.secondary)
                    JobRow(activity: current, isLive: isLive)
                    if let steps = current.job.steps, !steps.isEmpty {
                        StepProgressView(steps: steps, isLive: isLive)
                    }
                } else {
                    Label(store.state(runner).context, systemImage: store.state(runner).symbol)
                        .foregroundStyle(.secondary).padding(.vertical, 12)
                }
                Divider()
                HStack {
                    Text("Recent jobs").font(.headline)
                    Spacer()
                    Button { Task { await store.refreshActivity() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh recent jobs").accessibilityLabel("Refresh recent jobs")
                        .disabled(store.refreshingActivity)
                    if store.refreshingActivity { ProgressView().controlSize(.small).accessibilityLabel("Refreshing recent jobs") }
                }
                let recent = (store.activity[runner.id] ?? []).filter { $0.job.status == "completed" }
                if recent.isEmpty {
                    Text("No jobs for this runner in the repository’s 10 most recent workflow runs.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(recent, id: \.job.id) { item in
                    JobRow(activity: item)
                    Divider()
                }
                Link("View repository actions on GitHub ↗", destination: URL(string: "https://github.com/\(runner.repository)/actions")!)
                    .font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 20)
        }.scrollBounceBehavior(.basedOnSize)
    }


}

struct JobRow: View {
    let activity: RunnerActivity
    var isLive = true

    static func startedTime(_ started: Date, at now: Date) -> String {
        started.formatted(date: now.timeIntervalSince(started) > 24 * 60 * 60 ? .abbreviated : .omitted,
                          time: .shortened)
    }

    var body: some View {
        let outcome = ActivityStatus(status: activity.job.status, conclusion: activity.job.conclusion)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: outcome.symbol).foregroundStyle(outcome.color).frame(width: 18).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.job.name).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                Text("\(activity.run.name ?? "Workflow") · \(activity.run.head_branch ?? "—") · \(activity.run.head_sha.prefix(7))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(outcome.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Duration").foregroundStyle(.secondary)
                    ActivityDuration(status: activity.job.status, conclusion: activity.job.conclusion,
                                     startedAt: activity.job.started_at, completedAt: activity.job.completed_at, isLive: isLive)
                }.font(.caption)
                if let started = ActivityDuration.date(activity.job.started_at) {
                    TimelineView(.periodic(from: started, by: 60)) { context in
                        Text("Started at \(Self.startedTime(started, at: context.date))")
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                Link("View on GitHub ↗", destination: activity.job.html_url).font(.caption)
            }
        }.padding(.vertical, 4).fixedSize(horizontal: false, vertical: true)
    }
}

struct LogsView: View {
    let store: RunnerStore
    let runner: Runner
    @State private var filter = ""
    @State private var follow = true
    private var output: String {
        let text = store.logs[runner.id] ?? "No local output yet."
        return filter.isEmpty ? text : text.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Filter local logs", text: $filter).textFieldStyle(.roundedBorder)
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string) }
                Button("Export…") { export() }
            }
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading) {
                        Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Color.clear.frame(height: 1).id("end")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: output) { if follow { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: follow) { if follow { proxy.scrollTo("end", anchor: .bottom) } }
            }
            Text("Local runner diagnostics · latest 512 KB. Complete job output is on GitHub.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Open complete job logs on GitHub ↗", destination: URL(string: "https://github.com/\(runner.repository)/actions")!)
                .font(.caption)
        }.task {
            while !Task.isCancelled {
                store.logs[runner.id] = await RunnerProcess.readLog(store.paths.directory(runner.id))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(runner.name)-runner.log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try output.write(to: url, atomically: true, encoding: .utf8) }
        catch { store.error = error.localizedDescription }
    }
}

struct ConfigurationView: View {
    let store: RunnerStore
    let runner: Runner
    @State private var confirmRemove = false
    @State private var showSnippet = false
    @State private var pendingExecution: RunnerExecution?
    private var form: some View {
        ScrollView {
            SettingsSection {
                LabeledContent("Repository", value: runner.repository)
                Divider()
                LabeledContent("Runner name", value: runner.name)
                Divider()
                Toggle("Run automatically", isOn: Binding(get: { runner.runAutomatically }, set: { store.setRunAutomatically($0, for: runner) }))
                    .toggleStyle(.checkbox).disabled(store.operations.contains(runner.id))
                Text("Start this runner when Comet opens.").font(.caption).foregroundStyle(.secondary)
                Divider()
                LabeledContent("Execution") {
                    Picker("Execution", selection: Binding(get: { runner.execution }, set: { pendingExecution = $0 })) {
                        ForEach(RunnerExecution.allCases, id: \.self) { execution in
                            Text(execution.title).tag(execution)
                                .disabled(execution == .macOSVM && !MacVirtualMachines.available)
                        }
                    }
                    .labelsHidden().fixedSize()
                }.disabled(store.isEnabled(runner) || store.operations.contains(runner.id))
                if !MacVirtualMachines.available {
                    Text(MacVirtualMachines.requirement).font(.caption).foregroundStyle(.secondary)
                }
                if runner.execution == .macOSVM {
                    Divider()
                    VMInstallerView(store: store)
                    Button("Copy VM Password") {
                        do {
                            guard let password = try Keychain.load(service: "dev.runnerbar.vm", account: runner.id.uuidString) else {
                                throw RunnerError.message("Start the VM first to create its account.")
                            }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(password, forType: .string)
                        } catch { store.error = error.localizedDescription }
                    }.controlSize(.small)
                }
                Divider()
                LabeledContent("Labels", value: "self-hosted, macOS, \(runner.execution == .macOSVM || RunnerProcess.architecture == "arm64" ? "ARM64" : "X64"), \(runner.label)")
                Divider()
                LabeledContent("Workspace") {
                    if runner.execution == .dedicatedUser {
                        Text(DedicatedUser(id: runner.id).directory).font(.caption).textSelection(.enabled)
                    } else if runner.execution == .macOSVM && !FileManager.default.fileExists(atPath: store.paths.directory(runner.id).path) {
                        Text("Created during VM setup").foregroundStyle(.secondary)
                    } else {
                        Button("Show in Finder") { store.showWorkspace(for: runner) }
                    }
                }
                if runner.execution == .dedicatedUser {
                    Divider()
                    LabeledContent("Homebrew", value: DedicatedUser.homebrew)
                    Button("Set Up Dedicated User…") { Task { await store.prepareDedicatedAccount(for: runner) } }
                        .disabled(store.operations.contains(runner.id))
                }
                Text(runner.execution.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button("Workflow Snippet…") { showSnippet = true }
                    Spacer()
                    Button("Remove Runner…", role: .destructive) { confirmRemove = true }
                        .disabled(store.isEnabled(runner) || store.operations.contains(runner.id))
                }.controlSize(.small)
                Text("Stop the runner before removing it. Local files are kept for recovery.").font(.caption).foregroundStyle(.secondary)
            }.labeledContentStyle(SettingsFieldStyle())
                .padding(24)
        }.scrollBounceBehavior(.basedOnSize)
    }
    var body: some View {
        form
        .alert("Change execution?", isPresented: Binding(get: { pendingExecution != nil }, set: { if !$0 { pendingExecution = nil } })) {
            Button("Cancel", role: .cancel) { pendingExecution = nil }
            Button("Change Execution") {
                if let execution = pendingExecution { Task { await store.setExecution(execution, for: runner) } }
                pendingExecution = nil
            }
        } message: {
            Text("This replaces the stopped GitHub runner registration. Its workflow label stays the same. The existing workspace and VM are kept for recovery; the new execution environment starts fresh.")
        }
        .alert("Remove \(runner.name)?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Runner", role: .destructive) { Task { await store.remove(runner) } }
        } message: { Text("This deregisters the runner on GitHub. Its local workspace will be kept. If deregistration fails, the runner stays in this app.") }
        .sheet(isPresented: $showSnippet) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Target this runner").font(.headline)
                Text(runner.workflow).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(runner.workflow, forType: .string) }
                    Spacer()
                    Button("Done") { showSnippet = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 480)
        }
    }

}

struct SettingsFieldStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline) {
            configuration.label.fixedSize()
            Spacer(minLength: 24)
            configuration.content.multilineTextAlignment(.trailing)
        }
    }
}
