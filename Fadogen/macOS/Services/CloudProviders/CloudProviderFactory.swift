import Foundation

struct CloudProviderFactory {

    static func createService(for integrationType: IntegrationType) throws -> any CloudProviderService {
        switch integrationType {
        case .digitalocean:
            return DigitalOceanServiceAdapter()

        case .hetzner:
            return HetznerServiceAdapter()

        case .linode:
            return LinodeServiceAdapter()

        case .vultr:
            return VultrServiceAdapter()

        case .bunny:
            // TODO: Implement service for Bunny
            throw CloudProviderError.unsupportedProvider(integrationType.metadata.displayName)

        case .cloudflare:
            // Cloudflare is not a VPS provider
            throw CloudProviderError.unsupportedProvider("Cloudflare is not a VPS provider")

        case .hetznerDNS:
            // Hetzner DNS is not a VPS provider
            throw CloudProviderError.unsupportedProvider("Hetzner DNS is not a VPS provider")

        case .github:
            // GitHub is not a VPS provider
            throw CloudProviderError.unsupportedProvider("GitHub is not a VPS provider")

        case .scaleway:
            // Scaleway (as configured here) is only for Object Storage, not VPS
            throw CloudProviderError.unsupportedProvider("Scaleway is configured for backup storage only")

        case .dropbox:
            // Dropbox is only for backup storage, not VPS
            throw CloudProviderError.unsupportedProvider("Dropbox is configured for backup storage only")
        }
    }
}
