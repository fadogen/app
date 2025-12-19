import SwiftUI
import SwiftData

/// Node.js and Bun version management view
struct NodeBunView: View {
    @Environment(AppServices.self) private var services
    @Query private var installedNodeVersions: [NodeVersion]

    // Keep only UI-specific state (dialogs)
    @State private var showRemoveConfirmation: String?
    @State private var showSelectNewDefault = false
    @State private var showLastVersionWarning = false
    @State private var versionToRemove: String?
    @State private var availableDefaultVersions: [String] = []
    @State private var errorAlert: String?

    var body: some View {
        List {
            // Bun section
            Section {
                BunRow()
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            } header: {
                Text("JavaScript Runtime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            // Node.js versions section
            Section {
                ForEach(displayNodeVersions) { version in
                    NodeVersionRow(
                        version: version,
                        isDownloading: services.node.installingVersions.contains(version.major),
                        isUninstalling: services.node.removingVersions.contains(version.major),
                        isUpdating: services.node.updatingVersions.contains(version.major),
                        downloadProgress: services.node.operationProgress[version.major] ?? 0.0,
                        updateProgress: services.node.operationProgress[version.major] ?? 0.0,
                        uninstallProgress: services.node.operationProgress[version.major] ?? 0.0,
                        isAnyOperationActive: services.node.isAnyOperationActive,
                        onInstall: { startInstall(version.major) },
                        onUpdate: { startUpdate(version.major) },
                        onRemove: { startRemove(version.major) },
                        onSetDefault: { startSetDefault(version.major) }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            } header: {
                Text("Node.js Versions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Node.js & Bun")
        .toolbar {
            // Refresh button
            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        await services.node.refresh()
                        await services.bun.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .symbolEffect(.rotate, value: services.node.isLoading || services.bun.isLoading)
                .disabled(services.node.isLoading || services.bun.isLoading)
            }
        }
        .overlay {
            if (services.node.isLoading && services.node.availableVersions.isEmpty) ||
               (services.bun.isLoading && services.bun.availableVersion == nil) {
                ProgressView("Loading metadata...")
            }
        }
        .alert("Operation Error", isPresented: .constant(!services.node.operationErrors.isEmpty)) {
            Button("OK") {
                services.node.operationErrors.removeAll()
            }
        } message: {
            if let firstError = services.node.operationErrors.first {
                Text("Node.js \(firstError.key): \(firstError.value)")
            }
        }
        .confirmationDialog(
            "Remove Node.js \(showRemoveConfirmation ?? "")?",
            isPresented: .constant(showRemoveConfirmation != nil),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let version = showRemoveConfirmation {
                    performRemoval(version)
                }
                showRemoveConfirmation = nil
            }
            Button("Cancel", role: .cancel) {
                showRemoveConfirmation = nil
            }
        } message: {
            Text("This will delete Node.js \(showRemoveConfirmation ?? "") completely.")
        }
        .confirmationDialog(
            "Select New Default Version",
            isPresented: $showSelectNewDefault,
            titleVisibility: .visible
        ) {
            ForEach(availableDefaultVersions, id: \.self) { version in
                Button("Node.js \(version)") {
                    if let oldVersion = versionToRemove {
                        setNewDefaultAndRemove(oldVersion: oldVersion, newDefault: version)
                    }
                    showSelectNewDefault = false
                    versionToRemove = nil
                }
            }
            Button("Cancel", role: .cancel) {
                showSelectNewDefault = false
                versionToRemove = nil
            }
        } message: {
            Text("The current default version will be removed. Select a replacement:")
        }
        .alert("Cannot Remove Last Version", isPresented: $showLastVersionWarning) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("At least one Node.js version must remain installed. Node.js is required for Fadogen to function properly.")
        }
        .alert("Error", isPresented: .constant(errorAlert != nil)) {
            Button("OK") {
                errorAlert = nil
            }
        } message: {
            if let error = errorAlert {
                Text(error)
            }
        }
    }

    /// Combine metadata with installed versions to create display models
    /// Local-first approach: displays installed versions even when offline
    private var displayNodeVersions: [DisplayNodeVersion] {
        // Get all unique major versions (installed OR available)
        let installedMajors = Set(installedNodeVersions.map { $0.major })
        let availableMajors = Set(services.node.availableVersions.keys)
        let allMajors = installedMajors.union(availableMajors).sorted(by: >)

        // Map each major to DisplayNodeVersion
        return allMajors.map { major in
            let installed = installedNodeVersions.first { $0.major == major }
            let metadata = services.node.availableVersions[major]

            // Latest available: prefer metadata, fallback to installed minor, or empty string
            let latestAvailable = metadata?.latest ?? installed?.minor ?? ""

            // Has update: only if both installed AND metadata exist, and versions differ
            let hasUpdate = if let installed, let metadata {
                installed.minor != metadata.latest
            } else {
                false
            }

            return DisplayNodeVersion(
                major: major,
                minor: installed?.minor,
                latestAvailable: latestAvailable,
                isInstalled: installed != nil,
                isDefault: installed?.isDefault ?? false,
                hasUpdate: hasUpdate,
                isLts: metadata?.isLts ?? false,
                isEol: metadata?.isEol ?? false
            )
        }
    }

    private func startInstall(_ version: String) {
        Task {
            do {
                try await services.node.install(major: version)
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func startUpdate(_ version: String) {
        Task {
            do {
                try await services.node.update(major: version)
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func startSetDefault(_ version: String) {
        Task {
            do {
                try await services.node.setDefault(major: version)
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func startRemove(_ version: String) {
        // Check if it's the last version
        if installedNodeVersions.count == 1 {
            showLastVersionWarning = true
            return
        }

        // Check if it's the default version - show dialog to select new default
        if let versionToCheck = installedNodeVersions.first(where: { $0.major == version }),
           versionToCheck.isDefault {
            versionToRemove = version
            availableDefaultVersions = installedNodeVersions
                .filter { $0.major != version }
                .map { $0.major }
                .sorted(by: >)
            showSelectNewDefault = true
            return
        }

        // Show confirmation dialog for normal removal
        showRemoveConfirmation = version
    }

    private func performRemoval(_ version: String) {
        Task {
            do {
                try await services.node.remove(major: version)
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func setNewDefaultAndRemove(oldVersion: String, newDefault: String) {
        Task {
            do {
                try await services.node.setDefault(major: newDefault)
                try await services.node.remove(major: oldVersion)
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }
}

/// Individual row for each Node.js version
struct NodeVersionRow: View {
    let version: DisplayNodeVersion
    let isDownloading: Bool
    let isUninstalling: Bool
    let isUpdating: Bool
    let downloadProgress: Double
    let updateProgress: Double
    let uninstallProgress: Double
    let isAnyOperationActive: Bool
    let onInstall: () -> Void
    let onUpdate: () -> Void
    let onRemove: () -> Void
    let onSetDefault: () -> Void

    private var hasActiveOperation: Bool {
        isDownloading || isUninstalling || isUpdating
    }

    private var shouldDisableActions: Bool {
        isAnyOperationActive && !hasActiveOperation
    }

    var body: some View {
        HStack(spacing: 16) {
            // Version display
            HStack(spacing: 8) {
                // Default indicator
                Button {
                    if version.isInstalled && !version.isDefault {
                        onSetDefault()
                    }
                } label: {
                    Image(systemName: version.isDefault ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(version.isDefault ? .blue : .secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .disabled(!version.isInstalled || version.isDefault || shouldDisableActions)
                .opacity(version.isInstalled ? 1.0 : 0.0)
                .help(version.isDefault ? "Default version" : "Set as default")

                versionView

                if version.isEol {
                    StatusBadge(text: "EOL", color: .yellow)
                } else if version.isLts {
                    StatusBadge(text: "LTS", color: .green)
                }

                if version.isDefault {
                    StatusBadge(text: "Default")
                }
            }
            .animation(.smooth, value: version.isDefault)

            Spacer()

            // Action buttons
            HStack(alignment: .center, spacing: 8) {
                // Update button
                if version.hasUpdate && version.isInstalled && !isUninstalling {
                    if isUpdating {
                        OperationProgressView(progress: updateProgress)
                    } else {
                        Button(action: onUpdate) {
                            Image(systemName: "arrow.down.circle")
                                .font(.title2)
                                .foregroundColor(.orange)
                                .frame(height: 24)
                        }
                        .buttonStyle(.borderless)
                        .disabled(shouldDisableActions)
                        .opacity(shouldDisableActions ? 0.3 : 1.0)
                        .help("Update to latest version")
                    }
                }

                // Install/Uninstall button
                if version.isInstalled {
                    if isUninstalling {
                        OperationProgressView(progress: uninstallProgress, tint: .secondary)
                    }

                    Button(action: onRemove) {
                        Image(systemName: "trash")
                            .font(.title2)
                            .foregroundColor(.secondary)
                            .frame(height: 24)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isUninstalling || isUpdating || shouldDisableActions)
                    .opacity((isUninstalling || isUpdating || shouldDisableActions) ? 0.3 : 1.0)
                    .help("Uninstall this version")
                } else {
                    if isDownloading {
                        OperationProgressView(progress: downloadProgress)
                    }

                    Button(action: onInstall) {
                        Image(systemName: "arrow.down.circle")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                            .frame(height: 24)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDownloading || shouldDisableActions)
                    .opacity((isDownloading || shouldDisableActions) ? 0.3 : 1.0)
                    .help("Download and install")
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var versionView: some View {
        if version.hasUpdate, let minor = version.minor {
            HStack(spacing: 4) {
                Text(version.major)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text("(\(minor) → \(version.latestAvailable))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .opacity(0.7)
            }
        } else {
            Text(version.major)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(version.isInstalled ? .primary : .secondary)
        }
    }
}

/// Individual row for Bun
struct BunRow: View {
    @Environment(AppServices.self) private var services
    @Query private var installedBunVersion: [BunVersion]

    @State private var errorAlert: String?
    @State private var showRemoveConfirmation = false

    private var installedVersion: BunVersion? {
        installedBunVersion.first
    }

    private var hasUpdate: Bool {
        guard let installed = installedVersion,
              let available = services.bun.availableVersion else {
            return false
        }
        return available.latest != installed.version
    }

    var body: some View {
        HStack(spacing: 16) {
            // Bun info with version
            HStack(spacing: 8) {
                Text("Bun")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(installedVersion != nil ? .primary : .secondary)

                if let installed = installedVersion {
                    Text(installed.version)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Action buttons
            HStack(alignment: .center, spacing: 8) {
                // Update button (only if installed)
                if hasUpdate && installedVersion != nil {
                    if services.bun.isUpdating {
                        OperationProgressView(progress: services.bun.updateProgress)
                    } else {
                        Button {
                            Task {
                                do {
                                    try await services.bun.update()
                                } catch {
                                    await MainActor.run {
                                        errorAlert = error.localizedDescription
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.title2)
                                .foregroundColor(.orange)
                                .frame(height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help("Update to latest version")
                    }
                }

                // Install/Uninstall button
                if installedVersion != nil {
                    Button {
                        showRemoveConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.title2)
                            .foregroundColor(.secondary)
                            .frame(height: 24)
                    }
                    .buttonStyle(.borderless)
                    .disabled(services.bun.isUpdating)
                    .opacity(services.bun.isUpdating ? 0.3 : 1.0)
                    .help("Uninstall Bun")
                } else {
                    // Install button
                    if services.bun.isUpdating {
                        OperationProgressView(progress: services.bun.updateProgress)
                    }

                    Button {
                        Task {
                            do {
                                try await services.bun.install()
                            } catch {
                                await MainActor.run {
                                    errorAlert = error.localizedDescription
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                            .frame(height: 24)
                    }
                    .buttonStyle(.borderless)
                    .disabled(services.bun.isUpdating)
                    .opacity(services.bun.isUpdating ? 0.3 : 1.0)
                    .help("Download and install Bun")
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .confirmationDialog(
            "Remove Bun?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    do {
                        try await services.bun.remove()
                    } catch {
                        await MainActor.run {
                            errorAlert = error.localizedDescription
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete Bun completely. You can reinstall it at any time.")
        }
        .alert("Error", isPresented: .constant(errorAlert != nil)) {
            Button("OK") {
                errorAlert = nil
            }
        } message: {
            if let error = errorAlert {
                Text(error)
            }
        }
    }
}

// MARK: - Display Data Model

struct DisplayNodeVersion: Identifiable {
    let id = UUID()
    let major: String
    let minor: String?
    let latestAvailable: String
    let isInstalled: Bool
    let isDefault: Bool
    let hasUpdate: Bool
    let isLts: Bool
    let isEol: Bool
}
