import SwiftUI
import SwiftData

/// Detail view for Reverb WebSocket server
/// Displays configuration and controls in a Liquid Glass toolbar
struct ReverbDetailView: View {
    @Query private var installedReverb: [ReverbVersion]

    @Environment(AppServices.self) private var appServices
    @Environment(\.dismiss) private var dismiss

    @State private var showEditSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showUpdateConfirmation = false
    @State private var showEnvSheet = false
    @State private var errorAlert: String?

    /// Get the installed Reverb version
    private var reverbVersion: ReverbVersion? {
        installedReverb.first
    }

    /// Calculate running status dynamically from ReverbProcessManager
    private var isRunning: Bool {
        appServices.reverbProcess.isRunning
    }

    private var startupError: String? {
        appServices.reverbProcess.startupError
    }

    private var isOperationInProgress: Bool {
        appServices.reverb.isInstalling ||
        appServices.reverb.isUpdating ||
        appServices.reverb.isRemoving ||
        appServices.reverbProcess.isStarting ||
        appServices.reverbProcess.isStopping
    }

    /// Check if update is available
    private var hasUpdate: Bool {
        guard let installed = reverbVersion,
              let latest = appServices.reverb.availableMetadata?.latest else {
            return false
        }
        return installed.version != latest
    }

    @ViewBuilder
    private var infoBar: some View {
        if let reverbVersion {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    // Version info
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.blue)
                            .font(.callout)
                        Text("Version \(reverbVersion.version)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // Port info
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Text("Port \(String(reverbVersion.port))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // Auto-start indicator
                    if reverbVersion.autoStart {
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
                    appServices.reverbProcess.clearStartupError()
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
            "Reverb WebSocket Server",
            systemImage: "waveform",
            description: Text("Reverb is \(isRunning ? "running" : "stopped")")
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
        .navigationTitle("Reverb")
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
                    .help("Update to \(appServices.reverb.availableMetadata?.latest ?? "latest")")
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
                .help("Delete Reverb installation")
            }

            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .automatic)
            }

            // Start/Stop button (primary action)
            ToolbarItem(placement: .automatic) {
                Button {
                    toggleReverb()
                } label: {
                    if appServices.reverbProcess.isStarting {
                        Label("Starting...", systemImage: "hourglass")
                    } else if appServices.reverbProcess.isStopping {
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
                .disabled(isOperationInProgress || reverbVersion == nil)
                .help(isRunning ? "Stop Reverb (⌘K)" : "Start Reverb (⌘R)")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let reverbVersion {
                ReverbSheet(editing: reverbVersion)
            }
        }
        .sheet(isPresented: $showEnvSheet) {
            ReverbEnvironmentVariablesSheet()
        }
        .confirmationDialog(
            "Delete Reverb?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteReverb()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All Reverb data and binaries will be permanently deleted.")
        }
        .sheet(isPresented: $showUpdateConfirmation) {
            UpdateConfirmationSheet(
                serviceName: "Reverb",
                currentVersion: reverbVersion?.version ?? "unknown",
                latestVersion: appServices.reverb.availableMetadata?.latest ?? "unknown",
                isUpdating: appServices.reverb.isUpdating,
                onUpdate: { updateReverb() },
                onCancel: { showUpdateConfirmation = false }
            )
            .onChange(of: appServices.reverb.isUpdating) { _, isUpdating in
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

    private func toggleReverb() {
        guard let reverbVersion else { return }

        Task {
            do {
                if isRunning {
                    await appServices.reverbProcess.stop()
                } else {
                    try await appServices.reverbProcess.start(port: reverbVersion.port)
                }
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func updateReverb() {
        Task {
            do {
                try await appServices.reverb.update()
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func deleteReverb() {
        Task {
            do {
                // Stop Reverb first if running
                if isRunning {
                    await appServices.reverbProcess.stop()
                }

                // Delete Reverb
                try await appServices.reverb.remove()

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

// MARK: - Preview