import Foundation

// MARK: - DNS Zone

/// Normalized across all providers
struct DNSZone: Identifiable, Hashable, Sendable {
    let name: String  // e.g., "example.com"
    let id: String
    let integration: Integration

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
    }

    static func == (lhs: DNSZone, rhs: DNSZone) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

// MARK: - DNS Record

/// Normalized across all providers
struct DNSRecord: Identifiable, Sendable {
    let id: String
    let type: String  // A, AAAA, CNAME, MX, TXT, etc.
    let name: String  // subdomain or @
    let content: String
    let priority: Int?  // MX, SRV
    let proxied: Bool?  // Cloudflare only

    var displayString: String {
        "\(type) \(name) → \(content)"
    }
}

// MARK: - DNS Record Type

enum DNSRecordType: String, CaseIterable, Sendable {
    case a = "A"
    case aaaa = "AAAA"
    case cname = "CNAME"
    case mx = "MX"
    case txt = "TXT"
    case ns = "NS"
    case srv = "SRV"
    case caa = "CAA"

    var description: String {
        switch self {
        case .a:
            return "IPv4 Address"
        case .aaaa:
            return "IPv6 Address"
        case .cname:
            return "Canonical Name"
        case .mx:
            return "Mail Exchange"
        case .txt:
            return "Text Record"
        case .ns:
            return "Name Server"
        case .srv:
            return "Service Record"
        case .caa:
            return "Certification Authority Authorization"
        }
    }
}

// MARK: - DNS Error

enum DNSError: Error, LocalizedError {
    case invalidToken
    case integrationNotConfigured
    case capabilityNotSupported
    case notImplemented(String)
    case apiError(String)
    case traefikConfigurationFailed
    case gitRepositoryNotFound
    case serverNotLinked
    case recordAlreadyExists(type: String, name: String, existingContent: String, requestedContent: String)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Invalid or missing DNS credentials"
        case .integrationNotConfigured:
            return "DNS integration is not configured"
        case .capabilityNotSupported:
            return "This integration does not support DNS management"
        case .notImplemented(let provider):
            return "\(provider) DNS management is not yet implemented"
        case .apiError(let message):
            return "DNS API Error: \(message)"
        case .traefikConfigurationFailed:
            return "Failed to configure Traefik DNS provider"
        case .gitRepositoryNotFound:
            return "Git repository not found in project directory"
        case .serverNotLinked:
            return "Project is not linked to a server"
        case .recordAlreadyExists(let type, let name, let existingContent, let requestedContent):
            return "DNS record \(type) '\(name)' already exists with different content. Existing: '\(existingContent)', Requested: '\(requestedContent)'"
        }
    }
}
