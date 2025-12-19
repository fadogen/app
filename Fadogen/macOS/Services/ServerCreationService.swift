import Foundation
import SwiftData
import OSLog

/// Orchestrates server creation (custom + provider-based)
@Observable
final class ServerCreationService {

    private let sshService: SSHService
    private let cloudflareService: CloudflareService
    private let ansibleManager: AnsibleManager
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "server-creation")

    var isCreating = false
    var creationProgress: String = ""
    var errorMessage: String?

    init(
        sshService: SSHService,
        cloudflareService: CloudflareService,
        ansibleManager: AnsibleManager,
        modelContext: ModelContext
    ) {
        self.sshService = sshService
        self.cloudflareService = cloudflareService
        self.ansibleManager = ansibleManager
        self.modelContext = modelContext
    }

    // MARK: - Public

    func createCustomServer(
        name: String?,
        username: String,
        host: String,
        port: Int,
        authMethodType: AuthMethodType,
        selectedSSHKey: SSHKeyOption,
        customSSHKeyContent: String,
        password: String,
        sudoPassword: String,
        tunnelConfig: CloudflareTunnelConfig? = nil
    ) async throws -> Server {
        logger.info("Creating custom server: \(name ?? host)")

        isCreating = true
        errorMessage = nil

        defer {
            isCreating = false
        }

        // Validate server name uniqueness
        try validateServerName(name)

        let sshConfig = try await sshService.prepareAuthCredentials(
            authMethodType: authMethodType,
            selectedSSHKey: selectedSSHKey,
            customSSHKeyContent: customSSHKeyContent
        )

        // Determine effective sudo password:
        // - If sudoPassword is provided, use it
        // - Otherwise, for password auth, fall back to SSH password
        let effectiveSudoPassword: String? = if !sudoPassword.isEmpty {
            sudoPassword
        } else if !sshConfig.useSSHKey && !password.isEmpty {
            password
        } else {
            nil
        }

        let newServer = Server(
            name: name?.isEmpty == false ? name : nil,
            username: username,
            host: host,
            port: port,
            useSSHKey: sshConfig.useSSHKey,
            password: sshConfig.useSSHKey ? nil : password,
            sudoPassword: effectiveSudoPassword,
            sshPrivateKey: sshConfig.keyContent,
            sshPublicKey: sshConfig.publicKey
        )

        // Step 3: Test connection with Ansible
        logger.info("Testing connection to \(host)...")
        try await ansibleManager.testConnection(server: newServer)

        // Step 4: Setup Cloudflare Tunnel (if enabled)
        if let tunnelConfig = tunnelConfig {
            logger.info("Setting up Cloudflare Tunnel for custom server...")

            let serverName = name?.isEmpty == false ? name! : host
            let tunnelInfo = try await setupCloudflareTunnel(
                serverName: serverName,
                config: tunnelConfig
            )

            // Create and attach CloudflareTunnel model
            await MainActor.run {
                let cloudflareTunnel = CloudflareTunnel(
                    tunnelID: tunnelInfo.tunnelInfo.id,
                    tunnelToken: tunnelInfo.tunnelInfo.token ?? "",
                    zoneID: tunnelConfig.zone.id,
                    zoneName: tunnelConfig.zone.name,
                    sshSubdomain: tunnelConfig.sshSubdomain,
                    dnsRecordID: tunnelInfo.dnsRecord.id,
                    server: nil,
                    integration: tunnelConfig.integration
                )
                modelContext.insert(cloudflareTunnel)
                newServer.cloudflareTunnel = cloudflareTunnel
                logger.info("Cloudflare Tunnel attached to custom server: \(tunnelInfo.tunnelInfo.id)")
            }
        }

        // Step 5: Save server
        logger.info("Connection successful, saving server...")
        try await MainActor.run {
            modelContext.insert(newServer)
            try modelContext.save()
        }

        logger.info("Custom server created successfully: \(newServer.id)")
        return newServer
    }

    func createServerFromIntegration(
        name: String?,
        integration: Integration,
        region: any ServerRegion,
        size: any ServerSize,
        tunnelConfig: CloudflareTunnelConfig? = nil
    ) async throws -> Server {
        logger.info("Creating server from integration: \(integration.displayName)")

        guard let credentials = ProviderCredentials.retrieve(for: integration) else {
            throw ServerCreationError.missingAPIToken
        }

        // Get provider-specific service via factory
        let providerService = try CloudProviderFactory.createService(for: integration.type)

        isCreating = true
        errorMessage = nil
        creationProgress = ""

        defer {
            isCreating = false
            creationProgress = ""
        }

        // Validate server name uniqueness
        try validateServerName(name)

        // Step 1: Get or generate SSH key
        updateProgress(String(localized: "Preparing SSH key..."))
        logger.info("Getting or generating SSH key...")
        let keyPair = try await sshService.getOrGenerateSSHKey()

        // Step 2: Upload SSH key to integration (with duplicate detection)
        updateProgress(String(localized: "Uploading SSH key to \(integration.displayName)..."))
        logger.info("Uploading SSH key to \(integration.displayName)...")

        // Generate unique name based on key content hash
        let keyHash = String(keyPair.publicKey.hashValue).replacingOccurrences(of: "-", with: "")
        let keyName = "Fadogen-\(keyHash.prefix(8))"

        let sshKeyID = try await providerService.uploadSSHKey(
            name: keyName,
            publicKey: keyPair.publicKey,
            credentials: credentials
        )

        // Step 2.5: Get latest Debian image
        updateProgress(String(localized: "Selecting latest Debian image..."))
        logger.info("Fetching latest Debian image from \(integration.displayName)...")

        let debianImage = try await providerService.getLatestDebianImage(credentials: credentials)
        logger.info("Selected Debian image: \(debianImage)")

        // Step 3: Create server
        updateProgress(String(localized: "Creating server in \(region.displayName)..."))
        logger.info("Creating server in region: \(region.slug)")

        let serverName = name?.isEmpty == false ? name! : "\(UUID().uuidString.prefix(8))"
        let serverInfo = try await providerService.createServer(
            name: serverName,
            region: region,
            size: size,
            image: debianImage,
            sshKeyID: sshKeyID,
            credentials: credentials
        )

        // Step 4: Save server with placeholder configuration
        updateProgress(String(localized: "Saving server configuration..."))
        logger.info("Server created with ID: \(serverInfo.providerID), saving...")

        let newServer = Server(
            name: name?.isEmpty == false ? name : nil,
            integration: integration,
            integrationServerID: serverInfo.providerID,
            username: "root",
            host: nil,  // No IP yet - will be fetched during provisioning
            port: 22,
            useSSHKey: true,
            password: nil,
            sshPrivateKey: keyPair.privateKey,
            sshPublicKey: keyPair.publicKey
        )

        // Mark as waiting for IP - ServerDetailView will handle provisioning
        await MainActor.run {
            newServer.status = ServerStatus.waitingForIP
        }

        // Step 4.5: Setup Cloudflare Tunnel (if enabled)
        if let tunnelConfig = tunnelConfig {
            updateProgress(String(localized: "Setting up Cloudflare Tunnel..."))
            logger.info("Setting up Cloudflare Tunnel for server...")

            do {
                let tunnelInfo = try await setupCloudflareTunnel(
                    serverName: serverName,
                    config: tunnelConfig
                )

                // Create and attach CloudflareTunnel model
                await MainActor.run {
                    let cloudflareTunnel = CloudflareTunnel(
                        tunnelID: tunnelInfo.tunnelInfo.id,
                        tunnelToken: tunnelInfo.tunnelInfo.token ?? "",
                        zoneID: tunnelConfig.zone.id,
                        zoneName: tunnelConfig.zone.name,
                        sshSubdomain: tunnelConfig.sshSubdomain,
                        dnsRecordID: tunnelInfo.dnsRecord.id,
                        server: nil,
                        integration: tunnelConfig.integration
                    )
                    modelContext.insert(cloudflareTunnel)
                    newServer.cloudflareTunnel = cloudflareTunnel
                    logger.info("Cloudflare Tunnel attached to server: \(tunnelInfo.tunnelInfo.id)")
                }
            } catch {
                logger.error("Failed to setup Cloudflare Tunnel: \(error.localizedDescription)")
                // Rollback: Delete the server from provider if tunnel setup fails
                updateProgress(String(localized: "Tunnel setup failed, cleaning up..."))
                try? await providerService.deleteServer(serverID: serverInfo.providerID, credentials: credentials)
                throw error
            }
        }

        try await MainActor.run {
            modelContext.insert(newServer)
            try modelContext.save()
        }

        logger.info("Server from provider created successfully: \(newServer.id)")
        return newServer
    }

    // MARK: - Private

    @MainActor
    private func updateProgress(_ message: String) {
        creationProgress = message
        logger.debug("Progress: \(message)")
    }

    private func validateServerName(_ name: String?) throws {
        // Skip validation if name is empty or nil (multiple servers can have no name)
        guard let name = name, !name.isEmpty else { return }

        // Check for existing server with the same name
        let nameToCheck = name
        let descriptor = FetchDescriptor<Server>(
            predicate: #Predicate { server in
                server.name == nameToCheck
            }
        )

        if let _ = try? modelContext.fetch(descriptor).first {
            logger.warning("Server name '\(name)' already exists")
            throw ServerCreationError.duplicateServerName
        }
    }

    private func setupCloudflareTunnel(
        serverName: String,
        config: CloudflareTunnelConfig
    ) async throws -> TunnelSetupResult {
        // Get account ID
        let accountID = try await cloudflareService.getAccountID(integration: config.integration)

        // Setup tunnel via CloudflareService orchestration method
        let result = try await cloudflareService.setupTunnelForServer(
            serverName: serverName,
            zoneName: config.zone.name,
            zoneID: config.zone.id,
            sshSubdomain: config.sshSubdomain,
            accountID: accountID,
            integration: config.integration
        )

        logger.info("Cloudflare Tunnel created: \(result.tunnelInfo.id)")
        return result
    }
}

// MARK: - Errors

enum ServerCreationError: LocalizedError {
    case missingAPIToken
    case duplicateServerName

    var errorDescription: String? {
        switch self {
        case .missingAPIToken:
            return String(localized: "Missing API token for provider")
        case .duplicateServerName:
            return String(localized: "A server with this name already exists")
        }
    }
}
