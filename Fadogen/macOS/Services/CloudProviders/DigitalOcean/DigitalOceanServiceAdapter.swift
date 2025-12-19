import Foundation

struct DigitalOceanServiceAdapter: CloudProviderService {

    private let service = DigitalOceanService()

    // MARK: - Configuration Fetching

    func listRegions(credentials: ProviderCredentials) async throws -> ServerRegionList {
        let token = try extractBearerToken(from: credentials)
        let regions = try await service.listRegions(apiToken: token)
        return ServerRegionList(regions: regions)
    }

    func listSizes(credentials: ProviderCredentials) async throws -> ServerSizeList {
        let token = try extractBearerToken(from: credentials)
        let sizes = try await service.listSizes(apiToken: token)
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

        guard let doRegion = region as? DORegion else {
            throw CloudProviderError.invalidParameters
        }
        guard let doSize = size as? DOSize else {
            throw CloudProviderError.invalidParameters
        }
        guard let keyID = Int(sshKeyID) else {
            throw CloudProviderError.invalidParameters
        }

        let droplet = try await service.createDroplet(
            name: name,
            region: doRegion.slug,
            size: doSize.slug,
            image: image,
            sshKeyIDs: [keyID],
            apiToken: token
        )

        return convertToProviderServerInfo(droplet)
    }

    func getServer(
        serverID: String,
        credentials: ProviderCredentials
    ) async throws -> ProviderServerInfo {
        let token = try extractBearerToken(from: credentials)

        guard let dropletID = Int(serverID) else {
            throw CloudProviderError.invalidParameters
        }

        let droplet = try await service.getDroplet(dropletID: dropletID, apiToken: token)
        return convertToProviderServerInfo(droplet)
    }

    func waitForServerActive(
        serverID: String,
        credentials: ProviderCredentials,
        maxWaitTime: TimeInterval,
        logCallback: @Sendable (String) -> Void
    ) async throws -> ProviderServerInfo {
        let token = try extractBearerToken(from: credentials)

        guard let dropletID = Int(serverID) else {
            throw CloudProviderError.invalidParameters
        }

        let maxAttempts = Int(maxWaitTime / 5)  // 5 seconds between attempts
        let delaySeconds: UInt64 = 5

        for attempt in 1...maxAttempts {
            let droplet = try await service.getDroplet(dropletID: dropletID, apiToken: token)

            if droplet.isActive, droplet.publicIPv4 != nil {
                logCallback("Droplet \(dropletID) is active with IP: \(droplet.publicIPv4!)")
                return convertToProviderServerInfo(droplet)
            }

            logCallback("Attempt \(attempt)/\(maxAttempts): Droplet status is '\(droplet.status)', waiting...")
            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }

        throw CloudProviderError.timeout(String(localized: "Droplet did not become active within \(maxWaitTime) seconds"))
    }

    func deleteServer(
        serverID: String,
        credentials: ProviderCredentials
    ) async throws {
        let token = try extractBearerToken(from: credentials)

        guard let dropletID = Int(serverID) else {
            throw CloudProviderError.invalidParameters
        }

        try await service.deleteDroplet(dropletID: dropletID, apiToken: token)
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

    private func convertToProviderServerInfo(_ droplet: DODroplet) -> ProviderServerInfo {
        let status: ServerProvisioningStatus
        switch droplet.status {
        case "active":
            status = .active
        case "new":
            status = .pending
        case "off":
            status = .off
        default:
            status = .error
        }

        return ProviderServerInfo(
            providerID: String(droplet.id),
            status: status,
            publicIPv4: droplet.publicIPv4
        )
    }
}
