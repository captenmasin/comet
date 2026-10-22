import AppKit
import SwiftUI

struct VMInstallerView: View {
    let store: RunnerStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.virtualMachines.hasInstaller(paths: store.paths) {
                HStack(spacing: 12) {
                    Label("macOS installer downloaded", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([MacVirtualMachines.installer(paths: store.paths)])
                    }.controlSize(.small)
                }
            } else if store.virtualMachines.isDownloading {
                HStack {
                    Text(store.virtualMachines.downloadMessage ?? "Downloading macOS…").font(.callout)
                    Spacer()
                    Button { store.virtualMachines.cancelDownload() } label: {
                        Label("Stop Download", systemImage: "stop.fill")
                    }
                    .disabled(store.virtualMachines.isStoppingDownload)
                    .help("Stop this download. Downloading again starts from the beginning.")
                }
                ProgressView(value: store.virtualMachines.downloadProgress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("macOS download")
                if let size = store.virtualMachines.downloadSize {
                    Text(size).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Button("Download macOS…") { Task { await store.virtualMachines.downloadInstaller(paths: store.paths) } }
                    .disabled(!MacVirtualMachines.available)
                Text(store.virtualMachines.downloadMessage ?? "About 27 GB from Apple. Download once and reuse for VM setup. Allow at least 80 GB free for the installer and guest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
