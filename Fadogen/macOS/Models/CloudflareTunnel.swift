import Foundation
import SwiftData

/// Zero-trust SSH access without exposing port 22
@Model
final class CloudflareTunnel {

    var id: UUID = UUID()
    var tunnelID: String?

    @Attribute(.allowsCloudEncryption)
    var tunnelToken: String?

    var zoneID: String?
    var zoneName: String?
    var sshSubdomain: String?
    var dnsRecordID: String?
    var createdAt: Date = Date()

    // MARK: - Relationships

    var server: Server?
    var integration: Integration?

    // MARK: - Computed

    /// e.g. "ssh.example.com"
    var sshHostname: String {
        guard let subdomain = sshSubdomain, let zone = zoneName else {
            return "unknown"
        }
        return "\(subdomain).\(zone)"
    }

    /// Trailing dot required by some DNS providers (FQDN format)
    var tunnelCNAME: String {
        guard let id = tunnelID else {
            return "unknown"
        }
        return "\(id).cfargotunnel.com."
    }

    // MARK: - Init

    init(
        tunnelID: String? = nil,
        tunnelToken: String? = nil,
        zoneID: String? = nil,
        zoneName: String? = nil,
        sshSubdomain: String? = nil,
        dnsRecordID: String? = nil,
        server: Server? = nil,
        integration: Integration? = nil
    ) {
        self.tunnelID = tunnelID
        self.tunnelToken = tunnelToken
        self.zoneID = zoneID
        self.zoneName = zoneName
        self.sshSubdomain = sshSubdomain
        self.dnsRecordID = dnsRecordID
        self.server = server
        self.integration = integration
    }

    // MARK: - Validation

    static func validateTunnelID(_ id: String) throws {
        guard !id.isEmpty else {
            throw ValidationError.emptyTunnelID
        }

        // UUID format validation (8-4-4-4-12 hexadecimal characters)
        let uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        let regex = try NSRegularExpression(pattern: uuidPattern)
        let range = NSRange(location: 0, length: id.utf16.count)

        guard regex.firstMatch(in: id, range: range) != nil else {
            throw ValidationError.invalidTunnelIDFormat
        }
    }

    static func validateZoneName(_ name: String) throws {
        guard !name.isEmpty else {
            throw ValidationError.emptyZoneName
        }

        guard !name.contains(where: \.isWhitespace) else {
            throw ValidationError.zoneNameContainsWhitespace
        }

        // Basic domain validation: alphanumeric, dots, hyphens
        let domainPattern = "^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$"
        let regex = try NSRegularExpression(pattern: domainPattern)
        let range = NSRange(location: 0, length: name.utf16.count)

        guard regex.firstMatch(in: name, range: range) != nil else {
            throw ValidationError.invalidZoneNameFormat
        }
    }

    static func validateSubdomain(_ subdomain: String) throws {
        guard !subdomain.isEmpty else {
            throw ValidationError.emptySubdomain
        }

        guard subdomain.count <= 63 else {
            throw ValidationError.subdomainTooLong
        }

        // Alphanumeric and hyphens only, no leading/trailing hyphens
        let subdomainPattern = "^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"
        let regex = try NSRegularExpression(pattern: subdomainPattern)
        let range = NSRange(location: 0, length: subdomain.utf16.count)

        guard regex.firstMatch(in: subdomain, range: range) != nil else {
            throw ValidationError.invalidSubdomainFormat
        }
    }
}

// MARK: - Errors

extension CloudflareTunnel {
    enum ValidationError: LocalizedError {
        case emptyTunnelID
        case invalidTunnelIDFormat
        case emptyZoneName
        case zoneNameContainsWhitespace
        case invalidZoneNameFormat
        case emptySubdomain
        case subdomainTooLong
        case invalidSubdomainFormat

        var errorDescription: String? {
            switch self {
            case .emptyTunnelID:
                return "Tunnel ID cannot be empty"
            case .invalidTunnelIDFormat:
                return "Tunnel ID must be a valid UUID format"
            case .emptyZoneName:
                return "Zone name cannot be empty"
            case .zoneNameContainsWhitespace:
                return "Zone name cannot contain whitespace"
            case .invalidZoneNameFormat:
                return "Zone name must be a valid domain format"
            case .emptySubdomain:
                return "Subdomain cannot be empty"
            case .subdomainTooLong:
                return "Subdomain cannot exceed 63 characters"
            case .invalidSubdomainFormat:
                return "Subdomain must contain only alphanumeric characters and hyphens, and cannot start or end with a hyphen"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .invalidTunnelIDFormat:
                return "Ensure the tunnel ID is a valid UUID (e.g., 550e8400-e29b-41d4-a716-446655440000)"
            case .invalidZoneNameFormat:
                return "Use a valid domain name (e.g., example.com)"
            case .invalidSubdomainFormat:
                return "Use only letters, numbers, and hyphens. Must start and end with alphanumeric characters."
            default:
                return nil
            }
        }
    }
}
