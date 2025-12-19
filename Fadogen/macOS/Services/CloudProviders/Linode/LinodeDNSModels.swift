import Foundation

// MARK: - Domain

struct LinodeDomain: Codable, Identifiable, Sendable, Hashable {
    let id: Int
    let domain: String
    let status: String      // "active", "disabled", "edit_mode"
    let type: String        // "master", "slave"
    let soaEmail: String?
    let ttlSec: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case domain
        case status
        case type
        case soaEmail = "soa_email"
        case ttlSec = "ttl_sec"
    }
}

// MARK: - Record

struct LinodeDomainRecord: Codable, Identifiable, Sendable {
    let id: Int
    let type: String        // A, AAAA, CNAME, MX, TXT, NS, SRV, CAA
    let name: String        // "" for apex, subdomain otherwise
    let target: String      // IP, domain, content
    let priority: Int?
    let weight: Int?
    let port: Int?
    let ttlSec: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case target
        case priority
        case weight
        case port
        case ttlSec = "ttl_sec"
    }
}

// MARK: - Pagination

struct LinodePagination: Codable, Sendable {
    let page: Int
    let pages: Int
    let results: Int
}

// MARK: - Response

struct LinodeDomainsResponse: Codable, Sendable {
    let data: [LinodeDomain]
    let page: Int
    let pages: Int
    let results: Int
}

struct LinodeDomainRecordsResponse: Codable, Sendable {
    let data: [LinodeDomainRecord]
    let page: Int
    let pages: Int
    let results: Int
}

// MARK: - Request

struct LinodeCreateRecordRequest: Codable, Sendable {
    let type: String
    let name: String
    let target: String
    let priority: Int?
    let weight: Int?
    let port: Int?
    let ttlSec: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case target
        case priority
        case weight
        case port
        case ttlSec = "ttl_sec"
    }

    init(
        type: String,
        name: String,
        target: String,
        ttlSec: Int? = nil,
        priority: Int? = nil,
        weight: Int? = nil,
        port: Int? = nil
    ) {
        self.type = type
        self.name = name
        self.target = target
        self.ttlSec = ttlSec
        self.priority = priority
        self.weight = weight
        self.port = port
    }
}

// MARK: - Error

struct LinodeDNSAPIError: Codable, Sendable {
    let reason: String
    let field: String?
}

struct LinodeDNSErrorResponse: Codable, Sendable {
    let errors: [LinodeDNSAPIError]
}

enum LinodeDNSError: Error, LocalizedError {
    case unauthorized
    case forbidden
    case rateLimited
    case notFound
    case validation(String)
    case networkError(Error)
    case serverError(Int, String)
    case apiError(String)
    case invalidResponse
    case timeout
    case recordAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Failed to authenticate with Linode")
        case .forbidden:
            return String(localized: "Access forbidden to Linode resource")
        case .rateLimited:
            return String(localized: "Too many requests to Linode API")
        case .notFound:
            return String(localized: "Domain or record not found")
        case .validation(let message):
            return String(localized: "Invalid request: \(message)")
        case .networkError:
            return String(localized: "Network connection error")
        case .serverError(let code, _):
            return String(localized: "Linode server error (code: \(code))")
        case .apiError(let message):
            return String(localized: "Linode API Error: \(message)")
        case .invalidResponse:
            return String(localized: "Invalid response from Linode")
        case .timeout:
            return String(localized: "Request to Linode timed out")
        case .recordAlreadyExists(let message):
            return String(localized: "DNS record already exists: \(message)")
        }
    }

    var failureReason: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Your Linode API token is incorrect or has expired.")
        case .forbidden:
            return String(localized: "Your Linode API token doesn't have permission for this operation.")
        case .rateLimited:
            return String(localized: "You've made too many requests in a short time.")
        case .notFound:
            return String(localized: "The requested domain or DNS record doesn't exist.")
        case .validation(let message):
            return message
        case .networkError(let error):
            return error.localizedDescription
        case .serverError(_, let message):
            return message
        case .apiError(let message):
            return message
        case .invalidResponse:
            return String(localized: "The response from Linode was not in the expected format.")
        case .timeout:
            return String(localized: "The connection to Linode took too long.")
        case .recordAlreadyExists(let message):
            return message
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Check your Linode API token in Settings, then try again.")
        case .forbidden:
            return String(localized: "Check that your API token has the required permissions.")
        case .rateLimited:
            return String(localized: "Wait a few minutes before trying again.")
        case .notFound:
            return String(localized: "Verify that the domain exists in your Linode account.")
        case .validation:
            return String(localized: "Check the DNS record parameters and try again.")
        case .networkError:
            return String(localized: "Check your internet connection and try again.")
        case .serverError:
            return String(localized: "Try again in a few minutes. If the problem persists, check Linode's status page.")
        case .apiError:
            return String(localized: "If this error persists, contact Linode support.")
        case .invalidResponse:
            return String(localized: "Try again. If the problem persists, contact support.")
        case .timeout:
            return String(localized: "Check your internet connection and try again.")
        case .recordAlreadyExists:
            return String(localized: "Use a different name or delete the existing record first.")
        }
    }
}
