import Foundation

// MARK: - Domain

struct VultrDomain: Codable, Identifiable, Sendable, Hashable {
    let domain: String
    let dateCreated: String
    let dnsSec: String      // "enabled" or "disabled"

    var id: String { domain }

    enum CodingKeys: String, CodingKey {
        case domain
        case dateCreated = "date_created"
        case dnsSec = "dns_sec"
    }
}

// MARK: - Record

struct VultrDNSRecord: Codable, Identifiable, Sendable {
    let id: String
    let type: String        // A, AAAA, CNAME, MX, TXT, NS, SRV, CAA
    let name: String        // "" for apex, subdomain otherwise
    let data: String        // IP, domain, content
    let priority: Int
    let ttl: Int

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case data
        case priority
        case ttl
    }
}

// MARK: - Response

struct VultrDomainsResponse: Codable, Sendable {
    let domains: [VultrDomain]
}

struct VultrDomainResponse: Codable, Sendable {
    let domain: VultrDomain
}

struct VultrDNSRecordsResponse: Codable, Sendable {
    let records: [VultrDNSRecord]
}

struct VultrDNSRecordResponse: Codable, Sendable {
    let record: VultrDNSRecord
}

// MARK: - Request

struct VultrCreateRecordRequest: Codable, Sendable {
    let type: String
    let name: String
    let data: String
    let ttl: Int?
    let priority: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case data
        case ttl
        case priority
    }

    init(
        type: String,
        name: String,
        data: String,
        ttl: Int? = nil,
        priority: Int? = nil
    ) {
        self.type = type
        self.name = name
        self.data = data
        self.ttl = ttl
        self.priority = priority
    }
}

// MARK: - Error

enum VultrDNSError: Error, LocalizedError {
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
            return String(localized: "Failed to authenticate with Vultr")
        case .forbidden:
            return String(localized: "Access forbidden to Vultr resource")
        case .rateLimited:
            return String(localized: "Too many requests to Vultr API")
        case .notFound:
            return String(localized: "Domain or record not found")
        case .validation(let message):
            return String(localized: "Invalid request: \(message)")
        case .networkError:
            return String(localized: "Network connection error")
        case .serverError(let code, _):
            return String(localized: "Vultr server error (code: \(code))")
        case .apiError(let message):
            return String(localized: "Vultr API Error: \(message)")
        case .invalidResponse:
            return String(localized: "Invalid response from Vultr")
        case .timeout:
            return String(localized: "Request to Vultr timed out")
        case .recordAlreadyExists(let message):
            return String(localized: "DNS record already exists: \(message)")
        }
    }

    var failureReason: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Your Vultr API token is incorrect or has expired.")
        case .forbidden:
            return String(localized: "Your Vultr API token doesn't have permission for this operation.")
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
            return String(localized: "The response from Vultr was not in the expected format.")
        case .timeout:
            return String(localized: "The connection to Vultr took too long.")
        case .recordAlreadyExists(let message):
            return message
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Check your Vultr API token in Settings, then try again.")
        case .forbidden:
            return String(localized: "Check that your API token has the required permissions.")
        case .rateLimited:
            return String(localized: "Wait a few minutes before trying again.")
        case .notFound:
            return String(localized: "Verify that the domain exists in your Vultr account.")
        case .validation:
            return String(localized: "Check the DNS record parameters and try again.")
        case .networkError:
            return String(localized: "Check your internet connection and try again.")
        case .serverError:
            return String(localized: "Try again in a few minutes. If the problem persists, check Vultr's status page.")
        case .apiError:
            return String(localized: "If this error persists, contact Vultr support.")
        case .invalidResponse:
            return String(localized: "Try again. If the problem persists, contact support.")
        case .timeout:
            return String(localized: "Check your internet connection and try again.")
        case .recordAlreadyExists:
            return String(localized: "Use a different name or delete the existing record first.")
        }
    }
}
