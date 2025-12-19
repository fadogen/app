import SwiftUI
import SwiftData

struct AddServerSheet: View {
    @Binding var createdServer: Server?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProvisioningService.self) private var provisioningService
    @Query private var integrations: [Integration]
    @Query private var allServers: [Server]

    @State private var selectedMode: ServerAddMode?
    @State private var selectedIntegration: Integration?

    // MARK: - Composition Pattern Access

    private var sshService: SSHService {
        provisioningService.sshService
    }

    private var cloudflareService: CloudflareService {
        provisioningService.cloudflareService
    }

    private var vpsIntegrations: [Integration] {
        integrations.filter { $0.supports(.vpsProvider) }
    }

    // Form fields
    @State private var name: String = ""
    @State private var username: String = ""
    @State private var host: String = ""
    @State private var sshPort: String = "22"
    @State private var authMethodType: AuthMethodType = .sshKey
    @State private var selectedSSHKey: SSHKeyOption = .auto
    @State private var customSSHKeyContent: String = ""
    @State private var password: String = ""
    @State private var sudoPassword: String = ""

    // Cloudflare Tunnel Configuration (managed by CloudflareTunnelConfigSection)
    @State private var tunnelConfig: CloudflareTunnelConfig?

    // UI State
    @State private var isTesting = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if selectedMode == nil {
                modeSelectionView
            } else if selectedMode == .fromProvider {
                AddServerFromProviderView(
                    createdServer: $createdServer,
                    preselectedIntegration: selectedIntegration,
                    onBack: {
                        selectedMode = nil
                        errorMessage = nil
                    }
                )
            } else {
                customServerView
            }
        }
    }

    // MARK: - Mode Selection View

    private var modeSelectionView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Text("Add Server")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .padding(20)

            ScrollView {
                LazyVGrid(columns: ViewConstants.providerGridColumns, spacing: 16) {
                    // VPS integration cards
                    ForEach(vpsIntegrations) { integration in
                        Button {
                            selectIntegration(integration)
                        } label: {
                            SelectableCard(
                                icon: integration.metadata.assetName,
                                title: integration.displayName,
                                iconColor: .blue,
                                isAsset: true
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Custom server card
                    Button {
                        selectedMode = .custom
                    } label: {
                        SelectableCard(
                            icon: "server.rack",
                            title: String(localized: "Custom Server"),
                            iconColor: .orange,
                            isAsset: false
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()
            }
            .padding(20)
        }
        .frame(width: 650, height: 600)
    }

    private func selectIntegration(_ integration: Integration) {
        selectedIntegration = integration
        selectedMode = .fromProvider
    }

    // MARK: - Custom Server View

    private var customServerView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Text("Add Custom Server")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .padding(20)
            .padding(.bottom, 0)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    BasicInfoSection(
                        name: $name,
                        username: $username,
                        host: $host,
                        sshPort: $sshPort
                    )

                    GroupBox {
                        VStack(spacing: 12) {
                            HStack(alignment: .center, spacing: 12) {
                                Text("Method")
                                    .frame(width: 80, alignment: .trailing)
                                    .foregroundStyle(.secondary)

                                Picker(selection: $authMethodType) {
                                    ForEach(AuthMethodType.allCases, id: \.self) { method in
                                        Text(method.localizedValue).tag(method)
                                    }
                                } label: {
                                    EmptyView()
                                }
                                .labelsHidden()
                                .frame(maxWidth: 200, alignment: .leading)

                                Spacer()
                            }
                        }
                        .padding(8)
                    } label: {
                        Text("Authentication Method")
                            .font(.headline)
                    }

                    if authMethodType == .sshKey {
                        SSHKeySection(
                            selectedSSHKey: $selectedSSHKey
                        )

                        if case .custom = selectedSSHKey {
                            CustomSSHKeyInput(
                                customSSHKeyContent: $customSSHKeyContent
                            )
                        }
                    } else {
                        PasswordSection(
                            password: $password
                        )
                    }

                    // Sudo Password (Optional, for provisioning)
                    SudoPasswordSection(sudoPassword: $sudoPassword)

                    // Cloudflare Tunnel (Optional)
                    CloudflareTunnelConfigSection(tunnelConfig: $tunnelConfig, isDisabled: isTesting)
                }
                .padding(20)
            }

            Divider()

            // Footer
            VStack(spacing: 8) {
                if let error = nameValidationError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }

                ErrorMessageView(message: errorMessage)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.escape)
                    .disabled(isTesting)

                    Spacer()

                    Button("Back") {
                        selectedMode = nil
                        errorMessage = nil
                    }
                    .disabled(isTesting)

                    Button {
                        performTestAndAdd()
                    } label: {
                        LoadingButton(
                            title: String(localized: "Add"),
                            loadingTitle: String(localized: "Adding..."),
                            isLoading: isTesting
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!canTestAndAdd || isTesting)
                }
            }
            .padding(20)
        }
        .frame(width: 650, height: 600)
    }

    private var canTestAndAdd: Bool {
        guard !username.isEmpty,
              !host.isEmpty,
              !sshPort.isEmpty,
              Int(sshPort) != nil else {
            return false
        }

        // Check for duplicate name
        if isDuplicateName {
            return false
        }

        switch authMethodType {
        case .sshKey:
            if case .custom = selectedSSHKey {
                return !customSSHKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        case .password:
            return !password.isEmpty
        }
    }

    private var isDuplicateName: Bool {
        guard !name.isEmpty else { return false }
        return allServers.contains { $0.name == name }
    }

    private var nameValidationError: String? {
        if isDuplicateName {
            return String(localized: "A server with this name already exists")
        }
        return nil
    }

    private func performTestAndAdd() {
        guard let port = Int(sshPort) else {
            errorMessage = String(localized: "Invalid port number")
            return
        }

        isTesting = true
        errorMessage = nil

        Task {
            do {
                // Create service with dependencies
                let creationService = ServerCreationService(
                    sshService: sshService,
                    cloudflareService: cloudflareService,
                    ansibleManager: provisioningService.createTemporaryManager(),
                    modelContext: modelContext
                )

                // Use service to create and validate server
                let newServer = try await creationService.createCustomServer(
                    name: name,
                    username: username,
                    host: host,
                    port: port,
                    authMethodType: authMethodType,
                    selectedSSHKey: selectedSSHKey,
                    customSSHKeyContent: customSSHKeyContent,
                    password: password,
                    sudoPassword: sudoPassword,
                    tunnelConfig: tunnelConfig
                )

                // Connection successful - navigate to server detail
                await MainActor.run {
                    createdServer = newServer
                    dismiss()
                }

            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isTesting = false
                }
            }
        }
    }
}

// MARK: - Server Add Mode

private enum ServerAddMode {
    case fromProvider
    case custom
}
