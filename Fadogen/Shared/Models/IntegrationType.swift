import Foundation

nonisolated enum IntegrationType: String, Codable, CaseIterable, Sendable, Identifiable {
    case cloudflare = "cloudflare"
    case digitalocean = "digitalocean"
    case hetzner = "hetzner"
    case hetznerDNS = "hetzner_dns"
    case bunny = "bunny"
    case vultr = "vultr"
    case linode = "linode"
    case github = "github"
    case scaleway = "scaleway"
    case dropbox = "dropbox"

    /// Base URL for Fadogen documentation - change this to update all integration doc links
    static let docsBaseURL = "https://docs.fadogen.app"

    var id: String { rawValue }

    var metadata: IntegrationMetadata {
        switch self {
        case .cloudflare:
            return IntegrationMetadata(
                displayName: "Cloudflare",
                defaultCapabilities: [.dns, .tunnel, .backup],
                authMethod: .emailAndGlobalKey,
                apiBaseURL: "https://api.cloudflare.com/client/v4",
                documentationURL: URL(string: "\(Self.docsBaseURL)/integrations/config/cloudflare/"),
                assetName: "cloudflare",
                iconName: "cloud.fill"
            )

        case .digitalocean:
            return IntegrationMetadata(
                displayName: "DigitalOcean",
                defaultCapabilities: [.dns, .vpsProvider],
                authMethod: .bearerToken,
                apiBaseURL: "https://api.digitalocean.com/v2",
                documentationURL: URL(string: "\(Self.docsBaseURL)/integrations/config/digitalocean/"),
                assetName: "digitalocean",
                iconName: "server.rack"
            )

        case .hetzner:
            return IntegrationMetadata(
                displayName: "Hetzner Cloud",
                defaultCapabilities: [.vpsProvider],
                authMethod: .bearerToken,
                apiBaseURL: "https://api.hetzner.cloud/v1",
                documentationURL: URL(string: "\(Self.docsBaseURL)/integrations/config/hetzner/"),
                assetName: "hetzner",
                iconName: "server.rack"
            )

        case .hetznerDNS:
            return IntegrationMetadata(
                displayName: "Hetzner DNS",
                defaultCapabilities: [.dns],
                authMethod: .bearerToken,
                apiBaseURL: "https://dns.hetzner.com/api/v1",
                documentationURL: URL(string: "\(Self.docsBaseURL)/integrations/config/hetzner-dns/"),
                assetName: "hetzner",
                iconName: "network"
            )

        case .bunny:
            return IntegrationMetadata(
                displayName: "Bunny",
                defaultCapabilities: [.dns],
                authMethod: .apiKey,
                apiBaseURL: "https://api.bunny.net",
                documentationURL: URL(string: "\(Self.docsBaseURL)/integrations/config/bunny/"),
                assetName: "bunny",
                iconName: "hare.fill"
            )

        case .vultr:
            return IntegrationMetadata(
                displayName: "Vultr",
                defaultCapabilities: [.dns, .vpsProvider],
                authMethod: .bearerToken,
                apiBaseURL: "https://api.vultr.com/v2",
                documentationURL: URL(string: "\(Self.docsBaseURL)/integrations/config/vultr/"),
                assetName: "vultr",
                iconName: "server.rack"
            )

        case .linode:
            return IntegrationMetadata(
                displayName: "Linode",
                defaultCapabilities: [.dns, .vpsProvider],
                authMethod: .bearerToken,
                apiBaseURL: "https://api.linode.com/v4",
                documentationURL: URL(string: "\(Self.docsBaseURL)/integrations/config/linode/"),
                assetName: "linode",
                iconName: "server.rack"
            )

        case .github:
            return IntegrationMetadata(
                displayName: "GitHub",
                defaultCapabilities: [.cicd],
                authMethod: .bearerToken,
                apiBaseURL: "https://api.github.com",
                documentationURL: URL(string: "\(Self.docsBaseURL)/integrations/config/github/"),
                assetName: "github",
                iconName: "chevron.left.forwardslash.chevron.right"
            )

        case .scaleway:
            return IntegrationMetadata(
                displayName: "Scaleway",
                defaultCapabilities: [.backup],
                authMethod: .accessKeyAndSecret,
                apiBaseURL: "",  // Regional S3 endpoints
                documentationURL: URL(string: "\(Self.docsBaseURL)/integrations/config/scaleway/"),
                assetName: "scaleway",
                iconName: "externaldrive.fill.badge.icloud"
            )

        case .dropbox:
            return IntegrationMetadata(
                displayName: "Dropbox",
                defaultCapabilities: [.backup],
                authMethod: .oauth2,
                apiBaseURL: "https://api.dropboxapi.com/2",
                documentationURL: URL(string: "\(Self.docsBaseURL)/integrations/config/dropbox/"),
                assetName: "dropbox",
                iconName: "shippingbox.fill"
            )
        }
    }
}

nonisolated struct IntegrationMetadata: Sendable {
    let displayName: String
    let defaultCapabilities: [IntegrationCapability]
    let authMethod: AuthenticationMethod
    let apiBaseURL: String
    let documentationURL: URL?
    let assetName: String
    let iconName: String
}

nonisolated enum AuthenticationMethod: Sendable {
    case bearerToken
    case apiKey
    case emailAndGlobalKey
    case accessKeyAndSecret
    case oauth2
}
