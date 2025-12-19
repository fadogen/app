import Foundation
import SwiftData

/// Authentication type for SSH connections
enum AuthMethodType: String, CaseIterable {
    case sshKey = "SSH Key"
    case password = "Password"

    var localizedValue: String {
        switch self {
        case .sshKey:
            return String(localized: "SSH Key")
        case .password:
            return String(localized: "Password")
        }
    }
}

/// Available SSH key options
enum SSHKeyOption: Hashable {
    case auto
    case custom

    var displayName: String {
        switch self {
        case .auto:
            return String(localized: "Auto (try all detected keys)")
        case .custom:
            return String(localized: "Custom")
        }
    }
}

/// Cloudflare Tunnel configuration for server creation
struct CloudflareTunnelConfig {
    let integration: Integration
    let zone: CloudflareZone
    let sshSubdomain: String

    /// Validates if the tunnel configuration is valid
    var isValid: Bool {
        do {
            try CloudflareTunnel.validateSubdomain(sshSubdomain)
            return true
        } catch {
            return false
        }
    }

    /// The full SSH hostname for this tunnel
    var fullSSHHostname: String {
        "\(sshSubdomain).\(zone.name)"
    }

    /// Validates the subdomain and returns an error message if invalid
    func validationError() -> String? {
        do {
            try CloudflareTunnel.validateSubdomain(sshSubdomain)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
