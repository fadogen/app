import SwiftUI
import SwiftData

/// Detail view for a database or cache service
/// Displays logs, configuration, and controls in a Liquid Glass toolbar
struct ServiceDetailView: View {
    let service: DisplayServiceVersion

    @Environment(AppServices.self) private var appServices
    @Environment(\.dismiss) private var dismiss
    @Query private var allServices: [ServiceVersion]

    @State private var showEditSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showUpdateConfirmation = false
    @State private var showEnvSheet = false
    @State private var isAtBottom = true
    @State private var errorAlert: String?

    /// Get the real ServiceVersion object from SwiftData
    private var serviceVersion: ServiceVersion? {
        allServices.first {
            $0.serviceType == service.serviceType && $0.major == service.major
        }
    }

    private var serviceProcesses: ServiceProcessManager {
        appServices.serviceProcesses
    }

    /// Calculate running status dynamically from ServiceProcessManager
    private var isRunning: Bool {
        serviceProcesses.isRunning(service: service.serviceType, major: service.major)
    }

    private var logs: [String] {
        serviceProcesses.getLogs(service: service.serviceType, major: service.major)
    }

    private var startupError: String? {
        serviceProcesses.startupErrors[identifier]
    }

    private var isOperationInProgress: Bool {
        appServices.services.installingServices.contains(identifier) ||
        appServices.services.updatingServices.contains(identifier) ||
        appServices.services.removingServices.contains(identifier) ||
        serviceProcesses.isStarting(service: service.serviceType, major: service.major) ||
        serviceProcesses.isStopping(service: service.serviceType, major: service.major)
    }

    private var identifier: String {
        "\(service.serviceType.rawValue)-\(service.major)"
    }

    /// Calculate hasUpdate dynamically from SwiftData and metadata (not from static DisplayServiceVersion)
    /// Uses centralized helper that handles both standard and single-installation services
    private var hasUpdate: Bool {
        guard let serviceVersion = serviceVersion else { return false }
        return appServices.services.hasUpdate(
            service: service.serviceType,
            major: serviceVersion.major,
            currentMinor: serviceVersion.minor
        )
    }

    /// Latest available version from metadata
    /// Uses centralized helper that handles both standard and single-installation services
    private var latestAvailable: String {
        guard let serviceVersion = serviceVersion else { return service.latestAvailable }
        return appServices.services.latestAvailable(
            service: service.serviceType,
            major: serviceVersion.major
        ) ?? service.latestAvailable
    }

    @ViewBuilder
    private var infoBar: some View {
        if let serviceVersion {
            HStack(spacing: 12) {
                // Port info
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Text("Port \(String(serviceVersion.port))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // Auto-start indicator
                if serviceVersion.autoStart {
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
                    serviceProcesses.clearStartupError(service: service.serviceType, major: service.major)
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
    private var logsArea: some View {
        Group {
            if logs.isEmpty {
                ContentUnavailableView(
                    "Empty Logs",
                    systemImage: "doc.text",
                    description: Text("Logs will appear here when \(service.serviceType.displayName) \(service.major) is running")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(logs.joined(separator: "\n"))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                                .onScrollVisibilityChange(threshold: 0.9) { isVisible in
                                    isAtBottom = isVisible
                                }
                        }
                        .padding()
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onAppear {
                        scrollToBottom(proxy)
                    }
                    .onChange(of: logs) { _, _ in
                        scrollToBottom(proxy)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !isAtBottom {
                            Button {
                                scrollToBottom(proxy)
                            } label: {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 40, height: 40)
                                    .background(.blue, in: Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                            }
                            .buttonStyle(.plain)
                            .padding(16)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: isAtBottom)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            errorBanner
            logsArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("\(service.serviceType.displayName) \(serviceVersion?.major ?? service.major)")
        .toolbar {
            // Environment variables button - informative action, positioned first
            ToolbarItem(placement: .automatic) {
                Button {
                    showEnvSheet = true
                } label: {
                    Label("Environment", systemImage: "doc.text")
                }
                .help("Show environment variables for .env file")
            }

            // Update button (only if update available) - prominent, next to Environment
            if hasUpdate {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showUpdateConfirmation = true
                    } label: {
                        Label("Update", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(.orange)
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(isOperationInProgress)
                    .help("Update to \(latestAvailable)")
                }
            }

            ToolbarSpacer(.flexible, placement: .automatic)

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
                .help("Delete this service version")
            }

            ToolbarSpacer(.flexible, placement: .automatic)

            // Clear logs button - separated from destructive actions
            ToolbarItem(placement: .automatic) {
                Button {
                    clearLogs()
                } label: {
                    Label("Clear Logs", systemImage: "eraser")
                }
                .disabled(logs.isEmpty)
                .help("Clear all logs")
            }

            ToolbarSpacer(.flexible, placement: .automatic)

            // Start/Stop button (primary action)
            ToolbarItem(placement: .automatic) {
                Button {
                    toggleService()
                } label: {
                    if serviceProcesses.isStarting(service: service.serviceType, major: service.major) {
                        Label("Starting...", systemImage: "hourglass")
                    } else if serviceProcesses.isStopping(service: service.serviceType, major: service.major) {
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
                .disabled(isOperationInProgress)
                .help(isRunning ? "Stop service (⌘K)" : "Start service (⌘R)")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let serviceVersion {
                ServiceSheet(editing: serviceVersion)
            }
        }
        .sheet(isPresented: $showEnvSheet) {
            EnvironmentVariablesSheet(service: service)
        }
        .confirmationDialog(
            "Delete \(service.serviceType.displayName) \(service.major)?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteService()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All data and binaries for \(service.serviceType.displayName) \(service.major) will be permanently deleted.")
        }
        .sheet(isPresented: $showUpdateConfirmation) {
            UpdateConfirmationSheet(
                serviceName: "\(service.serviceType.displayName) \(service.major)",
                currentVersion: serviceVersion?.minor ?? service.minor ?? "unknown",
                latestVersion: latestAvailable,
                isUpdating: appServices.services.updatingServices.contains(identifier),
                onUpdate: { updateService() },
                onCancel: { showUpdateConfirmation = false }
            )
            .onChange(of: appServices.services.updatingServices) { _, newValue in
                // Close sheet when update completes (service removed from updatingServices)
                if !newValue.contains(identifier) && !hasUpdate {
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

    private func toggleService() {
        Task {
            do {
                if isRunning {
                    try await serviceProcesses.stop(
                        service: service.serviceType,
                        major: service.major
                    )
                } else {
                    try await serviceProcesses.start(
                        service: service.serviceType,
                        major: service.major,
                        port: serviceVersion?.port ?? service.port
                    )
                }
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func updateService() {
        Task {
            do {
                try await appServices.services.update(
                    service: service.serviceType,
                    major: service.major
                )
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func deleteService() {
        Task {
            do {
                // Stop service first if running
                if isRunning {
                    try await serviceProcesses.stop(
                        service: service.serviceType,
                        major: service.major
                    )
                }

                // Delete service
                try await appServices.services.remove(
                    service: service.serviceType,
                    major: service.major
                )

                // Navigate back to list after deletion
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }

    private func clearLogs() {
        serviceProcesses.clearLogs(service: service.serviceType, major: service.major)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

// MARK: - Preview