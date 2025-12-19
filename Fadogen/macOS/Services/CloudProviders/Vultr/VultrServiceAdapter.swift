import Foundation

struct VultrServiceAdapter: CloudProviderService {

    private let service = VultrService()

    // MARK: - Configuration Fetching

    func listRegions(credentials: ProviderCredentials) async throws -> ServerRegionList {
        let token = try extractBearerToken(from: credentials)
        let regions = try await service.listRegions(apiToken: token)
        return ServerRegionList(regions: regions)
    }

    func listSizes(credentials: ProviderCredentials) async throws -> ServerSizeList {
        let token = try extractBearerToken(from: credentials)
        let plans = try await service.listPlans(apiToken: token)
        return ServerSizeList(sizes: plans)
    }

    func getLatestDebianImage(credentials: ProviderCredentials) async throws -> String {
        let token = try extractBearerToken(from: credentials)
        let osID = try await service.getLatestDebianOS(apiToken: token)
        return String(osID)
    }

    // MARK: - Server Lifecycle Management

    func createServer(
        name: String,
        region: any ServerRegion,
        size: any ServerSize,
        image: String,
        sshKeyID: String,
        credentials: ProviderCredentials
    ) async throws -> ProviderServerInfo {
        let token = try extractBearerToken(from: credentials)

        guard let vultrRegion = region as? VultrRegion else {
            throw CloudProviderError.invalidParameters
        }
        guard let vultrPlan = size as? VultrPlan else {
            throw CloudProviderError.invalidParameters
        }
        guard let osID = Int(image) else {
            throw CloudProviderError.invalidParameters
        }

        // Vultr uses SSH key IDs (not public keys directly like Linode)
        let instance = try await service.createInstance(
            label: name,
            region: vultrRegion.regionId,
            plan: vultrPlan.planId,
            osID: osID,
            sshKeyIDs: [sshKeyID],
            apiToken: token
        )

        return convertToProviderServerInfo(instance)
    }

    func getServer(
        serverID: String,
        credentials: ProviderCredentials
    ) async throws -> ProviderServerInfo {
        let token = try extractBearerToken(from: credentials)

        let instance = try await service.getInstance(instanceID: serverID, apiToken: token)
        return convertToProviderServerInfo(instance)
    }

    func waitForServerActive(
        serverID: String,
        credentials: ProviderCredentials,
        maxWaitTime: TimeInterval,
        logCallback: @Sendable (String) -> Void
    ) async throws -> ProviderServerInfo {
        let token = try extractBearerToken(from: credentials)

        let instance = try await service.waitForInstanceActive(
            instanceID: serverID,
            apiToken: token,
            maxWaitTime: maxWaitTime,
            logCallback: logCallback
        )

        return convertToProviderServerInfo(instance)
    }

    func deleteServer(
        serverID: String,
        credentials: ProviderCredentials
    ) async throws {
        let token = try extractBearerToken(from: credentials)

        try await service.deleteInstance(instanceID: serverID, apiToken: token)
    }

    // MARK: - SSH Key Management

    func uploadSSHKey(
        name: String,
        publicKey: String,
        credentials: ProviderCredentials
    ) async throws -> String {
        let token = try extractBearerToken(from: credentials)

        // Vultr returns the SSH key ID (unlike Linode which uses public key directly)
        let sshKeyID = try await service.uploadSSHKey(
            name: name,
            sshKey: publicKey,
            apiToken: token
        )

        return sshKeyID
    }

    // MARK: - Private

    private func extractBearerToken(from credentials: ProviderCredentials) throws -> String {
        guard case .bearerToken(let token) = credentials else {
            throw CloudProviderError.invalidCredentials
        }
        return token
    }

    private func convertToProviderServerInfo(_ instance: VultrInstance) -> ProviderServerInfo {
        let status: ServerProvisioningStatus
        switch instance.status {
        case "active":
            // Check power status too
            status = instance.powerStatus == "running" ? .active : .off
        case "pending", "installing", "resizing":
            status = .pending
        case "stopped", "suspended":
            status = .off
        default:
            status = .error
        }

        return ProviderServerInfo(
            providerID: instance.id,
            status: status,
            publicIPv4: instance.publicIPv4
        )
    }
}
