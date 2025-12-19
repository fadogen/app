import Foundation

struct LinodeServiceAdapter: CloudProviderService {

    private let service = LinodeService()

    // MARK: - Configuration Fetching

    func listRegions(credentials: ProviderCredentials) async throws -> ServerRegionList {
        let token = try extractBearerToken(from: credentials)
        let regions = try await service.listRegions(apiToken: token)
        return ServerRegionList(regions: regions)
    }

    func listSizes(credentials: ProviderCredentials) async throws -> ServerSizeList {
        let token = try extractBearerToken(from: credentials)
        let types = try await service.listTypes(apiToken: token)
        return ServerSizeList(sizes: types)
    }

    func getLatestDebianImage(credentials: ProviderCredentials) async throws -> String {
        let token = try extractBearerToken(from: credentials)
        return try await service.getLatestDebianImage(apiToken: token)
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

        guard let linodeRegion = region as? LinodeRegion else {
            throw CloudProviderError.invalidParameters
        }
        guard let linodeType = size as? LinodeType else {
            throw CloudProviderError.invalidParameters
        }

        // Linode uses authorized_keys directly, not SSH key IDs
        // The sshKeyID passed here is actually the public key content
        // (handled by the provisioning service which passes the public key)
        let instance = try await service.createInstance(
            label: name,
            region: linodeRegion.id,
            type: linodeType.id,
            image: image,
            authorizedKeys: [sshKeyID],
            apiToken: token
        )

        return convertToProviderServerInfo(instance)
    }

    func getServer(
        serverID: String,
        credentials: ProviderCredentials
    ) async throws -> ProviderServerInfo {
        let token = try extractBearerToken(from: credentials)

        guard let instanceID = Int(serverID) else {
            throw CloudProviderError.invalidParameters
        }

        let instance = try await service.getInstance(instanceID: instanceID, apiToken: token)
        return convertToProviderServerInfo(instance)
    }

    func waitForServerActive(
        serverID: String,
        credentials: ProviderCredentials,
        maxWaitTime: TimeInterval,
        logCallback: @Sendable (String) -> Void
    ) async throws -> ProviderServerInfo {
        let token = try extractBearerToken(from: credentials)

        guard let instanceID = Int(serverID) else {
            throw CloudProviderError.invalidParameters
        }

        let instance = try await service.waitForInstanceRunning(
            instanceID: instanceID,
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

        guard let instanceID = Int(serverID) else {
            throw CloudProviderError.invalidParameters
        }

        try await service.deleteInstance(instanceID: instanceID, apiToken: token)
    }

    // MARK: - SSH Key Management

    func uploadSSHKey(
        name: String,
        publicKey: String,
        credentials: ProviderCredentials
    ) async throws -> String {
        // Linode can accept SSH keys directly in authorized_keys during instance creation
        // But we also support uploading to profile for reuse
        let token = try extractBearerToken(from: credentials)

        _ = try await service.uploadSSHKey(
            label: name,
            sshKey: publicKey,
            apiToken: token
        )

        // Return the public key itself as the "ID" since Linode uses authorized_keys
        // The caller will pass this to createServer
        return publicKey
    }

    // MARK: - Private

    private func extractBearerToken(from credentials: ProviderCredentials) throws -> String {
        guard case .bearerToken(let token) = credentials else {
            throw CloudProviderError.invalidCredentials
        }
        return token
    }

    private func convertToProviderServerInfo(_ instance: LinodeInstance) -> ProviderServerInfo {
        let status: ServerProvisioningStatus
        switch instance.status {
        case "running":
            status = .active
        case "provisioning", "booting", "rebooting", "rebuilding", "migrating", "resizing":
            status = .pending
        case "offline", "shutting_down":
            status = .off
        default:
            status = .error
        }

        return ProviderServerInfo(
            providerID: String(instance.id),
            status: status,
            publicIPv4: instance.publicIPv4
        )
    }
}
