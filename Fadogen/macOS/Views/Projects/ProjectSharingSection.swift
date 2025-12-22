import SwiftUI
import SwiftData

/// Minimalist project sharing section with password protection.
/// Password can be configured BEFORE sharing for immediate protection.
struct ProjectSharingSection: View {
    @Bindable var project: LocalProject

    @Environment(AppServices.self) private var appServices
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Integration> { $0.typeRawValue == "cloudflare" })
    private var cloudflareIntegrations: [Integration]

    @Query private var tunnelRoutes: [LocalTunnelRoute]

    @State private var showCustomDomainSheet = false
    @State private var isStopping = false
    @State private var isGeneratingPassword = false

    // MARK: - Computed

    private var integration: Integration? { cloudflareIntegrations.first }
    private var permanentRoute: LocalTunnelRoute? { tunnelRoutes.first { $0.projectID == project.id } }

    private var quickTunnelState: QuickTunnelState {
        appServices.quickTunnel.state(for: project.id)
    }

    private var activeQuickTunnel: QuickTunnel? {
        appServices.quickTunnel.tunnel(for: project.id)
    }

    private var activeTunnel: (url: String, hostname: String, isQuick: Bool)? {
        if let quick = activeQuickTunnel {
            return (quick.publicURL, quick.hostname, true)
        }
        if let permanent = permanentRoute {
            return (permanent.publicURL, permanent.hostname, false)
        }
        return nil
    }

    private var isSharing: Bool { activeTunnel != nil }

    private var isPasswordProtected: Bool {
        project.sharingPassword != nil
    }

    // MARK: - Body

    var body: some View {
        Section("Sharing") {
            // Public URL row (always visible)
            publicURLRow

            // Password row (always visible - can pre-configure before sharing)
            passwordRow

            // Error message
            if case .failed(let message) = quickTunnelState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Custom domain option
            if integration != nil {
                customDomainRow
            }
        }
        .sheet(isPresented: $showCustomDomainSheet) {
            if let integration {
                CustomDomainSheet(project: project, integration: integration) {}
            }
        }
    }

    // MARK: - Public URL Row

    @ViewBuilder
    private var publicURLRow: some View {
        if let tunnel = activeTunnel {
            // Active: show URL with actions
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)

                Link(tunnel.hostname, destination: URL(string: tunnel.url)!)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    copyToClipboard(tunnel.url)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy URL")

                Button {
                    stopTunnel(isQuick: tunnel.isQuick)
                } label: {
                    if isStopping || quickTunnelState == .stopping {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "stop.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isStopping || quickTunnelState == .stopping)
                .help("Stop sharing")
            }
        } else {
            // Idle: show share button
            HStack {
                Label("Public URL", systemImage: "link")
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    startQuickTunnel()
                } label: {
                    if case .starting = quickTunnelState {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Share")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(quickTunnelState == .starting)
            }
        }
    }

    // MARK: - Password Row

    @ViewBuilder
    private var passwordRow: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { isPasswordProtected },
                set: { togglePassword($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Password", systemImage: "lock")
                    if isPasswordProtected {
                        Text("username: user")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .toggleStyle(.switch)
            .disabled(isGeneratingPassword)

            if isGeneratingPassword {
                ProgressView().controlSize(.small)
            }
        }

        if let password = project.sharingPassword {
            HStack {
                Text(password)
                    .font(.system(.body, design: .monospaced))

                Spacer()

                Button {
                    copyToClipboard(password)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy password")

                Button {
                    regeneratePassword()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Regenerate")
                .disabled(isGeneratingPassword)
            }
            .padding(.leading, 24)
        }
    }

    // MARK: - Custom Domain Row

    @ViewBuilder
    private var customDomainRow: some View {
        HStack {
            Label("Custom Domain", systemImage: "globe")
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showCustomDomainSheet = true
        }
    }

    // MARK: - Actions

    private func startQuickTunnel() {
        Task { @MainActor in
            try? await appServices.quickTunnel.start(for: project)
        }
    }

    /// Regenerate password and wait for completion
    private func regeneratePasswordAsync() async {
        isGeneratingPassword = true
        defer { isGeneratingPassword = false }

        let password = SecretGenerator.generatePassword(length: 12)
        guard let hash = try? await SecretGenerator.hashPasswordWithCaddy(password) else { return }

        project.sharingPassword = password
        project.sharingPasswordHash = hash
        saveAndReconcile()
    }

    private func stopTunnel(isQuick: Bool) {
        if isQuick {
            Task { @MainActor in
                await appServices.quickTunnel.stop(for: project.id)
            }
        } else {
            guard let integration else { return }
            isStopping = true
            Task { @MainActor in
                try? await appServices.cloudflaredTunnel.removeRoute(for: project, integration: integration)
                isStopping = false
            }
        }
    }

    private func togglePassword(_ enabled: Bool) {
        if enabled {
            generatePassword()
        } else {
            project.sharingPassword = nil
            project.sharingPasswordHash = nil
            saveAndReconcile()
        }
    }

    private func generatePassword() {
        Task { @MainActor in
            await regeneratePasswordAsync()
        }
    }

    private func regeneratePassword() {
        generatePassword()
    }

    private func saveAndReconcile() {
        try? modelContext.save()
        appServices.caddyConfig.reconcile(project: project)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
