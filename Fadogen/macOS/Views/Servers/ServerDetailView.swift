import SwiftUI
import SwiftData

struct ServerDetailView: View {
    let server: Server

    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.modelContext) private var modelContext
    @SwiftUI.Environment(ProvisioningService.self) private var provisioningService
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var showEditSheet = false
    @State private var showPassword = false
    @State private var showSSHKey = false
    @State private var showDeleteConfirmation = false
    @State private var deletionInProgress = false
    @State private var deletionError: ServerDeletionError?
    @State private var showDeletionErrorAlert = false

    // MARK: - Composition Pattern Access

    /// Access SSH service via composition
    private var sshService: SSHService {
        provisioningService.sshService
    }

    private var ansibleManager: AnsibleManager {
        provisioningService.manager(for: server.id)
    }

    private var isCurrentlyProvisioning: Bool {
        guard server.status != .ready else { return false }

        // Show provisioning view if in "preparing" or "inProgress" state
        if server.status == .waitingForIP { return true }
        if server.status == .provisioning { return true }

        // Show provisioning view if Ansible is running or failed
        if case .running = ansibleManager.state { return true }
        if case .completed(.failure) = ansibleManager.state { return true }
        return false
    }

    enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        Group {
            if isCurrentlyProvisioning {
                ProvisioningLogsView(
                    ansibleManager: ansibleManager,
                    onRetry: performRetryProvisioning
                )
            } else {
                normalServerView
            }
        }
        .overlay {
            if deletionInProgress {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .progressViewStyle(.circular)

                        if let phase = provisioningService.deletionProgress[server.id] {
                            Text(phase.localizedDescription)
                                .font(.headline)
                                .foregroundStyle(.primary)
                        } else {
                            Text("Preparing deletion...")
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(32)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .disabled(deletionInProgress)
        .animation(.easeInOut(duration: 0.3), value: ansibleManager.state)
        .navigationTitle(server.name ?? "Server")
        .toolbar {
            if !isCurrentlyProvisioning {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showEditSheet = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
            }

            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditServerSheet(server: server)
        }
        .confirmationDialog(
            isCurrentlyProvisioning
                ? "Delete server during provisioning?"
                : "Are you sure you want to delete this server?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                performDeletion()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if isCurrentlyProvisioning {
                Text("WARNING: The server is currently being configured. If you delete it now, the server state may be unpredictable and could become inaccessible.")
            } else {
                Text("All server configuration and credentials will be permanently deleted.")
            }
        }
        .alert("Deletion Failed", isPresented: $showDeletionErrorAlert, presenting: deletionError) { error in
            // For Cloudflare errors, the tunnel is already detached as an orphan
            // Retrying will simply delete the server without touching the tunnel
            if case .cloudflareFailed = error {
                Button("Delete Server Anyway") {
                    performDeletion()
                }
                Button("Cancel", role: .cancel) {
                    deletionError = nil
                }
            } else {
                Button("Retry") {
                    performDeletion()
                }
                Button("Cancel", role: .cancel) {
                    deletionError = nil
                }
            }
        } message: { error in
            VStack(alignment: .leading, spacing: 8) {
                Text(error.errorDescription ?? "Unknown error")
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                }
            }
        }
        .onAppear {
            provisioningService.startProvisioningIfNeeded(for: server)
        }
    }

    @ViewBuilder
    private var normalServerView: some View {
        Form {
            if server.hasCompleteConfig() {
                Section("Information") {
                    if server.status == .ready {
                        LabeledContent("Status") {
                            Label("Provisioned", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    }

                    if let name = server.name {
                        LabeledContent("Name", value: name)
                    }

                    if server.status == .waitingForIP || server.host == nil {
                        LabeledContent("Host") {
                            Label("Waiting for IP address...", systemImage: "clock")
                                .foregroundStyle(.secondary)
                        }
                    } else if server.cloudflareTunnel != nil {
                        LabeledContent("Host") {
                            VStack(alignment: .leading, spacing: 4) {
                                if server.status == .ready {
                                    Text(server.cloudflareTunnel!.sshHostname)
                                        .font(.body)
                                } else {
                                    Text(server.host ?? "Unknown")
                                        .font(.body)
                                }
                                Text("via Cloudflare Tunnel")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        LabeledContent("Host", value: server.host ?? "Unknown")
                    }
                    LabeledContent("Username", value: server.username!)
                    LabeledContent("SSH Port", value: String(server.port!))
                }

                // Integration Section (only for servers created via integration)
                if let integration = server.integration {
                    Section("Integration") {
                        LabeledContent("Managed by") {
                            HStack(spacing: 8) {
                                Image(integration.type.metadata.assetName)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 16, height: 16)

                                Text(integration.type.metadata.displayName)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let serverID = server.integrationServerID {
                            LabeledContent("Server ID", value: serverID)
                        }

                        LabeledContent("Type") {
                            Label(server.isManagedByIntegration() ? "Managed" : "Custom",
                                  systemImage: server.isManagedByIntegration() ? "cloud.fill" : "server.rack")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Cloudflare Tunnel Section (conditional)
                if let tunnel = server.cloudflareTunnel {
                    Section("Cloudflare Tunnel") {
                        LabeledContent("Status") {
                            Label("Active", systemImage: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                        }

                        LabeledContent("SSH Hostname") {
                            Text(tunnel.sshHostname)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }

                        if let zoneName = tunnel.zoneName {
                            LabeledContent("Zone", value: zoneName)
                        }

                        if let subdomain = tunnel.sshSubdomain {
                            LabeledContent("Subdomain", value: subdomain)
                        }

                        LabeledContent("CNAME Target") {
                            Text(tunnel.tunnelCNAME)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }

                        if let tunnelID = tunnel.tunnelID {
                            LabeledContent("Tunnel ID") {
                                Text(tunnelID)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Deployed Projects Section
                Section("Deployed Projects") {
                    if server.deployedProjects?.isEmpty ?? true {
                        Text("No sites deployed on this server")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(server.deployedProjects ?? []) { deployedProject in
                            NavigationLink(value: ProjectDestination.remote(deployedProject)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(deployedProject.name)
                                        .font(.headline)

                                    if let domain = deployedProject.productionDomain {
                                        Text("https://\(domain)")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                    }

                                    if let traefikIntegration = deployedProject.traefikDNSIntegration {
                                        Label("SSL via \(traefikIntegration.type.metadata.displayName)", systemImage: "lock.shield")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Authentication") {
                    LabeledContent("Method") {
                        Label(server.useSSHKey! ? "SSH Key" : "Password",
                              systemImage: server.useSSHKey! ? "key.fill" : "lock.fill")
                            .foregroundStyle(.secondary)
                    }

                    if server.useSSHKey!, let sshKey = server.sshPrivateKey {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("SSH Key")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button {
                                    showSSHKey.toggle()
                                } label: {
                                    Image(systemName: showSSHKey ? "eye.slash" : "eye")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if showSSHKey {
                                Text(sshKey)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(4)
                            } else {
                                Text("••••••••")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if !server.useSSHKey!, let password = server.password {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Password")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if showPassword {
                                Text(password)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text("••••••••")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        performConnectionTest()
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Testing Connection...")
                            } else {
                                Image(systemName: "network")
                                Text("Test Connection")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isTesting || server.status == .waitingForIP)

                    if let result = testResult {
                        switch result {
                        case .success:
                            Label("Connection successful", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let error):
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Connection failed", systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("Configuration incomplete")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func performRetryProvisioning() {
        // Delegate retry to ProvisioningService
        provisioningService.retryProvisioning(for: server)
    }

    private func performConnectionTest() {
        guard server.hasCompleteConfig() else { return }

        isTesting = true
        testResult = nil

        Task {
            do {
                // Test connection with Ansible
                try await ansibleManager.testConnection(server: server)

                await MainActor.run {
                    testResult = .success
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }

    private func performDeletion() {
        deletionInProgress = true
        deletionError = nil

        Task {
            let result = await provisioningService.deleteServer(server, from: modelContext)

            await MainActor.run {
                switch result {
                case .success:
                    // Deletion successful - dismiss immediately to prevent accessing deleted server
                    dismiss()
                case .failure(let error):
                    // Deletion failed - show error alert and stay on view
                    deletionInProgress = false
                    deletionError = error
                    showDeletionErrorAlert = true
                }
            }
        }
    }
}
