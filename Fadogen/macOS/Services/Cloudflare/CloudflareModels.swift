import Foundation

struct EmptyResult: Codable {}

// MARK: - Zone

struct CloudflareZone: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let status: String
    let nameServers: [String]?

    /// Computed property to check if zone is active
    var isActive: Bool {
        status == "active"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case nameServers = "name_servers"
    }
}

// MARK: - Account

struct CloudflareAccount: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let type: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
    }
}

// MARK: - Pagination

struct CloudflareResultInfo: Codable, Sendable {
    let page: Int
    let perPage: Int
    let totalCount: Int
    let totalPages: Int

    enum CodingKeys: String, CodingKey {
        case page
        case perPage = "per_page"
        case totalCount = "total_count"
        case totalPages = "total_pages"
    }
}

// MARK: - API Response

struct CloudflareAPIResponse<T: Codable>: Codable {
    let success: Bool
    let errors: [CloudflareAPIError]
    let messages: [String]
    let result: T?
    let resultInfo: CloudflareResultInfo?

    enum CodingKeys: String, CodingKey {
        case success
        case errors
        case messages
        case result
        case resultInfo = "result_info"
    }

    func isSuccess() -> Bool { success && result != nil }

    func errorMessage() -> String {
        if errors.isEmpty {
            return String(localized: "Unknown error occurred", comment: "Generic error message")
        }
        return errors.map { $0.message }.joined(separator: "; ")
    }
}

// MARK: - API Error

struct CloudflareAPIError: Codable, Sendable {
    let code: Int
    let message: String

    var localizedDescription: String {
        switch code {
        case 9103, 10000:
            return String(localized: "Invalid Cloudflare credentials. Please check your email and API key.", comment: "Authentication error")
        case 9106:
            return String(localized: "Malformed request to Cloudflare API.", comment: "Bad request error")
        case 9109:
            return String(localized: "Access denied. Your account doesn't have permission to perform this action.", comment: "Permission error")
        default:
            return message
        }
    }
}

// MARK: - Tunnel

struct CloudflareTunnelInfo: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let accountTag: String?
    let credentialsFile: TunnelCredentials?
    let token: String?

    var cnameTarget: String { "\(id).cfargotunnel.com" }

    /// Cloudflare API returns these fields in PascalCase
    struct TunnelCredentials: Codable, Sendable {
        let accountTag: String?
        let tunnelID: String?
        let tunnelName: String?
        let tunnelSecret: String?

        enum CodingKeys: String, CodingKey {
            case accountTag = "AccountTag"
            case tunnelID = "TunnelID"
            case tunnelName = "TunnelName"
            case tunnelSecret = "TunnelSecret"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case accountTag = "account_tag"
        case credentialsFile = "credentials_file"
        case token
    }
}

// MARK: - DNS Record

struct CloudflareDNSRecord: Codable, Identifiable, Sendable {
    let id: String
    let zoneID: String?  // Present in list responses, absent in create responses
    let type: String
    let name: String
    let content: String
    let proxied: Bool
    let ttl: Int
    let createdOn: String?
    let modifiedOn: String?

    var isTunnelRecord: Bool { content.hasSuffix(".cfargotunnel.com") }

    enum CodingKeys: String, CodingKey {
        case id
        case zoneID = "zone_id"
        case type
        case name
        case content
        case proxied
        case ttl
        case createdOn = "created_on"
        case modifiedOn = "modified_on"
    }
}

// MARK: - Tunnel Setup

struct TunnelSetupResult: Sendable {
    let tunnelInfo: CloudflareTunnelInfo
    let dnsRecord: CloudflareDNSRecord
}

struct CloudflareDeleteResponse: Codable, Sendable {
    let id: String
}

// MARK: - Error

enum CloudflareError: Error, LocalizedError {
    case unauthorized
    case rateLimited
    case networkError(Error)
    case serverError(code: Int)
    case apiError(code: Int, message: String)
    case invalidResponse
    case timeout
    case noAccountFound

    // DNS-specific errors
    case recordConflict(message: String)
    case invalidRecordType(message: String)
    case dnssecError(message: String)
    case zoneLockedError(message: String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Failed to authenticate with Cloudflare", comment: "Auth error description")
        case .rateLimited:
            return String(localized: "Too many requests to Cloudflare", comment: "Rate limit error description")
        case .networkError:
            return String(localized: "Network connection error", comment: "Network error description")
        case .serverError(let code):
            return String(localized: "Cloudflare server error (code: \(code))", comment: "Server error description")
        case .apiError(_, let message):
            return message
        case .invalidResponse:
            return String(localized: "Invalid response from Cloudflare", comment: "Invalid response error description")
        case .timeout:
            return String(localized: "Request to Cloudflare timed out", comment: "Timeout error description")
        case .noAccountFound:
            return String(localized: "No Cloudflare account found", comment: "No account error description")
        case .recordConflict(let message):
            return String(localized: "DNS record conflict: \(message)", comment: "DNS conflict error description")
        case .invalidRecordType(let message):
            return String(localized: "Invalid DNS record type: \(message)", comment: "Invalid record type error description")
        case .dnssecError(let message):
            return String(localized: "DNSSEC error: \(message)", comment: "DNSSEC error description")
        case .zoneLockedError(let message):
            return String(localized: "Zone is locked: \(message)", comment: "Zone locked error description")
        }
    }

    var failureReason: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Your Cloudflare email or API key is incorrect.", comment: "Auth error reason")
        case .rateLimited:
            return String(localized: "You've made too many requests in a short time.", comment: "Rate limit error reason")
        case .networkError(let error):
            return error.localizedDescription
        case .serverError:
            return String(localized: "Cloudflare's servers are experiencing issues.", comment: "Server error reason")
        case .apiError(let code, _):
            return String(localized: "Cloudflare API error code: \(code)", comment: "API error reason")
        case .invalidResponse:
            return String(localized: "The response from Cloudflare was not in the expected format.", comment: "Invalid response reason")
        case .timeout:
            return String(localized: "The connection to Cloudflare took too long.", comment: "Timeout error reason")
        case .noAccountFound:
            return String(localized: "No account is associated with these credentials.", comment: "No account reason")
        case .recordConflict(let message):
            return message
        case .invalidRecordType(let message):
            return message
        case .dnssecError(let message):
            return message
        case .zoneLockedError(let message):
            return message
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Check your Cloudflare email and API key in Settings, then try again.", comment: "Auth error recovery")
        case .rateLimited:
            return String(localized: "Wait a few minutes before trying again.", comment: "Rate limit recovery")
        case .networkError:
            return String(localized: "Check your internet connection and try again.", comment: "Network error recovery")
        case .serverError:
            return String(localized: "Try again in a few minutes. If the problem persists, check Cloudflare's status page.", comment: "Server error recovery")
        case .apiError:
            return String(localized: "If this error persists, contact Cloudflare support.", comment: "API error recovery")
        case .invalidResponse:
            return String(localized: "Try again. If the problem persists, contact support.", comment: "Invalid response recovery")
        case .timeout:
            return String(localized: "Check your internet connection and try again.", comment: "Timeout recovery")
        case .noAccountFound:
            return String(localized: "Verify that you're using a Global API Key, not an API Token.", comment: "No account recovery")
        case .recordConflict:
            return String(localized: "Delete or modify the conflicting DNS record before creating this one.", comment: "DNS conflict recovery")
        case .invalidRecordType:
            return String(localized: "Check that you're using a valid DNS record type (A, AAAA, CNAME, etc.).", comment: "Invalid record type recovery")
        case .dnssecError:
            return String(localized: "Check your DNSSEC configuration in the Cloudflare dashboard.", comment: "DNSSEC error recovery")
        case .zoneLockedError:
            return String(localized: "Wait for the zone to be unlocked or contact Cloudflare support.", comment: "Zone locked recovery")
        }
    }
}

// MARK: - Tunnel Configuration

struct TunnelConfigurationResponse: Codable {
    let config: TunnelConfiguration
}

struct TunnelConfiguration: Codable {
    var ingress: [IngressRule]
}

struct IngressRule: Codable {
    let hostname: String?
    let service: String

    init(hostname: String?, service: String) {
        self.hostname = hostname
        self.service = service
    }
}

// MARK: - R2 Storage

struct CloudflareR2BucketListResult: Codable, Sendable {
    let buckets: [CloudflareR2Bucket]
}

struct CloudflareR2Bucket: Codable, Identifiable, Sendable {
    let name: String
    var id: String { name }
}

struct CloudflareTokenInfo: Codable, Sendable {
    let id: String
    let value: String?  // Only present in create response
}

struct CloudflarePermissionGroup: Codable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct CloudflareR2Credentials: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
}
