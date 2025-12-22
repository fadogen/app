import Foundation
import SwiftData

/// Local cloudflared daemon configuration for sharing projects publicly
/// Stored locally (not synced to CloudKit) as it's machine-specific
@Model
final class LocalTunnelConfig {

    /// Cloudflare tunnel UUID
    var tunnelID: String?

    /// Tunnel name (default: "fadogen-local-sharing")
    var tunnelName: String = "fadogen-local-sharing"

    /// Cloudflare account ID
    var accountID: String?

    /// Unique identifier for SwiftData queries
    var uniqueIdentifier: String = ""

    /// Creation date
    var createdAt: Date = Date()

    init(
        tunnelID: String? = nil,
        tunnelName: String = "fadogen-local-sharing",
        accountID: String? = nil
    ) {
        self.tunnelID = tunnelID
        self.tunnelName = tunnelName
        self.accountID = accountID
        self.uniqueIdentifier = "local-tunnel"
    }

    /// Check if tunnel is properly configured
    var isConfigured: Bool {
        tunnelID != nil && accountID != nil
    }

    /// CNAME target for DNS records
    var cnameTarget: String? {
        guard let id = tunnelID else { return nil }
        return "\(id).cfargotunnel.com"
    }
}
