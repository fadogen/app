import SwiftUI
import SwiftData

struct MailpitView: View {
    @Query private var mailpitConfigs: [MailpitConfig]
    @Environment(AppServices.self) private var appServices
    @Environment(\.modelContext) private var modelContext

    @State private var showEditSheet = false
    @State private var showEnvSheet = false
    @State private var errorAlert: String?

    /// Get or create the Mailpit configuration
    private var config: MailpitConfig? {
        mailpitConfigs.first
    }

    /// Check if Mailpit is running
    private var isRunning: Bool {
        appServices.mailpit.isRunning
    }

    /// Get startup error if any
    private var startupError: String? {
        appServices.mailpit.startupError
    }

    /// Check if an operation is in progress
    private var isOperationInProgress: Bool {
        appServices.mailpit.isStarting || appServices.mailpit.isStopping
    }

    @ViewBuilder
    private var infoBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // SMTP port info
                HStack(spacing: 6) {
                    Image(systemName: "envelope")
                        .foregroundStyle(.blue)
                        .font(.callout)
                    Text("SMTP \(String(config?.smtpPort ?? 1025))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // UI port info
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Text("UI \(String(config?.uiPort ?? 8025))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // Auto-start indicator
                if config?.autoStart == true {
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
                    appServices.mailpit.clearStartupError()
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
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Mailpit Email Server",
                systemImage: "envelope",
                description: Text("Mailpit is \(isRunning ? "running" : "stopped")")
            )

            if isRunning {
                Link(destination: URL(string: "https://mail.localhost")!) {
                    Label("Open mail.localhost", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            errorBanner
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Mail")
        .toolbar {
            ToolbarSpacer(.flexible, placement: .automatic)

            // Environment variables button
            ToolbarItem(placement: .automatic) {
                Button {
                    showEnvSheet = true
                } label: {
                    Label("Environment", systemImage: "doc.text")
                }
                .help("Show environment variables for .env file")
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

            ToolbarSpacer(.flexible, placement: .automatic)

            // Start/Stop button (primary action)
            ToolbarItem(placement: .automatic) {
                Button {
                    toggleMailpit()
                } label: {
                    if appServices.mailpit.isStarting {
                        Label("Starting...", systemImage: "hourglass")
                    } else if appServices.mailpit.isStopping {
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
                .help(isRunning ? "Stop Mailpit (⌘K)" : "Start Mailpit (⌘R)")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            MailpitEditSheet()
        }
        .sheet(isPresented: $showEnvSheet) {
            MailpitEnvironmentSheet()
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

    private func toggleMailpit() {
        Task {
            do {
                if isRunning {
                    await appServices.mailpit.stop()
                } else {
                    let (cfg, wasCreated) = try appServices.mailpit.getOrCreateConfig()

                    // Regenerate Caddy config only if config was just created
                    if wasCreated {
                        try appServices.caddyConfig.generateMainCaddyfile()
                        appServices.caddyConfig.reloadCaddy()
                    }

                    try await appServices.mailpit.start(smtpPort: cfg.smtpPort, uiPort: cfg.uiPort)
                }
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }
}
