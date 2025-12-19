import Foundation

// MARK: - Server Configuration

@preconcurrency protocol ServerRegion: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var slug: String { get }
}

@preconcurrency protocol ServerSize: Identifiable {
    var id: String { get }
    var slug: String { get }
    var displayName: String { get }
    var specs: ServerSpecs { get }
    var priceMonthly: Double { get }

    func isAvailableInRegion(_ regionSlug: String) -> Bool
    func displayNameForRegion(_ regionSlug: String) -> String
}

extension ServerSize {
    func displayNameForRegion(_ regionSlug: String) -> String {
        displayName
    }
}

struct ServerSpecs: Hashable, Sendable {
    let vcpus: Int
    let memoryMB: Int
    let diskGB: Int

    var memoryFormatted: String {
        "\(memoryMB / 1024) GB"
    }

    var diskFormatted: String {
        "\(diskGB) GB"
    }
}

// MARK: - Response Types

struct ServerRegionList: @unchecked Sendable {
    let regions: [any ServerRegion]
}

struct ServerSizeList: @unchecked Sendable {
    let sizes: [any ServerSize]
}

struct ProviderServerInfo: Sendable {
    let providerID: String
    let status: ServerProvisioningStatus
    let publicIPv4: String?
}

enum ServerProvisioningStatus: String, Sendable {
    case pending = "new"
    case active = "active"
    case error = "error"
    case off = "off"
}

// MARK: - Credentials

enum ProviderCredentials: Sendable {
    case bearerToken(String)
    case apiKeyAndSecret(key: String, secret: String)
    case emailAndGlobalKey(email: String, key: String)

    static func retrieve(for integration: Integration) -> ProviderCredentials? {
        // VPS providers (DigitalOcean, Hetzner, Vultr, Linode, Bunny) use Bearer token authentication
        guard let token = integration.credentials.token, !token.isEmpty else {
            return nil
        }
        return .bearerToken(token)
    }
}

// MARK: - Protocol

protocol CloudProviderService: Sendable {

    // MARK: Configuration

    func listRegions(credentials: ProviderCredentials) async throws -> ServerRegionList
    func listSizes(credentials: ProviderCredentials) async throws -> ServerSizeList
    func getLatestDebianImage(credentials: ProviderCredentials) async throws -> String

    // MARK: Server Lifecycle

    func createServer(
        name: String,
        region: any ServerRegion,
        size: any ServerSize,
        image: String,
        sshKeyID: String,
        credentials: ProviderCredentials
    ) async throws -> ProviderServerInfo

    func getServer(
        serverID: String,
        credentials: ProviderCredentials
    ) async throws -> ProviderServerInfo

    func waitForServerActive(
        serverID: String,
        credentials: ProviderCredentials,
        maxWaitTime: TimeInterval,
        logCallback: @Sendable (String) -> Void
    ) async throws -> ProviderServerInfo

    func deleteServer(
        serverID: String,
        credentials: ProviderCredentials
    ) async throws

    // MARK: SSH Keys

    func uploadSSHKey(
        name: String,
        publicKey: String,
        credentials: ProviderCredentials
    ) async throws -> String  // Returns key ID
}

// MARK: - Errors

enum CloudProviderError: LocalizedError {
    case invalidCredentials
    case invalidParameters
    case unsupportedProvider(String)
    case serverCreationFailed(String)
    case serverNotFound(String)
    case timeout(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return String(localized: "Invalid or missing credentials")
        case .invalidParameters:
            return String(localized: "Invalid parameters provided")
        case .unsupportedProvider(let provider):
            return String(localized: "Provider '\(provider)' is not supported for server creation")
        case .serverCreationFailed(let reason):
            return String(localized: "Server creation failed: \(reason)")
        case .serverNotFound(let id):
            return String(localized: "Server not found: \(id)")
        case .timeout(let message):
            return String(localized: "Operation timed out: \(message)")
        case .networkError(let message):
            return String(localized: "Network error: \(message)")
        }
    }
}
