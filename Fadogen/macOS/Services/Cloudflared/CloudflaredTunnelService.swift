import Foundation
import Subprocess
import System
import OSLog
import SwiftData

/// Manages the local cloudflared daemon for sharing projects publicly via Cloudflare Tunnel
@Observable
final class CloudflaredTunnelService {
    // MARK: - State

    private(set) var runningProcess: Task<Void, Never>?
    private(set) var processIdentifier: ProcessIdentifier?
    private(set) var isStarting = false
    private(set) var isStopping = false
    private(set) var startupError: String?

    var isRunning: Bool {
        guard let pid = processIdentifier else { return false }
        let exists = kill(pid_t(pid.value), 0) == 0
        if !exists {
            processIdentifier = nil
        }
        return exists
    }

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "cloudflared")
    private let modelContext: ModelContext
    let cloudflareService: CloudflareService
    private let caddyConfig: CaddyConfigService
    weak var processCleanup: ProcessCleanupService?
    weak var quickTunnelService: QuickTunnelService?

    // MARK: - Initialization

    init(modelContext: ModelContext, caddyConfig: CaddyConfigService, cloudflareService: CloudflareService = CloudflareService()) {
        self.modelContext = modelContext
        self.caddyConfig = caddyConfig
        self.cloudflareService = cloudflareService
    }

    // MARK: - Configuration

    func getOrCreateConfig() throws -> LocalTunnelConfig {
        let descriptor = FetchDescriptor<LocalTunnelConfig>(
            predicate: #Predicate { $0.uniqueIdentifier == "local-tunnel" }
        )

        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }

        let config = LocalTunnelConfig()
        modelContext.insert(config)
        try modelContext.save()
        return config
    }

    // MARK: - Routes

    func getActiveRoutes() throws -> [LocalTunnelRoute] {
        let descriptor = FetchDescriptor<LocalTunnelRoute>(
            predicate: #Predicate { $0.isActive == true }
        )
        return try modelContext.fetch(descriptor)
    }

    func getRoute(for projectID: UUID) throws -> LocalTunnelRoute? {
        let descriptor = FetchDescriptor<LocalTunnelRoute>(
            predicate: #Predicate { $0.projectID == projectID }
        )
        return try modelContext.fetch(descriptor).first
    }

    // MARK: - Tunnel Lifecycle

    func start(integration: Integration) async throws {
        guard runningProcess == nil else {
            logger.info("Cloudflared already running")
            return
        }

        guard !isStarting else {
            throw CloudflaredError.operationInProgress
        }

        isStarting = true
        defer { isStarting = false }

        logger.info("Starting cloudflared tunnel")
        startupError = nil

        // Get or create tunnel config
        let config = try getOrCreateConfig()

        // Ensure tunnel exists
        guard let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey else {
            throw CloudflaredError.missingCredentials
        }

        let accountID: String
        if let existingAccountID = config.accountID {
            accountID = existingAccountID
        } else {
            accountID = try await cloudflareService.getAccountID(integration: integration)
            config.accountID = accountID
            try modelContext.save()
        }

        // Get or create tunnel
        let tunnelID: String
        if let existingTunnelID = config.tunnelID {
            tunnelID = existingTunnelID
        } else {
            // Try to find existing tunnel or create new one
            // (handles case where tunnel exists from another Mac)
            let tunnel = try await cloudflareService.getOrCreateTunnel(
                name: config.tunnelName,
                accountID: accountID,
                email: email,
                apiKey: apiKey
            )
            config.tunnelID = tunnel.id
            try modelContext.save()
            tunnelID = tunnel.id
            logger.info("Using tunnel: \(tunnelID)")
        }

        // Get tunnel token
        let token = try await cloudflareService.getTunnelToken(
            tunnelID: tunnelID,
            accountID: accountID,
            email: email,
            apiKey: apiKey
        )

        // Verify cloudflared binary exists
        let cloudflaredPath = FadogenPaths.cloudflaredPath
        guard FileManager.default.fileExists(atPath: cloudflaredPath.path) else {
            let errorMsg = "cloudflared binary not found"
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw CloudflaredError.binaryNotFound
        }

        // Launch subprocess
        let task = Task {
            var startupErrorLines: [String] = []

            do {
                let result = try await run(
                    .path(FilePath(cloudflaredPath.path)),
                    arguments: ["tunnel", "run", "--token", token],
                    environment: .inherit,
                    preferredBufferSize: 1
                ) { execution, _, _, standardError in
                    self.processIdentifier = execution.processIdentifier

                    let pid = Int32(execution.processIdentifier.value)
                    self.processCleanup?.writePIDFile(identifier: "cloudflared", pid: pid)

                    var lineCount = 0
                    for try await line in standardError.lines() {
                        self.logger.debug("cloudflared: \(line)")

                        if lineCount < 10 && line.contains("ERR") {
                            startupErrorLines.append(line)
                            lineCount += 1
                        }
                    }
                }

                if !result.terminationStatus.isSuccess && !Task.isCancelled {
                    let errorMsg = if !startupErrorLines.isEmpty {
                        startupErrorLines.joined(separator: "\n")
                    } else {
                        "cloudflared exited with status: \(result.terminationStatus)"
                    }
                    self.logger.error("cloudflared failed: \(errorMsg)")
                    self.startupError = errorMsg
                }
            } catch {
                if !Task.isCancelled {
                    let errorMsg = error.localizedDescription
                    self.logger.error("cloudflared error: \(errorMsg)")
                    self.startupError = errorMsg
                }
            }

            runningProcess = nil
        }

        runningProcess = task

        // Wait a bit for connection to establish
        try await Task.sleep(for: .seconds(2))

        if startupError != nil {
            throw CloudflaredError.startupFailed(startupError!)
        }

        logger.info("cloudflared started successfully")
    }

    func stop() async {
        guard let task = runningProcess else {
            logger.info("cloudflared not running")
            return
        }

        guard !isStopping else {
            logger.warning("Stop operation already in progress")
            return
        }

        isStopping = true
        defer { isStopping = false }

        logger.info("Stopping cloudflared")

        // Kill the process
        if let pid = processIdentifier {
            kill(pid_t(pid.value), SIGTERM)
        }

        task.cancel()
        runningProcess = nil
        processIdentifier = nil

        processCleanup?.removePIDFile(identifier: "cloudflared")

        logger.info("cloudflared stopped")
    }

    // MARK: - Route Management

    /// Add a route for a project (creates ingress rule + DNS record)
    func addRoute(
        project: LocalProject,
        zone: CloudflareZone,
        subdomain: String,
        integration: Integration
    ) async throws -> LocalTunnelRoute {
        guard let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey else {
            throw CloudflaredError.missingCredentials
        }

        let config = try getOrCreateConfig()

        guard let tunnelID = config.tunnelID,
              let accountID = config.accountID else {
            throw CloudflaredError.tunnelNotConfigured
        }

        let localURL = project.localURL
        guard !localURL.isEmpty else {
            throw CloudflaredError.projectHasNoLocalURL
        }

        // Stop any active quick tunnel for this project (mutually exclusive)
        if quickTunnelService?.isActive(for: project.id) == true {
            logger.info("Stopping quick tunnel before adding permanent route")
            await quickTunnelService?.stop(for: project.id)
        }

        let hostname = "\(subdomain).\(zone.name)"

        // Add ingress rule to tunnel configuration
        try await cloudflareService.addHTTPRouteToTunnel(
            tunnelID: tunnelID,
            hostname: hostname,
            localPort: 443,  // Will be overridden by service URL
            accountID: accountID,
            email: email,
            apiKey: apiKey
        )

        // Update ingress with proper origin config (HTTPS with CA)
        try await updateIngressWithOriginConfig(
            tunnelID: tunnelID,
            hostname: hostname,
            serviceURL: localURL,
            accountID: accountID,
            email: email,
            apiKey: apiKey
        )

        // Create DNS CNAME record
        let dnsRecord = try await cloudflareService.createDNSRecord(
            zoneID: zone.id,
            type: "CNAME",
            name: subdomain,
            content: config.cnameTarget!,
            proxied: true,
            email: email,
            apiKey: apiKey
        )

        // Wait for DNS propagation (prevents browser negative caching)
        await DNSHelper.waitForDNS(hostname: hostname)

        // Save route
        let route = LocalTunnelRoute(
            projectID: project.id,
            hostname: hostname,
            zoneID: zone.id,
            zoneName: zone.name,
            subdomain: subdomain,
            dnsRecordID: dnsRecord.id,
            isActive: true
        )
        modelContext.insert(route)
        try modelContext.save()

        // Update Caddy config to include the public hostname
        caddyConfig.reconcile(project: project)

        logger.info("Added route: \(hostname) -> \(localURL)")

        // Auto-start tunnel if not running
        if !isRunning {
            logger.info("Auto-starting tunnel after adding route")
            try await start(integration: integration)
        }

        return route
    }

    /// Remove a route for a project
    /// Handles gracefully cases where remote resources were already deleted
    func removeRoute(for project: LocalProject, integration: Integration) async throws {
        guard let route = try getRoute(for: project.id) else {
            return
        }

        guard let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey else {
            throw CloudflaredError.missingCredentials
        }

        // Try to remove remote resources, but don't fail if they're already gone
        if let config = try? getOrCreateConfig(),
           let tunnelID = config.tunnelID,
           let accountID = config.accountID {
            // Remove ingress rule (ignore errors - tunnel may be deleted)
            do {
                try await cloudflareService.removeHTTPRouteFromTunnel(
                    tunnelID: tunnelID,
                    hostname: route.hostname,
                    accountID: accountID,
                    email: email,
                    apiKey: apiKey
                )
            } catch {
                logger.warning("Could not remove ingress rule (may already be deleted): \(error.localizedDescription)")
            }
        }

        // Delete DNS record (ignore "not found" errors)
        if let dnsRecordID = route.dnsRecordID {
            do {
                try await cloudflareService.deleteDNSRecord(
                    recordID: dnsRecordID,
                    zoneID: route.zoneID,
                    email: email,
                    apiKey: apiKey
                )
            } catch {
                logger.warning("Could not delete DNS record (may already be deleted): \(error.localizedDescription)")
            }
        }

        // Always delete route from database
        modelContext.delete(route)
        try modelContext.save()

        // Update Caddy config to remove the public hostname
        caddyConfig.reconcile(project: project)

        logger.info("Removed route: \(route.hostname)")

        // Auto-stop tunnel if no active routes remain
        let remainingRoutes = try getActiveRoutes()
        if remainingRoutes.isEmpty && isRunning {
            logger.info("No active routes remaining, auto-stopping tunnel")
            await stop()
        }
    }

    // MARK: - Auto-Start

    /// Start tunnel if any active routes exist (called on app launch)
    func startIfRoutesExist(integration: Integration?) async {
        logger.info("Checking for active routes to auto-start tunnel...")

        do {
            let activeRoutes = try getActiveRoutes()

            if !activeRoutes.isEmpty, let integration = integration {
                logger.info("Found \(activeRoutes.count) active route(s), starting tunnel")
                try await start(integration: integration)
            } else if activeRoutes.isEmpty {
                logger.info("No active routes, tunnel will remain stopped")
            } else {
                logger.info("Active routes exist but no Cloudflare integration configured")
            }
        } catch {
            logger.error("Failed to auto-start cloudflared: \(error.localizedDescription)")
        }
    }

    // MARK: - Orphan Cleanup

    /// Removes tunnel routes whose associated LocalProject no longer exists.
    /// Called automatically when projects are deleted and at app launch.
    /// DNS cleanup errors are logged but don't prevent local route deletion.
    func cleanupOrphanedRoutes() async {
        let allRoutes: [LocalTunnelRoute]
        do {
            allRoutes = try modelContext.fetch(FetchDescriptor<LocalTunnelRoute>())
        } catch {
            logger.warning("Failed to fetch tunnel routes for cleanup: \(error.localizedDescription)")
            return
        }

        guard !allRoutes.isEmpty else { return }

        let allProjectIDs: Set<UUID>
        do {
            let projects = try modelContext.fetch(FetchDescriptor<LocalProject>())
            allProjectIDs = Set(projects.map { $0.id })
        } catch {
            logger.warning("Failed to fetch projects for cleanup: \(error.localizedDescription)")
            return
        }

        let orphanedRoutes = allRoutes.filter { !allProjectIDs.contains($0.projectID) }

        guard !orphanedRoutes.isEmpty else { return }

        logger.info("Found \(orphanedRoutes.count) orphaned tunnel route(s) to cleanup")

        let integration = fetchCloudflareIntegration()

        for route in orphanedRoutes {
            await cleanupOrphanedRoute(route, integration: integration)
        }
    }

    /// Cleans up a single orphaned route: removes DNS record (best-effort) and deletes local route (always)
    private func cleanupOrphanedRoute(_ route: LocalTunnelRoute, integration: Integration?) async {
        if let integration,
           let email = integration.credentials.email,
           let apiKey = integration.credentials.globalAPIKey {

            if let config = try? getOrCreateConfig(),
               let tunnelID = config.tunnelID,
               let accountID = config.accountID {
                do {
                    try await cloudflareService.removeHTTPRouteFromTunnel(
                        tunnelID: tunnelID,
                        hostname: route.hostname,
                        accountID: accountID,
                        email: email,
                        apiKey: apiKey
                    )
                } catch {
                    logger.warning("Could not remove ingress rule for orphaned route \(route.hostname): \(error.localizedDescription)")
                }
            }

            if let dnsRecordID = route.dnsRecordID {
                do {
                    try await cloudflareService.deleteDNSRecord(
                        recordID: dnsRecordID,
                        zoneID: route.zoneID,
                        email: email,
                        apiKey: apiKey
                    )
                } catch {
                    logger.warning("Could not delete DNS record for orphaned route \(route.hostname): \(error.localizedDescription)")
                }
            }
        } else {
            logger.info("No Cloudflare integration available, skipping remote cleanup for \(route.hostname)")
        }

        modelContext.delete(route)
        try? modelContext.save()
        logger.info("Deleted orphaned tunnel route: \(route.hostname)")
    }

    private func fetchCloudflareIntegration() -> Integration? {
        let descriptor = FetchDescriptor<Integration>(
            predicate: #Predicate { $0.typeRawValue == "cloudflare" }
        )
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Private

    /// Update tunnel ingress configuration with proper origin settings for HTTPS
    private func updateIngressWithOriginConfig(
        tunnelID: String,
        hostname: String,
        serviceURL: String,
        accountID: String,
        email: String,
        apiKey: String
    ) async throws {
        // Get current configuration
        let currentConfig = try await cloudflareService.getTunnelConfiguration(
            tunnelID: tunnelID,
            accountID: accountID,
            email: email,
            apiKey: apiKey
        )

        // Build updated ingress with origin request config
        var newIngress: [[String: Any]] = []

        for rule in currentConfig.ingress {
            var ruleDict: [String: Any] = ["service": rule.service]

            if let ruleHostname = rule.hostname {
                ruleDict["hostname"] = ruleHostname

                // Add origin config for HTTPS origins
                if ruleHostname == hostname {
                    ruleDict["service"] = serviceURL

                    // Extract hostname from service URL for TLS SNI
                    let originHost = URL(string: serviceURL)?.host ?? hostname

                    ruleDict["originRequest"] = [
                        // Skip TLS verification for local Caddy (simpler than caPool with spaces in path)
                        "noTLSVerify": true,
                        // SNI for TLS handshake (use local hostname for certificate matching)
                        "originServerName": originHost
                        // NOTE: We do NOT set httpHostHeader here.
                        // Instead, Caddy is configured to accept both local and public hostnames.
                        // This allows the application to see the correct public Host header
                        // and generate proper URLs (e.g., for redirects).
                    ]
                }
            }

            newIngress.append(ruleDict)
        }

        // Update configuration via API
        let ingressConfig: [String: Any] = [
            "config": ["ingress": newIngress]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: ingressConfig) else {
            throw CloudflaredError.invalidConfiguration
        }

        let provider = CloudflareAPIProvider(email: email, apiKey: apiKey)
        let client = BaseDNSAPIClient(provider: provider)
        let endpoint = "accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations"

        let response: CloudflareAPIResponse<EmptyResult> = try await client.request(
            endpoint,
            method: "PUT",
            body: bodyData
        )

        guard response.success else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }
    }
}

// MARK: - Errors

enum CloudflaredError: LocalizedError {
    case operationInProgress
    case missingCredentials
    case tunnelNotConfigured
    case projectHasNoLocalURL
    case binaryNotFound
    case startupFailed(String)
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another operation is in progress"
        case .missingCredentials:
            return "Missing Cloudflare credentials"
        case .tunnelNotConfigured:
            return "Tunnel not configured. Please set up the tunnel first."
        case .projectHasNoLocalURL:
            return "Project has no local URL configured"
        case .binaryNotFound:
            return "cloudflared binary not found in app bundle"
        case .startupFailed(let details):
            return details
        case .invalidConfiguration:
            return "Invalid tunnel configuration"
        }
    }
}
