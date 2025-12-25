import Foundation
import SwiftData
import Observation

enum ProductionConfigurationStep: String, Sendable {
    case idle
    case creatingDNSRecord = "Creating DNS record..."
    case configuringTraefik = "Configuring Traefik SSL..."
    case configuringBackup = "Configuring backup storage..."
    case configuringGitHub = "Configuring GitHub secrets..."
    case completed
}

@Observable
final class ProjectDeploymentService {

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let provisioningService: ProvisioningService
    private let dnsManager: DNSManager
    private let githubSecretsService: GitHubSecretsService
    private let envFileService: EnvFileService
    private let cloudflareService: CloudflareService
    private let scalewayService: ScalewayService

    // MARK: - State

    var isDeploying = false
    var error: Error?

    var currentStep: ProductionConfigurationStep = .idle
    var pendingRepositoryRename: RepositoryResolution?
    private var deploymentTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Initialization

    init(modelContext: ModelContext, provisioningService: ProvisioningService, dnsManager: DNSManager) {
        self.modelContext = modelContext
        self.provisioningService = provisioningService
        self.dnsManager = dnsManager
        self.envFileService = EnvFileService()
        self.githubSecretsService = GitHubSecretsService()
        self.cloudflareService = CloudflareService()
        self.scalewayService = ScalewayService()
    }

    // MARK: - Public

    @discardableResult
    func configureProjectDeployment(
        project: LocalProject,
        server: Server,
        domain: DNSZone?,
        subdomain: String,
        backupIntegration: Integration? = nil
    ) async throws -> DeployedProject {
        isDeploying = true

        // Get or create DeployedProject (before try block for error handling access)
        let deployedProject = getOrCreateDeployedProject(for: project)
        deployedProject.deploymentStatus = .deploying
        deployedProject.deploymentError = nil

        do {
            defer {
                isDeploying = false
                currentStep = .idle
            }

            // 1. Link project to server
            deployedProject.server = server

            // 2. Configure production domain
            if let domain = domain {
                let oldDomain = deployedProject.productionDomain
                let fqdn = subdomain.isEmpty ? domain.name : "\(subdomain).\(domain.name)"
                let domainChanged = oldDomain != fqdn

                // Cleanup existing domain configuration only if domain is changing
                if oldDomain != nil && domainChanged {
                    await cleanupExistingDomainConfiguration(deployedProject: deployedProject, server: server)
                }

                deployedProject.dnsZoneName = domain.name
                deployedProject.dnsZoneID = domain.id
                deployedProject.dnsIntegration = domain.integration
                deployedProject.productionDomain = fqdn

                // Create DNS record only if domain changed or first time setup
                if domainChanged || oldDomain == nil {
                    currentStep = .creatingDNSRecord
                    try await createDNSRecord(
                        deployedProject: deployedProject,
                        server: server,
                        domain: domain,
                        subdomain: subdomain
                    )

                    // If server has Cloudflare Tunnel, add HTTP route
                    if let tunnel = server.cloudflareTunnel,
                       let tunnelID = tunnel.tunnelID {

                        // Get integration from tunnel, or fallback to fetching Cloudflare integration
                        let integration: Integration? = tunnel.integration ?? (try? fetchCloudflareIntegration())

                        if let integration {
                            // Fix the tunnel by attaching the integration for future use
                            if tunnel.integration == nil {
                                tunnel.integration = integration
                            }

                            guard let email = integration.credentials.email,
                                  let apiKey = integration.credentials.globalAPIKey else {
                                throw CloudflareError.unauthorized
                            }

                            let cloudflareService = CloudflareService()
                            let accountID = try await cloudflareService.getAccountID(integration: integration)

                            try await cloudflareService.addHTTPRouteToTunnel(
                                tunnelID: tunnelID,
                                hostname: fqdn,
                                localPort: 80,
                                accountID: accountID,
                                email: email,
                                apiKey: apiKey
                            )
                        }
                    }
                }
            }

        // Symfony: collect env sections in memory (don't write to .env.production which is versioned)
        // Laravel: write directly to .env.production file
        let isSymfony = project.framework == .symfony
        var symfonyEnvSections: [String] = []

        // 4. Configure Traefik DNS integration (if server without tunnel)
        // Auto-use same integration as domain (DNS challenge requires domain's authoritative DNS)
        if server.cloudflareTunnel == nil, let traefikIntegration = domain?.integration {
            // Check if THIS server already has this integration configured
            let serverHasIntegration = server.traefikDNSIntegrations?.contains(where: {
                $0.id == traefikIntegration.id
            }) ?? false

            if !serverHasIntegration {
                // Configure Traefik with this integration
                currentStep = .configuringTraefik
                try await provisioningService.configureTraefikDNSProvider(
                    server: server,
                    integration: traefikIntegration
                )

                // Add to server's configured providers
                if server.traefikDNSIntegrations == nil {
                    server.traefikDNSIntegrations = []
                }
                server.traefikDNSIntegrations?.append(traefikIntegration)
            }

            // Store project's reference (same as dnsIntegration)
            deployedProject.traefikDNSIntegration = traefikIntegration

            // Add DNS provider to env config
            let providerName = traefikIntegration.type.rawValue.lowercased()
            if isSymfony {
                // Symfony: collect in memory (will be added to GitHub Secrets)
                symfonyEnvSections.append(envFileService.generateDNSProviderSection(provider: providerName))
            } else {
                // Laravel: write to .env.production file
                let projectURL = URL(fileURLWithPath: project.path)
                try envFileService.addDNSProviderVariable(to: projectURL, provider: providerName)
            }
        }

        // 5. Configure backup storage
        if let backupIntegration = backupIntegration, backupIntegration.supports(.backup) {
            currentStep = .configuringBackup
            if let config = try await buildBackupConfig(
                integration: backupIntegration,
                projectSlug: project.sanitizedName
            ) {
                if isSymfony {
                    symfonyEnvSections.append(envFileService.backupConfigToSection(config))
                } else {
                    let projectURL = URL(fileURLWithPath: project.path)
                    try envFileService.writeBackupConfig(config, to: projectURL)
                }
            }
            deployedProject.backupIntegration = backupIntegration
        } else {
            // No backup provider - remove any existing backup variables (Laravel only)
            if !isSymfony {
                let projectURL = URL(fileURLWithPath: project.path)
                try envFileService.removeAllBackupVariables(from: projectURL)
            }
            deployedProject.backupIntegration = nil
        }

        // 6. Configure GitHub Actions secrets (if GitHub repository)
        if deployedProject.githubOwner != nil && deployedProject.githubRepo != nil {

            // Find GitHub integration
            let descriptor = FetchDescriptor<Integration>(
                predicate: #Predicate { integration in
                    integration.typeRawValue == "github"
                }
            )

            if let githubIntegrations = try? modelContext.fetch(descriptor),
               let githubIntegration = githubIntegrations.first {
                // Configure deployment secrets
                currentStep = .configuringGitHub
                do {
                    let envContent = try await githubSecretsService.configureDeploymentSecrets(
                        deployedProject: deployedProject,
                        project: project,
                        server: server,
                        integration: githubIntegration,
                        envFileService: envFileService,
                        additionalEnvSections: symfonyEnvSections
                    )
                    // Save env content for backup (prevents secret loss on local deletion)
                    deployedProject.envProductionContent = envContent
                } catch GitHubSecretsService.SecretsError.repositoryRenamed(let resolution) {
                    // Repository was renamed - pause deployment and show confirmation dialog
                    // Don't throw: the modal will handle continuation via continueDeploymentWithResolvedRepo
                    pendingRepositoryRename = resolution
                    return deployedProject
                }
            }
        }

            // Deployment completed successfully
            currentStep = .completed
            deployedProject.deploymentStatus = .deployed
            deployedProject.deploymentError = nil
            try modelContext.save()

            return deployedProject

        } catch {
            // Mark deployment as failed on any error
            deployedProject.deploymentStatus = .failed
            deployedProject.deploymentError = error.localizedDescription
            try? modelContext.save()
            isDeploying = false
            currentStep = .idle
            throw error
        }
    }

    func updateDeployedProjectConfiguration(
        deployedProject: DeployedProject,
        server: Server,
        domain: DNSZone?,
        subdomain: String,
        backupIntegration: Integration? = nil
    ) async throws {
        isDeploying = true
        defer {
            isDeploying = false
            currentStep = .idle
        }

        deployedProject.deploymentStatus = .deploying
        deployedProject.deploymentError = nil

        // 1. Link project to server
        deployedProject.server = server

        // 2. Configure production domain
        if let domain = domain {
            let oldDomain = deployedProject.productionDomain
            let fqdn = subdomain.isEmpty ? domain.name : "\(subdomain).\(domain.name)"
            let domainChanged = oldDomain != fqdn

            // Cleanup existing domain configuration only if domain is changing
            if oldDomain != nil && domainChanged {
                await cleanupExistingDomainConfiguration(deployedProject: deployedProject, server: server)
            }

            deployedProject.dnsZoneName = domain.name
            deployedProject.dnsZoneID = domain.id
            deployedProject.dnsIntegration = domain.integration
            deployedProject.productionDomain = fqdn

            // Create DNS record only if domain changed or first time setup
            if domainChanged || oldDomain == nil {
                currentStep = .creatingDNSRecord
                try await createDNSRecord(
                    deployedProject: deployedProject,
                    server: server,
                    domain: domain,
                    subdomain: subdomain
                )

                // Add Cloudflare Tunnel HTTP route if applicable
                if let tunnel = server.cloudflareTunnel,
                   let tunnelID = tunnel.tunnelID {

                    // Get integration from tunnel, or fallback to fetching Cloudflare integration
                    let integration: Integration? = tunnel.integration ?? (try? fetchCloudflareIntegration())

                    if let integration {
                        if tunnel.integration == nil {
                            tunnel.integration = integration
                        }

                        guard let email = integration.credentials.email,
                              let apiKey = integration.credentials.globalAPIKey else {
                            throw CloudflareError.unauthorized
                        }

                        let accountID = try await cloudflareService.getAccountID(integration: integration)

                        try await cloudflareService.addHTTPRouteToTunnel(
                            tunnelID: tunnelID,
                            hostname: fqdn,
                            localPort: 80,
                            accountID: accountID,
                            email: email,
                            apiKey: apiKey
                        )
                    }
                }
            }
        }

        // 4. Configure Traefik (server-side only, no local .env updates)
        if server.cloudflareTunnel == nil, let traefikIntegration = domain?.integration {
            let serverHasIntegration = server.traefikDNSIntegrations?.contains(where: {
                $0.id == traefikIntegration.id
            }) ?? false

            if !serverHasIntegration {
                currentStep = .configuringTraefik
                try await provisioningService.configureTraefikDNSProvider(
                    server: server,
                    integration: traefikIntegration
                )

                if server.traefikDNSIntegrations == nil {
                    server.traefikDNSIntegrations = []
                }
                server.traefikDNSIntegrations?.append(traefikIntegration)
            }

            deployedProject.traefikDNSIntegration = traefikIntegration
        }

        // 5. Update backup integration reference (no local file updates)
        deployedProject.backupIntegration = backupIntegration

        // 6. Configure GitHub Actions secrets (if GitHub repository)
        if deployedProject.githubOwner != nil && deployedProject.githubRepo != nil {
            let descriptor = FetchDescriptor<Integration>(
                predicate: #Predicate { integration in
                    integration.typeRawValue == "github"
                }
            )

            if let githubIntegrations = try? modelContext.fetch(descriptor),
               let githubIntegration = githubIntegrations.first {
                currentStep = .configuringGitHub
                // Use saved envProductionContent for secrets (no local project access)
                let envContent = try await githubSecretsService.configureDeploymentSecrets(
                    deployedProject: deployedProject,
                    project: nil,
                    server: server,
                    integration: githubIntegration,
                    envFileService: envFileService
                )
                deployedProject.envProductionContent = envContent
            }
        }

        // Deployment completed
        currentStep = .completed
        deployedProject.deploymentStatus = .deployed
        deployedProject.deploymentError = nil
        try modelContext.save()
    }

    // MARK: - Repository Rename

    func continueDeploymentWithResolvedRepo(
        project: LocalProject?,
        deployedProject: DeployedProject,
        server: Server,
        resolution: RepositoryResolution,
        updateGitConfig: Bool
    ) async throws {
        // Clear pending state and reset to deploying
        pendingRepositoryRename = nil
        deployedProject.deploymentStatus = .deploying
        deployedProject.deploymentError = nil

        // Update project gitRemoteURL if available
        if let project {
            project.gitRemoteURL = resolution.newRemoteURL
        }
        // Always update project gitRemoteURL
        deployedProject.gitRemoteURL = resolution.newRemoteURL
        try modelContext.save()

        // Optionally update local .git/config (only if project exists)
        if updateGitConfig, let project {
            try await project.updateGitRemoteOrigin(to: resolution.newRemoteURL)
        }

        // Find GitHub integration
        let descriptor = FetchDescriptor<Integration>(
            predicate: #Predicate { integration in
                integration.typeRawValue == "github"
            }
        )

        guard let githubIntegrations = try? modelContext.fetch(descriptor),
              let githubIntegration = githubIntegrations.first else {
            throw GitHubSecretsService.SecretsError.missingCredentials
        }

        // Retry GitHub secrets with the resolved repository name
        isDeploying = true
        currentStep = .configuringGitHub
        defer {
            isDeploying = false
            currentStep = .idle
        }

        let envContent = try await githubSecretsService.configureDeploymentSecrets(
            deployedProject: deployedProject,
            project: project,
            server: server,
            integration: githubIntegration,
            envFileService: envFileService,
            resolvedRepoName: resolution.newName
        )

        // Save env content for backup (prevents secret loss on local deletion)
        deployedProject.envProductionContent = envContent

        // Mark deployment as complete
        currentStep = .completed
        deployedProject.deploymentStatus = .deployed
        deployedProject.deploymentError = nil
        try modelContext.save()
    }

    // MARK: - Resumption

    func resumeIncompleteDeployments() async {
        // Query for DeployedProjects with deploying status
        let deployingRawValue = ProjectDeploymentStatus.deploying.rawValue
        let descriptor = FetchDescriptor<DeployedProject>(
            predicate: #Predicate { deployedProject in
                deployedProject.deploymentStatusRawValue == deployingRawValue
            }
        )

        guard let pendingProjects = try? modelContext.fetch(descriptor) else { return }

        // Resume each deployment
        for deployedProject in pendingProjects {
            await resumeDeployment(for: deployedProject)
        }
    }

    func resumeDeployment(for deployedProject: DeployedProject) async {
        // Guard against duplicate tasks
        guard deploymentTasks[deployedProject.id] == nil else { return }

        // Guard against invalid states
        guard deployedProject.deploymentStatus == .deploying || deployedProject.deploymentStatus == .failed else {
            return
        }

        // Ensure project has server and domain configured
        guard let server = deployedProject.server,
              let dnsZoneName = deployedProject.dnsZoneName,
              let dnsZoneID = deployedProject.dnsZoneID,
              let dnsIntegration = deployedProject.dnsIntegration,
              let productionDomain = deployedProject.productionDomain else {
            // Missing required data, mark as failed
            deployedProject.deploymentStatus = .failed
            deployedProject.deploymentError = "Incomplete deployment configuration"
            try? modelContext.save()
            return
        }

        // Find linked LocalProject (optional - deployment can proceed without it using saved env)
        let linkedProject = resolveLocalProject(for: deployedProject)

        // Create deployment task
        let task = Task {
            // Set status to deploying (in case resuming from failed)
            await MainActor.run {
                deployedProject.deploymentStatus = .deploying
                deployedProject.deploymentError = nil
                try? modelContext.save()
            }

            do {
                // Extract subdomain from production domain
                let subdomain = productionDomain.replacingOccurrences(of: ".\(dnsZoneName)", with: "")
                let subdomainToUse = subdomain == dnsZoneName ? "" : subdomain

                // Reconstruct DNS zone
                let zone = DNSZone(
                    name: dnsZoneName,
                    id: dnsZoneID,
                    integration: dnsIntegration
                )

                // Re-run deployment using resumed flow
                try await resumeProjectDeployment(
                    deployedProject: deployedProject,
                    project: linkedProject,
                    server: server,
                    domain: zone,
                    subdomain: subdomainToUse
                )

                // Clean up task tracking
                await MainActor.run {
                    deploymentTasks[deployedProject.id] = nil
                }
            } catch {
                // Mark as failed
                await MainActor.run {
                    deployedProject.deploymentStatus = .failed
                    deployedProject.deploymentError = error.localizedDescription
                    try? modelContext.save()
                    deploymentTasks[deployedProject.id] = nil
                }
            }
        }

        deploymentTasks[deployedProject.id] = task
    }

    private func resumeProjectDeployment(
        deployedProject: DeployedProject,
        project: LocalProject?,
        server: Server,
        domain: DNSZone,
        subdomain: String
    ) async throws {
        isDeploying = true
        defer {
            isDeploying = false
            currentStep = .idle
        }

        // 1. DNS record creation (idempotent)
        currentStep = .creatingDNSRecord
        try await createDNSRecord(
            deployedProject: deployedProject,
            server: server,
            domain: domain,
            subdomain: subdomain
        )

        // 2. Cloudflare Tunnel HTTP route (idempotent)
        if let tunnel = server.cloudflareTunnel,
           let tunnelID = tunnel.tunnelID,
           let fqdn = deployedProject.productionDomain {

            // Get integration from tunnel, or fallback to fetching Cloudflare integration
            let integration: Integration? = tunnel.integration ?? (try? fetchCloudflareIntegration())

            if let integration {
                if tunnel.integration == nil {
                    tunnel.integration = integration
                }

                guard let email = integration.credentials.email,
                      let apiKey = integration.credentials.globalAPIKey else {
                    throw CloudflareError.unauthorized
                }

                let accountID = try await cloudflareService.getAccountID(integration: integration)

                try await cloudflareService.addHTTPRouteToTunnel(
                    tunnelID: tunnelID,
                    hostname: fqdn,
                    localPort: 80,
                    accountID: accountID,
                    email: email,
                    apiKey: apiKey
                )
            }
        }

        // 3. Traefik DNS configuration (idempotent)
        if server.cloudflareTunnel == nil {
            let traefikIntegration = domain.integration

            let serverHasIntegration = server.traefikDNSIntegrations?.contains(where: {
                $0.id == traefikIntegration.id
            }) ?? false

            if !serverHasIntegration {
                currentStep = .configuringTraefik
                try await provisioningService.configureTraefikDNSProvider(
                    server: server,
                    integration: traefikIntegration
                )

                if server.traefikDNSIntegrations == nil {
                    server.traefikDNSIntegrations = []
                }
                server.traefikDNSIntegrations?.append(traefikIntegration)
            }

            deployedProject.traefikDNSIntegration = traefikIntegration

            // Update .env.production only if we have local project
            if let project = project {
                let projectURL = URL(fileURLWithPath: project.path)
                let providerName = traefikIntegration.type.rawValue.lowercased()
                try envFileService.addDNSProviderVariable(to: projectURL, provider: providerName)
            }
        }

        // 4. GitHub secrets (idempotent)
        if deployedProject.githubOwner != nil && deployedProject.githubRepo != nil {
            let descriptor = FetchDescriptor<Integration>(
                predicate: #Predicate { integration in
                    integration.typeRawValue == "github"
                }
            )

            if let githubIntegrations = try? modelContext.fetch(descriptor),
               let githubIntegration = githubIntegrations.first {
                currentStep = .configuringGitHub

                let envContent = try await githubSecretsService.configureDeploymentSecrets(
                    deployedProject: deployedProject,
                    project: project,
                    server: server,
                    integration: githubIntegration,
                    envFileService: envFileService
                )
                deployedProject.envProductionContent = envContent
            }
        }

        // Mark complete
        currentStep = .completed
        deployedProject.deploymentStatus = .deployed
        deployedProject.deploymentError = nil
        try modelContext.save()
    }

    // MARK: - Private

    private func getOrCreateDeployedProject(for project: LocalProject) -> DeployedProject {
        // Check if project is already linked to a DeployedProject
        if let existingSiteID = project.linkedDeployedProjectID,
           let existingSite = fetchDeployedProject(by: existingSiteID) {
            // Update name and git info from project
            existingSite.name = project.name
            existingSite.gitRemoteURL = project.gitRemoteURL
            existingSite.gitBranch = project.gitBranch
            return existingSite
        }

        // Create new DeployedProject
        let deployedProject = DeployedProject(
            name: project.name,
            gitRemoteURL: project.gitRemoteURL,
            gitBranch: project.gitBranch
        )
        modelContext.insert(deployedProject)

        // Link both ways
        project.linkedDeployedProjectID = deployedProject.id
        deployedProject.linkedLocalProjectID = project.id

        return deployedProject
    }

    private func fetchDeployedProject(by id: UUID) -> DeployedProject? {
        let descriptor = FetchDescriptor<DeployedProject>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func resolveLocalProject(for deployedProject: DeployedProject) -> LocalProject? {
        guard let projectID = deployedProject.linkedLocalProjectID else { return nil }
        let descriptor = FetchDescriptor<LocalProject>(
            predicate: #Predicate { $0.id == projectID }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func createDNSRecord(
        deployedProject: DeployedProject,
        server: Server,
        domain: DNSZone,
        subdomain: String
    ) async throws {
        let recordName = subdomain.isEmpty ? "@" : subdomain

        // If server behind Cloudflare tunnel
        if let tunnel = server.cloudflareTunnel {
            // CNAME to tunnel
            let cnameTarget = tunnel.tunnelCNAME  // "{tunnel-id}.cfargotunnel.com."

            // Cloudflare Tunnel requires proxying
            let proxied = true

            let record = try await dnsManager.createRecord(
                in: domain,
                type: "CNAME",
                name: recordName,
                content: cnameTarget,
                proxied: proxied
            )

            // Track created DNS record ID for safe deletion
            deployedProject.createdDNSRecordIDs.append(record.id)
        } else {
            // A record to server IP
            guard let serverIP = server.host, !serverIP.isEmpty else {
                throw DNSError.serverNotLinked
            }

            // For Cloudflare, proxy traffic through their CDN/protection
            let shouldProxy = domain.integration.type == .cloudflare ? true : nil

            let record = try await dnsManager.createRecord(
                in: domain,
                type: "A",
                name: recordName,
                content: serverIP,
                proxied: shouldProxy
            )

            // Track created DNS record ID for safe deletion
            deployedProject.createdDNSRecordIDs.append(record.id)
        }
    }

    private func cleanupExistingDomainConfiguration(
        deployedProject: DeployedProject,
        server: Server
    ) async {
        let oldDomain = deployedProject.productionDomain

        // 1. Delete old DNS records (uses centralized method)
        _ = await dnsManager.deleteProjectDNSRecords(for: deployedProject)
        deployedProject.createdDNSRecordIDs = []

        // 2. Remove old tunnel HTTP route if applicable
        if let oldDomain = oldDomain,
           let tunnel = server.cloudflareTunnel,
           let tunnelID = tunnel.tunnelID {

            // Get integration from tunnel, or fallback to fetching Cloudflare integration
            let integration: Integration?
            if let tunnelIntegration = tunnel.integration {
                integration = tunnelIntegration
            } else {
                integration = try? fetchCloudflareIntegration()
            }

            if let integration,
               let email = integration.credentials.email,
               let apiKey = integration.credentials.globalAPIKey,
               let accountID = try? await cloudflareService.getAccountID(integration: integration) {
                try? await cloudflareService.removeHTTPRouteFromTunnel(
                    tunnelID: tunnelID,
                    hostname: oldDomain,
                    accountID: accountID,
                    email: email,
                    apiKey: apiKey
                )
            }
        }
    }

    /// Builds backup configuration for the given integration (Cloudflare R2, Scaleway, Dropbox)
    /// Returns nil for unsupported integration types
    private func buildBackupConfig(
        integration: Integration,
        projectSlug: String
    ) async throws -> EnvFileService.BackupConfig? {
        let bucketName = "fadogen-backups"

        switch integration.type {
        case .cloudflare:
            let accountId = try await configureCloudflareR2Bucket(integration: integration, bucketName: bucketName)
            return envFileService.cloudflareBackupConfig(
                integration: integration,
                accountId: accountId,
                projectSlug: projectSlug
            )

        case .scaleway:
            try await configureScalewayBucket(integration: integration, bucketName: bucketName)
            return envFileService.scalewayBackupConfig(
                integration: integration,
                projectSlug: projectSlug
            )

        case .dropbox:
            return envFileService.dropboxBackupConfig(
                integration: integration,
                projectSlug: projectSlug
            )

        default:
            return nil
        }
    }

    private func configureCloudflareR2Bucket(integration: Integration, bucketName: String) async throws -> String {
        guard let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey else {
            throw CloudflareError.unauthorized
        }

        let accountId = try await cloudflareService.getAccountID(integration: integration)

        let existingBuckets = try await cloudflareService.listR2Buckets(
            accountId: accountId,
            email: email,
            apiKey: apiKey
        )

        if !existingBuckets.contains(where: { $0.name == bucketName }) {
            _ = try await cloudflareService.createR2Bucket(
                accountId: accountId,
                name: bucketName,
                email: email,
                apiKey: apiKey
            )
        }

        return accountId
    }

    private func configureScalewayBucket(integration: Integration, bucketName: String) async throws {
        guard let accessKey = integration.credentials.accessKey,
              let secretKey = integration.credentials.secretKey,
              let regionRaw = integration.credentials.scalewayRegion,
              let region = ScalewayRegion(rawValue: regionRaw) else {
            throw ScalewayError.invalidCredentials
        }

        let bucketExists = try await scalewayService.bucketExists(
            name: bucketName,
            accessKey: accessKey,
            secretKey: secretKey,
            region: region
        )

        if !bucketExists {
            try await scalewayService.createBucket(
                name: bucketName,
                accessKey: accessKey,
                secretKey: secretKey,
                region: region
            )
        }
    }

    /// Fetch the first Cloudflare integration from the database
    /// Used as fallback when tunnel.integration is nil (legacy tunnels)
    private func fetchCloudflareIntegration() throws -> Integration? {
        let cloudflareRawValue = IntegrationType.cloudflare.rawValue
        let descriptor = FetchDescriptor<Integration>(
            predicate: #Predicate { integration in
                integration.typeRawValue == cloudflareRawValue
            }
        )
        return try modelContext.fetch(descriptor).first
    }

}
