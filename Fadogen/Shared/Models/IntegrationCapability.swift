import Foundation
import SwiftUI

nonisolated enum IntegrationCapability: String, Codable, CaseIterable, Sendable {
    case dns = "dns"
    case vpsProvider = "vps_provider"
    case tunnel = "tunnel"
    case cicd = "cicd"
    case backup = "backup"

    var displayName: String {
        switch self {
        case .dns: return "DNS Management"
        case .vpsProvider: return "VPS Provisioning"
        case .tunnel: return "Secure Tunnels"
        case .cicd: return "CI/CD & Secrets"
        case .backup: return "Backup & Storage"
        }
    }

    var badgeLabel: String {
        switch self {
        case .dns: return "DNS"
        case .vpsProvider: return "VPS"
        case .tunnel: return "TUNNEL"
        case .cicd: return "CI/CD"
        case .backup: return "BACKUP"
        }
    }

    var color: Color {
        switch self {
        case .dns: return .blue
        case .vpsProvider: return .green
        case .tunnel: return .purple
        case .cicd: return .orange
        case .backup: return .cyan
        }
    }
}
