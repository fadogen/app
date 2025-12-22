import Foundation
import SwiftData

/// A route configuration for sharing a local project via Cloudflare Tunnel
/// Each route maps a public hostname to a local project URL
@Model
final class LocalTunnelRoute {

    /// UUID of the associated LocalProject
    var projectID: UUID

    /// Full public hostname (e.g., "myproject.example.com")
    var hostname: String

    /// Cloudflare zone ID
    var zoneID: String

    /// Zone name / domain (e.g., "example.com")
    var zoneName: String

    /// Subdomain part (e.g., "myproject")
    var subdomain: String

    /// DNS record ID for cleanup
    var dnsRecordID: String?

    /// Whether this route is currently active
    var isActive: Bool = true

    /// Creation date
    var createdAt: Date = Date()

    init(
        projectID: UUID,
        hostname: String,
        zoneID: String,
        zoneName: String,
        subdomain: String,
        dnsRecordID: String? = nil,
        isActive: Bool = true
    ) {
        self.projectID = projectID
        self.hostname = hostname
        self.zoneID = zoneID
        self.zoneName = zoneName
        self.subdomain = subdomain
        self.dnsRecordID = dnsRecordID
        self.isActive = isActive
    }

    /// Public URL for this route
    var publicURL: String {
        "https://\(hostname)"
    }

    /// Validate subdomain format (reuse CloudflareTunnel validation)
    static func validateSubdomain(_ subdomain: String) throws {
        try CloudflareTunnel.validateSubdomain(subdomain)
    }
}
