import Foundation

struct HetznerServiceAdapter: CloudProviderService {

    private let service = HetznerService()

    // MARK: - Configuration Fetching

    func listRegions(credentials: ProviderCredentials) async throws -> ServerRegionList {
        let token = try extractBearerToken(from: credentials)
        let regions = try await service.listLocations(apiToken: token)
        return ServerRegionList(regions: regions)
    }

    func listSizes(credentials: ProviderCredentials) async throws -> ServerSizeList {
        let token = try extractBearerToken(from: credentials)
        let sizes = try await service.listServerTypes(apiToken: token)
        return ServerSizeList(sizes: sizes)
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

        guard let hetznerLocation = region as? HetznerLocation else {
            throw CloudProviderError.invalidParameters
        }
        guard let hetznerServerType = size as? HetznerServerType else {
            throw CloudProviderError.invalidParameters
        }
        guard let keyID = Int(sshKeyID) else {
            throw CloudProviderError.invalidParameters
        }

        let server = try await service.createServer(
            name: name,
            location: hetznerLocation.name,
            serverType: hetznerServerType.name,
            image: image,
            sshKeyIDs: [keyID],
            apiToken: token
        )

        return convertToProviderServerInfo(server)
    }

    func getServer(
        serverID: String,
        credentials: ProviderCredentials
    ) async throws -> ProviderServerInfo {
        let token = try extractBearerToken(from: credentials)

        guard let serverIDInt = Int(serverID) else {
            throw CloudProviderError.invalidParameters
        }

        let server = try await service.getServer(serverID: serverIDInt, apiToken: token)
        return convertToProviderServerInfo(server)
    }

    func waitForServerActive(
        serverID: String,
        credentials: ProviderCredentials,
        maxWaitTime: TimeInterval,
        logCallback: @Sendable (String) -> Void
    ) async throws -> ProviderServerInfo {
        let token = try extractBearerToken(from: credentials)

        guard let serverIDInt = Int(serverID) else {
            throw CloudProviderError.invalidParameters
        }

        let maxAttempts = Int(maxWaitTime / 5)  // 5 seconds between attempts
        let delaySeconds: UInt64 = 5

        for attempt in 1...maxAttempts {
            let server = try await service.getServer(serverID: serverIDInt, apiToken: token)

            if server.isActive, server.publicIPv4 != nil {
                logCallback("Server \(serverID) is active with IP: \(server.publicIPv4!)")
                return convertToProviderServerInfo(server)
            }

            logCallback("Attempt \(attempt)/\(maxAttempts): Server status is '\(server.status)', waiting...")
            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }

        throw CloudProviderError.timeout(String(localized: "Server did not become active within \(maxWaitTime) seconds"))
    }

    func deleteServer(
        serverID: String,
        credentials: ProviderCredentials
    ) async throws {
        let token = try extractBearerToken(from: credentials)

        guard let serverIDInt = Int(serverID) else {
            throw CloudProviderError.invalidParameters
        }

        try await service.deleteServer(serverID: serverIDInt, apiToken: token)
    }

    // MARK: - SSH Key Management

    func uploadSSHKey(
        name: String,
        publicKey: String,
        credentials: ProviderCredentials
    ) async throws -> String {
        let token = try extractBearerToken(from: credentials)

        let sshKey = try await service.uploadSSHKey(
            name: name,
            publicKey: publicKey,
            apiToken: token
        )

        return String(sshKey.id)
    }

    // MARK: - Private

    private func extractBearerToken(from credentials: ProviderCredentials) throws -> String {
        guard case .bearerToken(let token) = credentials else {
            throw CloudProviderError.invalidCredentials
        }
        return token
    }

    private func convertToProviderServerInfo(_ server: HetznerServer) -> ProviderServerInfo {
        let status: ServerProvisioningStatus
        switch server.status {
        case "running":
            status = .active
        case "initializing", "starting":
            status = .pending
        case "off", "stopping":
            status = .off
        default:
            status = .error
        }

        return ProviderServerInfo(
            providerID: String(server.id),
            status: status,
            publicIPv4: server.publicIPv4
        )
    }
}
