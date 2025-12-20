import SwiftUI
import SwiftData

/// PHP version management view
/// Minimalist design with icon-only actions
struct PHPView: View {
    @Environment(AppServices.self) private var services
    @Query private var installedVersions: [PHPVersion]

    // Keep only UI-specific state (dialogs)
    @State private var showRemoveConfirmation: String?
    @State private var showSelectNewDefault = false
    @State private var showLastVersionWarning = false
    @State private var showHelp = false
    @State private var versionToRemove: String?
    @State private var availableDefaultVersions: [String] = []
    @State private var errorAlert: String?
    @State private var selectedVersionForEdit: PHPVersion?

    var body: some View {
        List {
            // PHP versions section
            Section {
                ForEach(displayVersions) { version in
                    PHPVersionRow(
                        version: version,
                        isDownloading: services.php.installingVersions.contains(version.major),
                        isUninstalling: services.php.removingVersions.contains(version.major),
                        isUpdating: services.php.updatingVersions.contains(version.major),
                        downloadProgress: services.php.operationProgress[version.major] ?? 0.0,
                        updateProgress: services.php.operationProgress[version.major] ?? 0.0,
                        uninstallProgress: services.php.operationProgress[version.major] ?? 0.0,
                        isAnyOperationActive: services.php.isAnyOperationActive,
                        onInstall: { startInstall(version.major) },
                        onUpdate: { startUpdate(version.major) },
                        onRemove: { startRemove(version.major) },
                        onSetDefault: { startSetDefault(version.major) },
                        onConfigure: { startConfigure(version.major) }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            } header: {
                Text("PHP Versions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            // Composer section (below PHP)
            Section {
                ComposerRow()
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            } header: {
                Text("Dependency Manager")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        }
        .listStyle(.plain)
        .navigationTitle("PHP")
        .toolbar {
            // Refresh button (primary, frequent usage)
            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        await services.php.refresh()
                        await services.composer.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .symbolEffect(.rotate, value: services.php.isLoading || services.composer.isLoading)
                .disabled(services.php.isLoading || services.composer.isLoading)
            }

            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            }

            // Help button (secondary, rare usage)
            ToolbarItem(placement: .automatic) {
                Button {
                    showHelp = true
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
            }
        }
        .overlay {
            if (services.php.isLoading && services.php.availableVersions.isEmpty) ||
               (services.composer.isLoading && services.composer.availableVersion == nil) {
                ProgressView("Loading metadata...")
            }
        }
        .alert("Operation Error", isPresented: .constant(!services.php.operationErrors.isEmpty)) {
            Button("OK") {
                services.php.operationErrors.removeAll()
            }
        } message: {
            if let firstError = services.php.operationErrors.first {
                Text("PHP \(firstError.key): \(firstError.value)")
            }
        }
        .confirmationDialog(
            "Remove PHP \(showRemoveConfirmation ?? "")?",
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
            Text("This will delete PHP \(showRemoveConfirmation ?? "") and its configuration files.")
        }
        .confirmationDialog(
            "Select New Default Version",
            isPresented: $showSelectNewDefault,
            titleVisibility: .visible
        ) {
            ForEach(availableDefaultVersions, id: \.self) { version in
                Button("PHP \(version)") {
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
            Text("At least one PHP version must remain installed. Please install another version before removing this one.")
        }
        .sheet(isPresented: $showHelp) {
            PHPHelpSheetView()
        }
        .sheet(item: $selectedVersionForEdit) { phpVersion in
            NavigationStack {
                PHPConfigEditSheet(phpVersion: phpVersion)
            }
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
    private var displayVersions: [DisplayPHPVersion] {
        // Get all unique major versions (installed OR available)
        let installedMajors = Set(installedVersions.map { $0.major })
        let availableMajors = Set(services.php.availableVersions.keys)
        let allMajors = installedMajors.union(availableMajors).sorted(by: >)

        // Map each major to DisplayPHPVersion
        return allMajors.map { major in
            let installed = installedVersions.first { $0.major == major }
            let metadata = services.php.availableVersions[major]

            // Latest available: prefer metadata, fallback to installed minor, or empty string
            let latestAvailable = metadata?.latest ?? installed?.minor ?? ""

            // Has update: only if both installed AND metadata exist, and versions differ
            let hasUpdate = if let installed, let metadata {
                installed.minor != metadata.latest
            } else {
                false
            }

            return DisplayPHPVersion(
                major: major,
                minor: installed?.minor,
                latestAvailable: latestAvailable,
                isInstalled: installed != nil,
                isDefault: installed?.isDefault ?? false,
                hasUpdate: hasUpdate,
                isEol: metadata?.isEol ?? false
            )
        }
    }

    private func startInstall(_ version: String) {
        Task {
            do {
                try await services.php.install(major: version)
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
                try await services.php.update(major: version)
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
                try await services.php.setDefault(major: version)
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func startConfigure(_ version: String) {
        // Find the installed version and show configuration sheet
        if let phpVersion = installedVersions.first(where: { $0.major == version }) {
            selectedVersionForEdit = phpVersion
        }
    }

    private func startRemove(_ version: String) {
        // Check if it's the last version
        if installedVersions.count == 1 {
            showLastVersionWarning = true
            return
        }

        // Check if it's the default version - show dialog to select new default
        if let versionToCheck = installedVersions.first(where: { $0.major == version }),
           versionToCheck.isDefault {
            versionToRemove = version
            availableDefaultVersions = installedVersions
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
                try await services.php.remove(major: version)
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
                try await services.php.setDefault(major: newDefault)
                try await services.php.remove(major: oldVersion)
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }
}

/// Individual row for each PHP version
struct PHPVersionRow: View {
    let version: DisplayPHPVersion
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
    let onConfigure: () -> Void

    /// Returns true if this specific version has an active operation
    private var hasActiveOperation: Bool {
        isDownloading || isUninstalling || isUpdating
    }

    /// Returns true if actions should be disabled (another version is busy)
    private var shouldDisableActions: Bool {
        isAnyOperationActive && !hasActiveOperation
    }

    var body: some View {
        HStack(spacing: 16) {
            // Version display
            HStack(spacing: 8) {
                // Default indicator (checkmark circle) - always present for alignment
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
                }

                if version.isDefault {
                    StatusBadge(text: "Default")
                }
            }
            .animation(.smooth, value: version.isDefault)

            Spacer()

            // Action buttons with progress bar on left when active
            HStack(alignment: .center, spacing: 8) {
                // Configure button (only for installed versions)
                if version.isInstalled {
                    Button(action: onConfigure) {
                        Image(systemName: "gear")
                            .font(.title2)
                            .foregroundColor(.secondary)
                            .frame(height: 24)
                    }
                    .buttonStyle(.borderless)
                    .disabled(shouldDisableActions)
                    .opacity(shouldDisableActions ? 0.3 : 1.0)
                    .help("Configure PHP settings")
                }

                // Update button (disappears during updating OR uninstalling)
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
                        .help("Update this PHP version")
                    }
                }

                // Install/Uninstall button (stays in place, disabled when active)
                if version.isInstalled {
                    // Uninstall button with progress bar
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
                    .help("Uninstall this PHP version")
                } else {
                    // Install button with progress bar
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
                    .help("Download and install this PHP version")
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var versionView: some View {
        if version.hasUpdate, let minor = version.minor {
            // Update available: show major version + update details in smaller, grayed text
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
            // No update or not installed
            Text(version.major)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(version.isInstalled ? .primary : .secondary)
        }
    }
}

// MARK: - Display Data Model

struct DisplayPHPVersion: Identifiable {
    let id = UUID()
    let major: String
    let minor: String?
    let latestAvailable: String
    let isInstalled: Bool
    let isDefault: Bool
    let hasUpdate: Bool
    let isEol: Bool
}
