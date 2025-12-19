import Foundation
import SwiftData

@Model nonisolated
final class Integration {
    // MARK: - Stored Properties

    var id: UUID = UUID()
    var typeRawValue: String = ""
    var capabilitiesRawValues: [String] = []

    // Store credentials directly (no JSON encoding)
    @Attribute(.allowsCloudEncryption)
    private var email: String? = nil

    @Attribute(.allowsCloudEncryption)
    private var globalAPIKey: String? = nil

    @Attribute(.allowsCloudEncryption)
    private var token: String? = nil

    @Attribute(.allowsCloudEncryption)
    private var apiKey: String? = nil

    @Attribute(.allowsCloudEncryption)
    private var accessKey: String? = nil

    @Attribute(.allowsCloudEncryption)
    private var secretKey: String? = nil

    @Attribute(.allowsCloudEncryption)
    private var r2AccessKeyId: String? = nil

    @Attribute(.allowsCloudEncryption)
    private var r2SecretAccessKey: String? = nil

    // Scaleway Object Storage
    private var scalewayRegion: String? = nil

    // Dropbox OAuth2
    @Attribute(.allowsCloudEncryption)
    private var dropboxAppKey: String? = nil

    @Attribute(.allowsCloudEncryption)
    private var dropboxAppSecret: String? = nil

    @Attribute(.allowsCloudEncryption)
    private var dropboxRefreshToken: String? = nil

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: - Relationships

    @Relationship(deleteRule: .cascade, inverse: \Server.integration)
    var servers: [Server]? = []

    @Relationship(deleteRule: .nullify, inverse: \CloudflareTunnel.integration)
    var tunnels: [CloudflareTunnel]? = []

    // Inverse-only relationships - access via deployedProject.dnsIntegration instead

    @Relationship(deleteRule: .nullify)
    var dnsZones: [DeployedProject]? = []

    @Relationship(deleteRule: .nullify)
    var traefikDNSZones: [DeployedProject]? = []

    @Relationship(deleteRule: .nullify)
    var traefikServers: [Server]? = []

    @Relationship(deleteRule: .nullify)
    var backupProjects: [DeployedProject]? = []

    // MARK: - Computed Properties

    var type: IntegrationType {
        get { IntegrationType(rawValue: typeRawValue) ?? .cloudflare }
        set {
            typeRawValue = newValue.rawValue
            updatedAt = Date()
        }
    }

    var capabilities: [IntegrationCapability] {
        get {
            capabilitiesRawValues.compactMap { IntegrationCapability(rawValue: $0) }
        }
        set {
            capabilitiesRawValues = newValue.map { $0.rawValue }
            updatedAt = Date()
        }
    }

    var credentials: IntegrationCredentials {
        get {
            IntegrationCredentials(
                email: email,
                globalAPIKey: globalAPIKey,
                token: token,
                apiKey: apiKey,
                accessKey: accessKey,
                secretKey: secretKey,
                r2AccessKeyId: r2AccessKeyId,
                r2SecretAccessKey: r2SecretAccessKey,
                scalewayRegion: scalewayRegion,
                dropboxAppKey: dropboxAppKey,
                dropboxAppSecret: dropboxAppSecret,
                dropboxRefreshToken: dropboxRefreshToken
            )
        }
        set {
            email = newValue.email
            globalAPIKey = newValue.globalAPIKey
            token = newValue.token
            apiKey = newValue.apiKey
            accessKey = newValue.accessKey
            secretKey = newValue.secretKey
            r2AccessKeyId = newValue.r2AccessKeyId
            r2SecretAccessKey = newValue.r2SecretAccessKey
            scalewayRegion = newValue.scalewayRegion
            dropboxAppKey = newValue.dropboxAppKey
            dropboxAppSecret = newValue.dropboxAppSecret
            dropboxRefreshToken = newValue.dropboxRefreshToken
            updatedAt = Date()
        }
    }

    // MARK: - Convenience Properties

    var displayName: String {
        type.metadata.displayName
    }

    var isConfigured: Bool {
        credentials.isValid(for: type)
    }

    var metadata: IntegrationMetadata {
        type.metadata
    }

    var primaryAuthToken: String? {
        credentials.primaryToken(for: type)
    }

    // MARK: - Initializer

    init(
        type: IntegrationType,
        capabilities: [IntegrationCapability]? = nil,
        credentials: IntegrationCredentials? = nil
    ) {
        self.type = type
        self.capabilities = capabilities ?? type.metadata.defaultCapabilities
        if let creds = credentials {
            self.credentials = creds
        }
    }

    // MARK: - Methods

    func supports(_ capability: IntegrationCapability) -> Bool {
        capabilities.contains(capability)
    }

    func validateCredentials() -> Bool {
        credentials.isValid(for: type)
    }

    // MARK: - Factory Methods (Type-safe creation)

    static func cloudflare(
        email: String,
        globalAPIKey: String,
        r2AccessKeyId: String? = nil,
        r2SecretAccessKey: String? = nil
    ) -> Integration {
        Integration(
            type: .cloudflare,
            credentials: IntegrationCredentials(
                email: email,
                globalAPIKey: globalAPIKey,
                r2AccessKeyId: r2AccessKeyId,
                r2SecretAccessKey: r2SecretAccessKey
            )
        )
    }

    static func digitalOcean(apiToken: String) -> Integration {
        Integration(
            type: .digitalocean,
            credentials: IntegrationCredentials(token: apiToken)
        )
    }

    static func hetzner(apiToken: String) -> Integration {
        Integration(
            type: .hetzner,
            credentials: IntegrationCredentials(token: apiToken)
        )
    }

    static func hetznerDNS(apiToken: String) -> Integration {
        Integration(
            type: .hetznerDNS,
            credentials: IntegrationCredentials(token: apiToken)
        )
    }

    static func bunny(apiKey: String) -> Integration {
        Integration(
            type: .bunny,
            credentials: IntegrationCredentials(apiKey: apiKey)
        )
    }

    static func vultr(apiToken: String) -> Integration {
        Integration(
            type: .vultr,
            credentials: IntegrationCredentials(token: apiToken)
        )
    }

    static func linode(apiToken: String) -> Integration {
        Integration(
            type: .linode,
            credentials: IntegrationCredentials(token: apiToken)
        )
    }

    static func github(token: String) -> Integration {
        Integration(
            type: .github,
            credentials: IntegrationCredentials(token: token)
        )
    }

    static func scaleway(accessKey: String, secretKey: String, region: String) -> Integration {
        Integration(
            type: .scaleway,
            credentials: IntegrationCredentials(
                accessKey: accessKey,
                secretKey: secretKey,
                scalewayRegion: region
            )
        )
    }

    static func dropbox(appKey: String, appSecret: String, refreshToken: String) -> Integration {
        Integration(
            type: .dropbox,
            credentials: IntegrationCredentials(
                dropboxAppKey: appKey,
                dropboxAppSecret: appSecret,
                dropboxRefreshToken: refreshToken
            )
        )
    }
}
