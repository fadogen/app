import SwiftUI
import SwiftData
import AppKit

struct DevelopmentConfigurationView: View {
    @Bindable var project: LocalProject
    var onOpenInFinder: () -> Void
    var onChangePath: () -> Void

    // Data passed from parent to avoid @Query (causes infinite loops in navigation destinations)
    let phpVersions: [PHPVersion]
    let nodeVersions: [NodeVersion]
    let bunVersions: [BunVersion]

    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @State private var selectedPHPVersion: String?
    @State private var selectedJSRuntime: JSRuntime
    @State private var showingURLEditSheet = false

    enum JSRuntime: Hashable {
        case `default`
        case node(String)  // Major version
        case bun

        var displayName: String {
            switch self {
            case .default:
                return "Default"
            case .node(let major):
                return "Node \(major)"
            case .bun:
                return "Bun"
            }
        }
    }

    init(
        project: LocalProject,
        onOpenInFinder: @escaping () -> Void,
        onChangePath: @escaping () -> Void,
        phpVersions: [PHPVersion],
        nodeVersions: [NodeVersion],
        bunVersions: [BunVersion]
    ) {
        self.project = project
        self.onOpenInFinder = onOpenInFinder
        self.onChangePath = onChangePath
        self.phpVersions = phpVersions
        self.nodeVersions = nodeVersions
        self.bunVersions = bunVersions
        _selectedPHPVersion = State(initialValue: project.phpVersion?.major)

        // Determine initial JS runtime from project configuration
        if let packageManager = project.jsPackageManager, packageManager == "bun" {
            _selectedJSRuntime = State(initialValue: .bun)
        } else if let nodeVersion = project.nodeVersion {
            _selectedJSRuntime = State(initialValue: .node(nodeVersion.major))
        } else {
            _selectedJSRuntime = State(initialValue: .default)
        }
    }

    var body: some View {
        Section("Information") {
            localURLRow

            LabeledContent("Path") {
                HStack(spacing: 8) {
                    if FileManager.default.fileExists(atPath: project.path) {
                        Text(project.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Not available locally")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        onChangePath()
                    } label: {
                        Text("Change")
                    }
                    .buttonStyle(.link)
                }
            }
        }

        Section("Configuration") {
            Picker("PHP Version", selection: $selectedPHPVersion) {
                Text("Default").tag(nil as String?)

                ForEach(phpVersions) { version in
                    Text("PHP \(version.major)").tag(version.major as String?)
                }
            }
            .onChange(of: selectedPHPVersion) { _, newValue in
                updatePHPVersion(newValue)
            }

            Picker("JavaScript Runtime", selection: $selectedJSRuntime) {
                Text(JSRuntime.default.displayName).tag(JSRuntime.default)

                ForEach(nodeVersions) { version in
                    Text(JSRuntime.node(version.major).displayName).tag(JSRuntime.node(version.major))
                }

                if !bunVersions.isEmpty {
                    Text(JSRuntime.bun.displayName).tag(JSRuntime.bun)
                }
            }
            .onChange(of: selectedJSRuntime) { _, newValue in
                updateJSRuntime(newValue)
            }
        }
    }

    // MARK: - Local URL Row

    private var localURLRow: some View {
        LabeledContent("Local URL") {
            HStack(spacing: 8) {
                Button(project.localURL) {
                    openInBrowser()
                }
                .buttonStyle(.link)

                Button("Edit") {
                    showingURLEditSheet = true
                }
                .buttonStyle(.link)
            }
        }
        .sheet(isPresented: $showingURLEditSheet) {
            LocalURLEditSheet(project: project) {
                services.caddyConfig.reconcile(project: project)
            }
        }
    }

    // MARK: - Private

    private func openInBrowser() {
        if let url = URL(string: project.localURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func updatePHPVersion(_ versionMajor: String?) {
        if let versionMajor {
            project.phpVersion = phpVersions.first { $0.major == versionMajor }
        } else {
            project.phpVersion = nil
        }

        try? modelContext.save()

        // Sync .fadogen file with new PHP version
        try? project.syncPHPVersion()

        services.caddyConfig.reconcile(project: project)
    }

    private func updateJSRuntime(_ runtime: JSRuntime) {
        switch runtime {
        case .default:
            project.nodeVersion = nil
            project.jsPackageManager = nil
        case .node(let major):
            project.nodeVersion = nodeVersions.first { $0.major == major }
            project.jsPackageManager = nil
        case .bun:
            project.nodeVersion = nil
            project.jsPackageManager = "bun"
        }

        try? modelContext.save()

        // Sync .fadogen file with new configuration
        try? project.syncFadogenConfig()

        services.caddyConfig.reconcile(project: project)
    }
}
