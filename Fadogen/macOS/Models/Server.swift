import Foundation
import SwiftData

enum ServerStatus: String, Codable {
    case created
    case waitingForIP
    case provisioning
    case ready
    case failed
}

/// VPS server with CloudKit-encrypted credentials
@Model
final class Server {

    var id: UUID = UUID()

    /// Display name (e.g., "Production", "Staging")
    var name: String?

    /// VPS provider integration. Nil for manually added servers.
    var integration: Integration?

    /// Provider-side server ID for API operations
    var integrationServerID: String?

    var status: ServerStatus = ServerStatus.created

    /// Detected via `uname -m` during provisioning
    var architecture: String?

    // MARK: - SSH Configuration

    @Attribute(.allowsCloudEncryption)
    var username: String? = nil

    @Attribute(.allowsCloudEncryption)
    var host: String? = nil

    @Attribute(.allowsCloudEncryption)
    var port: Int? = nil

    @Attribute(.allowsCloudEncryption)
    var useSSHKey: Bool? = nil

    @Attribute(.allowsCloudEncryption)
    var password: String? = nil

    /// Falls back to SSH password if not set
    @Attribute(.allowsCloudEncryption)
    var sudoPassword: String? = nil

    @Attribute(.allowsCloudEncryption)
    var sshPrivateKey: String? = nil

    @Attribute(.allowsCloudEncryption)
    var sshPublicKey: String? = nil

    // MARK: - Relationships

    /// SSH via Cloudflare's network instead of exposing port 22
    @Relationship(deleteRule: .nullify, inverse: \CloudflareTunnel.server)
    var cloudflareTunnel: CloudflareTunnel? = nil

    /// DNS providers configured in Traefik for ACME certificates
    @Relationship(deleteRule: .nullify, inverse: \Integration.traefikServers)
    var traefikDNSIntegrations: [Integration]? = []

    @Relationship(deleteRule: .nullify, inverse: \DeployedProject.server)
    var deployedProjects: [DeployedProject]? = []

    init(
        name: String? = nil,
        integration: Integration? = nil,
        integrationServerID: String? = nil,
        status: ServerStatus = .created,
        username: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        useSSHKey: Bool? = nil,
        password: String? = nil,
        sudoPassword: String? = nil,
        sshPrivateKey: String? = nil,
        sshPublicKey: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.integration = integration
        self.integrationServerID = integrationServerID
        self.status = status
        self.username = username
        self.host = host
        self.port = port
        self.useSSHKey = useSSHKey
        self.password = password
        self.sudoPassword = sudoPassword
        self.sshPrivateKey = sshPrivateKey
        self.sshPublicKey = sshPublicKey
    }

    // MARK: - Helpers

    func isManagedByIntegration() -> Bool {
        integration != nil && integrationServerID != nil
    }

    func isCustomServer() -> Bool {
        integration == nil
    }

    func hasCompleteConfig() -> Bool {
        username != nil && port != nil && useSSHKey != nil
    }

    /// Tunnel hostname when available, otherwise direct IP
    var connectionHost: String? {
        if let tunnel = cloudflareTunnel, status == .ready {
            return tunnel.sshHostname
        }
        return host
    }

    var needsProxyCommand: Bool {
        cloudflareTunnel != nil && status == .ready
    }
}
