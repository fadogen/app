import SwiftUI
import SwiftData

/// Detail view for Typesense search server
/// Displays configuration and controls in a Liquid Glass toolbar
struct TypesenseDetailView: View {
    @Query private var installedTypesense: [TypesenseVersion]

    @Environment(AppServices.self) private var appServices
    @Environment(\.dismiss) private var dismiss

    @State private var showEditSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showUpdateConfirmation = false
    @State private var showEnvSheet = false
    @State private var errorAlert: String?

    /// Get the installed Typesense version
    private var typesenseVersion: TypesenseVersion? {
        installedTypesense.first
    }

    /// Calculate running status dynamically from TypesenseProcessManager
    private var isRunning: Bool {
        appServices.typesenseProcess.isRunning
    }

    private var startupError: String? {
        appServices.typesenseProcess.startupError
    }

    private var isOperationInProgress: Bool {
        appServices.typesense.isInstalling ||
        appServices.typesense.isUpdating ||
        appServices.typesense.isRemoving ||
        appServices.typesenseProcess.isStarting ||
        appServices.typesenseProcess.isStopping
    }

    /// Check if update is available
    private var hasUpdate: Bool {
        guard let installed = typesenseVersion,
              let latest = appServices.typesense.availableMetadata?.latest else {
            return false
        }
        return installed.version != latest
    }

    @ViewBuilder
    private var infoBar: some View {
        if let typesenseVersion {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    // Version info
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.blue)
                            .font(.callout)
                        Text("Version \(typesenseVersion.version)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // Port info
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Text("Port \(String(typesenseVersion.port))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // Auto-start indicator
                    if typesenseVersion.autoStart {
                        HStack(spacing: 6) {
                            Image(systemName: "power")
                                .foregroundStyle(.green)
                                .font(.callout)
                            Text("Auto-start")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    // Running status
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isRunning ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(isRunning ? "Running" : "Stopped")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.background.secondary)

            Divider()
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = startupError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Dismiss") {
                    appServices.typesenseProcess.clearStartupError()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.red.opacity(0.1))

            Divider()
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        ContentUnavailableView(
            "Typesense Search Server",
            systemImage: "magnifyingglass",
            description: Text("Typesense is \(isRunning ? "running" : "stopped")")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            errorBanner
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Typesense")
        .toolbar {
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .automatic)
            }

            // Environment variables button - informative action
            ToolbarItem(placement: .automatic) {
                Button {
                    showEnvSheet = true
                } label: {
                    Label("Environment", systemImage: "doc.text")
                }
                .help("Show environment variables for .env file")
            }

            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .automatic)
            }

            // Update button (only if update available) - positioned before Edit
            if hasUpdate {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showUpdateConfirmation = true
                    } label: {
                        Label("Update", systemImage: "arrow.down.circle")
                    }
                    .buttonBorderShape(.circle)
                    .tint(.orange)
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(isOperationInProgress)
                    .help("Update to \(appServices.typesense.availableMetadata?.latest ?? "latest")")
                }
            }

            // Edit button
            ToolbarItem(placement: .automatic) {
                Button {
                    showEditSheet = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(isOperationInProgress)
                .help("Edit port and auto-start settings")
            }

            // Delete button
            ToolbarItem(placement: .automatic) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(isOperationInProgress)
                .help("Delete Typesense installation")
            }

            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .automatic)
            }

            // Start/Stop button (primary action)
            ToolbarItem(placement: .automatic) {
                Button {
                    toggleTypesense()
                } label: {
                    if appServices.typesenseProcess.isStarting {
                        Label("Starting...", systemImage: "hourglass")
                    } else if appServices.typesenseProcess.isStopping {
                        Label("Stopping...", systemImage: "hourglass")
                    } else {
                        Label(
                            isRunning ? "Stop" : "Start",
                            systemImage: isRunning ? "stop.fill" : "play.fill"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isRunning ? .red : nil)
                .keyboardShortcut(isRunning ? "k" : "r", modifiers: .command)
                .disabled(isOperationInProgress || typesenseVersion == nil)
                .help(isRunning ? "Stop Typesense (^K)" : "Start Typesense (^R)")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let typesenseVersion {
                TypesenseSheet(editing: typesenseVersion)
            }
        }
        .sheet(isPresented: $showEnvSheet) {
            TypesenseEnvironmentVariablesSheet()
        }
        .confirmationDialog(
            "Delete Typesense?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteTypesense()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Typesense binaries will be permanently deleted. Data files will be kept.")
        }
        .sheet(isPresented: $showUpdateConfirmation) {
            UpdateConfirmationSheet(
                serviceName: "Typesense",
                currentVersion: typesenseVersion?.version ?? "unknown",
                latestVersion: appServices.typesense.availableMetadata?.latest ?? "unknown",
                isUpdating: appServices.typesense.isUpdating,
                onUpdate: { updateTypesense() },
                onCancel: { showUpdateConfirmation = false }
            )
            .onChange(of: appServices.typesense.isUpdating) { _, isUpdating in
                if !isUpdating && !hasUpdate {
                    showUpdateConfirmation = false
                }
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

    // MARK: - Actions

    private func toggleTypesense() {
        guard let typesenseVersion else { return }

        Task {
            do {
                if isRunning {
                    await appServices.typesenseProcess.stop()
                } else {
                    try await appServices.typesenseProcess.start(port: typesenseVersion.port)
                }
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func updateTypesense() {
        Task {
            do {
                try await appServices.typesense.update()
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func deleteTypesense() {
        Task {
            do {
                // Stop Typesense first if running
                if isRunning {
                    await appServices.typesenseProcess.stop()
                }

                // Delete Typesense
                try await appServices.typesense.remove()

                // Navigate back to not installed view
                // (this happens automatically as the view reloads)
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }
}
