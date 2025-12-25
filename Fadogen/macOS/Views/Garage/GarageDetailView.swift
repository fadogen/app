import SwiftUI
import SwiftData

/// Detail view for Garage S3 storage
/// Displays configuration and controls in a Liquid Glass toolbar
struct GarageDetailView: View {
    @Query private var installedGarage: [GarageVersion]

    @Environment(AppServices.self) private var appServices
    @Environment(\.dismiss) private var dismiss

    @State private var showEditSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showUpdateConfirmation = false
    @State private var showEnvSheet = false
    @State private var errorAlert: String?

    /// Get the installed Garage version
    private var garageVersion: GarageVersion? {
        installedGarage.first
    }

    /// Calculate running status dynamically from GarageProcessManager
    private var isRunning: Bool {
        appServices.garageProcess.isRunning
    }

    private var startupError: String? {
        appServices.garageProcess.startupError
    }

    private var isOperationInProgress: Bool {
        appServices.garage.isInstalling ||
        appServices.garage.isUpdating ||
        appServices.garage.isRemoving ||
        appServices.garageProcess.isStarting ||
        appServices.garageProcess.isStopping
    }

    /// Check if update is available
    private var hasUpdate: Bool {
        guard let installed = garageVersion,
              let latest = appServices.garage.availableMetadata?.latest else {
            return false
        }
        return installed.version != latest
    }

    @ViewBuilder
    private var infoBar: some View {
        if let garageVersion {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    // Version info
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.blue)
                            .font(.callout)
                        Text("Version \(garageVersion.version)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // Port info
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Text("S3 Port \(String(garageVersion.s3Port))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // Auto-start indicator
                    if garageVersion.autoStart {
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
                    appServices.garageProcess.clearStartupError()
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
            "Garage S3 Storage",
            systemImage: "externaldrive.connected.to.line.below",
            description: Text("Garage is \(isRunning ? "running" : "stopped")")
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
        .navigationTitle("Garage")
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
                    .help("Update to \(appServices.garage.availableMetadata?.latest ?? "latest")")
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
                .help("Delete Garage installation")
            }

            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .automatic)
            }

            // Start/Stop button (primary action)
            ToolbarItem(placement: .automatic) {
                Button {
                    toggleGarage()
                } label: {
                    if appServices.garageProcess.isStarting {
                        Label("Starting...", systemImage: "hourglass")
                    } else if appServices.garageProcess.isStopping {
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
                .disabled(isOperationInProgress || garageVersion == nil)
                .help(isRunning ? "Stop Garage (^K)" : "Start Garage (^R)")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let garageVersion {
                GarageSheet(editing: garageVersion)
            }
        }
        .sheet(isPresented: $showEnvSheet) {
            GarageEnvironmentVariablesSheet()
        }
        .confirmationDialog(
            "Delete Garage?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteGarage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Garage binaries will be permanently deleted. Data files will be kept.")
        }
        .sheet(isPresented: $showUpdateConfirmation) {
            UpdateConfirmationSheet(
                serviceName: "Garage",
                currentVersion: garageVersion?.version ?? "unknown",
                latestVersion: appServices.garage.availableMetadata?.latest ?? "unknown",
                isUpdating: appServices.garage.isUpdating,
                onUpdate: { updateGarage() },
                onCancel: { showUpdateConfirmation = false }
            )
            .onChange(of: appServices.garage.isUpdating) { _, isUpdating in
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

    private func toggleGarage() {
        guard let garageVersion else { return }

        Task {
            do {
                if isRunning {
                    await appServices.garageProcess.stop()
                } else {
                    try await appServices.garageProcess.start(s3Port: garageVersion.s3Port)
                }
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func updateGarage() {
        Task {
            do {
                try await appServices.garage.update()
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func deleteGarage() {
        Task {
            do {
                // Stop Garage first if running
                if isRunning {
                    await appServices.garageProcess.stop()
                }

                // Delete Garage
                try await appServices.garage.remove()

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
