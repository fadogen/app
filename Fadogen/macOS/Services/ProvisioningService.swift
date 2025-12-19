import Foundation
import SwiftData
import System
import Subprocess

@Observable
final class ProvisioningService {

    // MARK: - Dependencies

    let sshService: SSHService
    let cloudflareService: CloudflareService
    let dnsManager: DNSManager

    private let modelContext: ModelContext

    // MARK: - State

    private var managers: [UUID: AnsibleManager] = [:]
    private var provisioningTasks: [UUID: Task<Void, Never>] = [:]
    var deletionProgress: [UUID: ServerDeletionPhase] = [:]

    // MARK: - Initialization

    init(modelContext: ModelContext, dnsManager: DNSManager) {
        self.modelContext = modelContext
        self.sshService = SSHService()
        self.cloudflareService = CloudflareService()
        self.dnsManager = dnsManager
    }

    // MARK: - Public

    func manager(for serverId: UUID) -> AnsibleManager {
        if let existing = managers[serverId] {
            return existing
        }

        let new = AnsibleManager()
        managers[serverId] = new
        return new
    }

    func createTemporaryManager() -> AnsibleManager {
        AnsibleManager()
    }

    func startProvisioningIfNeeded(for server: Server) {
        guard provisioningTasks[server.id] == nil else { return }
        guard server.status != .ready && server.status != .failed,
              server.hasCompleteConfig() else { return }

        performProvisioning(for: server)
    }

    func retryProvisioning(for server: Server) {
        guard server.hasCompleteConfig() else { return }
        provisioningTasks[server.id]?.cancel()
        provisioningTasks[server.id] = nil
        performProvisioning(for: server)
    }

    func clearManager(for serverId: UUID) async {
        await managers[serverId]?.killExecution()
        provisioningTasks[serverId]?.cancel()
        provisioningTasks.removeValue(forKey: serverId)
        managers.removeValue(forKey: serverId)
    }

    func deleteServer(_ server: Server, from context: ModelContext) async -> Result<Void, ServerDeletionError> {
        let serverID = server.id

        // Query deployed projects BEFORE SwiftData nullifies relationships
        let projectsDescriptor = FetchDescriptor<DeployedProject>(
            predicate: #Predicate { deployedProject in
                deployedProject.server?.id == serverID
            }
        )
        let projectsToCleanup = (try? context.fetch(projectsDescriptor)) ?? []

        // Phase -1: Delete GitHub Actions secrets
        if !projectsToCleanup.isEmpty {
            // Find GitHub integration
            let gitHubDescriptor = FetchDescriptor<Integration>(
                predicate: #Predicate { integration in
                    integration.typeRawValue == "github"
                }
            )

            if let githubIntegrations = try? context.fetch(gitHubDescriptor),
               let githubIntegration = githubIntegrations.first {

                deletionProgress[serverID] = .deletingGitHubSecrets
                let githubSecretsService = GitHubSecretsService()

                for deployedProject in projectsToCleanup {
                    guard let owner = deployedProject.githubOwner, let repo = deployedProject.githubRepo else {
                        continue
                    }

                    try? await githubSecretsService.deleteDeploymentSecrets(
                        owner: owner,
                        repo: repo,
                        integration: githubIntegration
                    )
                }
            }
        }

        // Phase 0: Cleanup deployed projects DNS records and conditionally delete unlinked sites
        if !projectsToCleanup.isEmpty {
            deletionProgress[serverID] = .cleaningUpProjects

            for deployedProject in projectsToCleanup {
                // Check if project has a linked LocalProject
                let hasLinkedProject = deployedProject.linkedLocalProjectID != nil

                // Cleanup DNS records created by Fadogen
                if !deployedProject.createdDNSRecordIDs.isEmpty,
                   let zoneID = deployedProject.dnsZoneID,
                   let zoneName = deployedProject.dnsZoneName,
                   let integration = deployedProject.dnsIntegration {

                    let zone = DNSZone(name: zoneName, id: zoneID, integration: integration)

                    // List all records in the zone
                    if let allRecords = try? await dnsManager.listRecords(in: zone, type: nil, name: nil) {
                        // Protected record types that should NEVER be deleted
                        let protectedTypes = ["NS", "SOA"]

                        // Delete only records created by Fadogen (tracked IDs)
                        for record in allRecords where deployedProject.createdDNSRecordIDs.contains(record.id) {
                            // Additional safety check: never delete NS/SOA records
                            guard !protectedTypes.contains(record.type) else { continue }

                            try? await dnsManager.deleteRecord(record, in: zone)
                        }
                    }
                }

                await MainActor.run {
                    if hasLinkedProject {
                        // Project has linked LocalProject - keep it, only reset production config
                        deployedProject.clearProductionConfiguration()
                    } else {
                        // Orphan DeployedProject - delete it entirely
                        context.delete(deployedProject)
                    }
                }
            }
        }

        // Phase 1: Handle Cloudflare tunnel deletion
        if let tunnel = server.cloudflareTunnel,
           let tunnelID = tunnel.tunnelID,
           let zoneID = tunnel.zoneID,
           let dnsRecordID = tunnel.dnsRecordID {

            deletionProgress[serverID] = .deletingCloudflare
            var cloudflareIntegration = tunnel.integration

            if cloudflareIntegration == nil {
                let descriptor = FetchDescriptor<Integration>(
                    predicate: #Predicate { integration in
                        integration.typeRawValue == "cloudflare"
                    }
                )
                if let integrations = try? context.fetch(descriptor) {
                    cloudflareIntegration = integrations.first
                }
            }

            if let integration = cloudflareIntegration {
                do {
                    guard let email = integration.credentials.email,
                          let apiKey = integration.credentials.globalAPIKey else {
                        throw CloudflareError.unauthorized
                    }

                    // Get account ID
                    let accountID = try await cloudflareService.getAccountID(integration: integration)

                    // Delete DNS record
                    try await cloudflareService.deleteDNSRecord(
                        recordID: dnsRecordID,
                        zoneID: zoneID,
                        email: email,
                        apiKey: apiKey
                    )

                    // Delete tunnel
                    try await cloudflareService.deleteTunnel(
                        tunnelID: tunnelID,
                        accountID: accountID,
                        email: email,
                        apiKey: apiKey
                    )

                    // Success: delete tunnel locally
                    context.delete(tunnel)

                } catch {
                    // Cloudflare deletion failed - detach tunnel to create orphan
                    tunnel.server = nil
                    try? context.save()

                    deletionProgress.removeValue(forKey: serverID)
                    return .failure(.cloudflareFailed(details: error.localizedDescription))
                }
            } else {
                // No integration available - detach tunnel to create orphan
                tunnel.server = nil
                try? context.save()
            }
        }

        // Phase 2: Handle VPS integration server deletion
        if server.isManagedByIntegration(),
           let integration = server.integration,
           let integrationServerID = server.integrationServerID {

            deletionProgress[serverID] = .deletingProvider

            guard let credentials = ProviderCredentials.retrieve(for: integration) else {
                deletionProgress.removeValue(forKey: serverID)
                return .failure(.providerFailed(details: "No credentials found for integration"))
            }

            do {
                let providerService = try CloudProviderFactory.createService(for: integration.type)
                try await providerService.deleteServer(serverID: integrationServerID, credentials: credentials)
            } catch let error as URLError {
                deletionProgress.removeValue(forKey: serverID)
                return .failure(.networkError(details: error.localizedDescription))
            } catch {
                deletionProgress.removeValue(forKey: serverID)
                let errorMessage = error.localizedDescription
                if errorMessage.contains("401") || errorMessage.contains("403") {
                    return .failure(.unauthorized(service: integration.type.metadata.displayName))
                }
                return .failure(.providerFailed(details: errorMessage))
            }
        }

        // Phase 3: Delete local server record
        deletionProgress[serverID] = .completed
        await clearManager(for: serverID)

        await MainActor.run {
            context.delete(server)
            try? context.save()
        }

        deletionProgress.removeValue(forKey: serverID)
        return .success(())
    }

    // MARK: - Private

    private func performProvisioning(for server: Server) {
        let ansibleManager = manager(for: server.id)

        if server.status == .waitingForIP {
            ansibleManager.updateStatus(String(localized: "Server created successfully"))
        }

        server.status = .provisioning

        provisioningTasks[server.id] = Task {
            do {
                let targetUser = NSUserName()
                guard let storedPublicKey = server.sshPublicKey,
                      let storedPrivateKey = server.sshPrivateKey else {
                    throw DOError.timeout(String(localized: "SSH keys not found in server configuration"))
                }

                if server.isManagedByIntegration() {
                    let realIP = try await waitForServerActive(server: server, ansibleManager: ansibleManager)
                    guard !Task.isCancelled else { return }
                    server.host = realIP
                }

                guard let host = server.host else {
                    throw DOError.apiError("Server IP not available")
                }

                try await waitForSSH(server: server, host: host, port: server.port!, ansibleManager: ansibleManager)
                guard !Task.isCancelled else { return }

                // Detect system architecture
                ansibleManager.updateStatus(String(localized: "Detecting system architecture..."))
                let architecture = try await detectArchitecture(server: server)
                server.architecture = architecture

                // Determine if we should run prepare-ssh.yml
                // - Root user: run prepare-ssh.yml to create non-root user with SSH keys
                // - Non-root custom server: skip prepare-ssh.yml, user already exists
                let isRoot = server.username == "root"
                let isCustomServer = server.isCustomServer()

                // Determine the username for provision-server.yml
                let provisioningUser: String

                if isRoot {
                    // Standard flow: create non-root user with macOS username
                    ansibleManager.updateStatus(String(localized: "Setting up SSH access..."))
                    try await ansibleManager.prepareSSH(
                        server: server,
                        targetUser: targetUser,
                        sshPublicKey: storedPublicKey
                    )
                    guard !Task.isCancelled else { return }

                    server.username = targetUser
                    provisioningUser = targetUser
                } else if isCustomServer {
                    // Non-root custom server: skip prepare-ssh.yml
                    // User already exists, use their provided username
                    ansibleManager.updateStatus(String(localized: "Using existing user for provisioning..."))
                    provisioningUser = server.username!
                } else {
                    // VPS provider with non-root (shouldn't happen normally)
                    provisioningUser = server.username!
                }

                ansibleManager.updateStatus(String(localized: "Configuring server security and packages..."))

                // Prepare Cloudflare Tunnel variables (optional)
                var tunnelVars: [String: String]? = nil

                if let tunnel = server.cloudflareTunnel,
                   let tunnelID = tunnel.tunnelID,
                   let tunnelToken = tunnel.tunnelToken {
                    tunnelVars = [
                        "tunnel_id": tunnelID,
                        "tunnel_token": tunnelToken,
                        "ssh_hostname": tunnel.sshHostname
                    ]
                }

                try await ansibleManager.provisionServer(
                    server: server,
                    targetUser: provisioningUser,
                    sshPublicKey: storedPublicKey,
                    tunnelVars: tunnelVars
                )
                guard !Task.isCancelled else { return }

                if let tunnel = server.cloudflareTunnel {
                    ansibleManager.updateStatus(String(localized: "Verifying Cloudflare Tunnel connection..."))

                    let tunnelWorks = try await testTunnelConnection(
                        server: server,
                        tunnel: tunnel,
                        targetUser: provisioningUser,
                        privateKey: storedPrivateKey,
                        ansibleManager: ansibleManager
                    )

                    guard tunnelWorks else {
                        await MainActor.run {
                            server.status = .failed
                        }
                        throw DOError.timeout(String(localized: "Cloudflare Tunnel connection test failed. Cannot close SSH port."))
                    }

                    ansibleManager.updateStatus(String(localized: "Closing SSH port (tunnel-only access)..."))
                    try await ansibleManager.closeSSHPort(
                        server: server,
                        tunnelVars: tunnelVars!
                    )
                }

                await MainActor.run {
                    server.status = .ready
                }

                await clearManager(for: server.id)
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    server.status = .failed
                    provisioningTasks[server.id] = nil
                }
            }
        }
    }

    private func waitForServerActive(server: Server, ansibleManager: AnsibleManager) async throws -> String {
        guard let integration = server.integration,
              let serverID = server.integrationServerID,
              let credentials = ProviderCredentials.retrieve(for: integration) else {
            throw CloudProviderError.invalidParameters
        }

        let providerService = try CloudProviderFactory.createService(for: integration.type)
        ansibleManager.updateStatus(String(localized: "Waiting for server to boot..."))

        let serverInfo = try await providerService.waitForServerActive(
            serverID: serverID,
            credentials: credentials,
            maxWaitTime: 300,
            logCallback: { message in
                Task { @MainActor in
                    ansibleManager.updateStatus(message)
                }
            }
        )

        guard !Task.isCancelled else { throw CancellationError() }
        guard let publicIP = serverInfo.publicIPv4 else {
            throw CloudProviderError.serverCreationFailed(String(localized: "Server is active but has no public IP"))
        }

        ansibleManager.updateStatus(String(localized: "Server is ready (IP: \(publicIP))"))
        return publicIP
    }

    private func waitForSSH(server: Server, host: String, port: Int, ansibleManager: AnsibleManager) async throws {
        ansibleManager.updateStatus(String(localized: "Establishing SSH connection..."))

        for _ in 1...30 {
            guard !Task.isCancelled else { throw CancellationError() }

            if let result = try? await run(
                .path(FilePath("/usr/bin/nc")),
                arguments: .init(["-z", "-w", "2", host, String(port)]),
                output: .discarded,
                error: .discarded
            ), result.terminationStatus.isSuccess {
                ansibleManager.updateStatus(String(localized: "SSH connection established"))
                return
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        throw DOError.timeout(String(localized: "SSH service did not become available within the expected time"))
    }

    private func detectArchitecture(server: Server) async throws -> String {
        guard let host = server.host,
              let port = server.port,
              let username = server.username,
              let privateKey = server.sshPrivateKey else {
            throw DOError.apiError("Missing SSH configuration for architecture detection")
        }

        // Create temporary SSH key file
        let tempKeyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pem")

        try privateKey.write(to: tempKeyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempKeyURL.path)

        defer {
            try? FileManager.default.removeItem(at: tempKeyURL)
        }

        // Execute: uname -m
        let result = try await run(
            .path(FilePath("/usr/bin/ssh")),
            arguments: .init([
                "-i", tempKeyURL.path,
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR",
                "\(username)@\(host)",
                "-p", "\(port)",
                "uname -m"
            ]),
            output: .string(limit: .max),
            error: .discarded
        )

        guard let output = result.standardOutput else {
            throw DOError.apiError("Failed to detect architecture: no output from uname command")
        }

        let arch = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strict validation - NO fallback
        switch arch {
        case "aarch64", "arm64":
            return "aarch64"
        case "x86_64", "amd64":
            return "amd64"
        default:
            throw DOError.apiError("Unsupported server architecture: '\(arch)'. Only aarch64 and amd64 are supported.")
        }
    }

    private func testTunnelConnection(
        server: Server,
        tunnel: CloudflareTunnel,
        targetUser: String,
        privateKey: String,
        ansibleManager: AnsibleManager
    ) async throws -> Bool {
        ansibleManager.updateStatus(String(localized: "Testing tunnel connection..."))
        try await Task.sleep(nanoseconds: 5_000_000_000)

        return (try? await ansibleManager.testTunnel(server: server, forceTunnel: true)) != nil
    }
}

// MARK: - Traefik DNS

extension ProvisioningService {

    func configureTraefikDNSProvider(
        server: Server,
        integration: Integration
    ) async throws {
        // Validate that integration supports DNS
        guard integration.supports(.dns) else {
            throw DNSError.capabilityNotSupported
        }

        // Extract credentials from integration
        let providerType = integration.type.rawValue.lowercased()

        // Get AnsibleManager for this server
        let ansibleManager = manager(for: server.id)

        // Get ACME email from UserPreferences
        let acmeEmail = getUserACMEEmail()

        // Build complete list of DNS providers for this server
        var allProviders = Set<String>()

        // Add providers from server's configured integrations (source of truth)
        if let configuredIntegrations = server.traefikDNSIntegrations {
            for integration in configuredIntegrations {
                allProviders.insert(integration.type.rawValue.lowercased())
            }
        }

        // Add the new provider being configured
        allProviders.insert(providerType)

        // Prepare Ansible variables
        // Cloudflare requires email + Global API Key (due to domain listing bug with API tokens)
        var extraVars: [String: String] = [
            "dns_providers": allProviders.sorted().joined(separator: ","),
            "provider_name": providerType,
            "acme_email": acmeEmail,
            "has_cloudflare_tunnel": server.cloudflareTunnel != nil ? "true" : "false"
        ]

        // Handle different authentication methods
        if integration.type.metadata.authMethod == .emailAndGlobalKey {
            // Cloudflare: uses email + Global API Key
            guard let email = integration.credentials.email,
                  let globalAPIKey = integration.credentials.globalAPIKey else {
                throw DNSError.invalidToken
            }
            extraVars["provider_email"] = email
            extraVars["provider_key"] = globalAPIKey
        } else {
            // Other providers: use single API token
            guard let token = integration.credentials.primaryToken(for: integration.type) else {
                throw DNSError.invalidToken
            }
            extraVars["provider_token"] = token
        }

        ansibleManager.updateStatus("Adding \(providerType) DNS provider to Traefik on \(server.name ?? server.host ?? "server")...")

        try await ansibleManager.configureTraefikDNS(
            server: server,
            extraVars: extraVars
        )

        ansibleManager.updateStatus("\(providerType) DNS provider configured successfully")
    }

    private func getUserACMEEmail() -> String {
        let descriptor = FetchDescriptor<UserPreferences>()
        if let preferences = try? modelContext.fetch(descriptor).first,
           let email = preferences.acmeEmail, !email.isEmpty {
            return email
        }
        // Fallback to noreply (Let's Encrypt stopped notifications in June 2025)
        return "noreply@fadogen.app"
    }
}
