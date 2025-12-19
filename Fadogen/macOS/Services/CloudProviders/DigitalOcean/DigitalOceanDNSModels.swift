import Foundation

// MARK: - Domain

struct DigitalOceanDomain: Codable, Identifiable, Sendable, Hashable {
    let name: String
    let ttl: Int?
    let zoneFile: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case ttl
        case zoneFile = "zone_file"
    }
}

// MARK: - Domain Record

struct DigitalOceanDomainRecord: Codable, Identifiable, Sendable {
    let id: Int
    let type: String
    let name: String
    let data: String
    let priority: Int?
    let port: Int?
    let ttl: Int
    let weight: Int?
    let flags: Int?
    let tag: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case data
        case priority
        case port
        case ttl
        case weight
        case flags
        case tag
    }
}

// MARK: - Pagination

struct DOLinks: Codable, Sendable {
    let pages: DOPages?

    struct DOPages: Codable, Sendable {
        let first: String?
        let prev: String?
        let next: String?
        let last: String?
    }
}

struct DOMeta: Codable, Sendable {
    let total: Int
}

// MARK: - Response

struct DigitalOceanDomainsResponse: Codable, Sendable {
    let domains: [DigitalOceanDomain]
    let links: DOLinks?
    let meta: DOMeta
}

struct DigitalOceanDomainResponse: Codable, Sendable {
    let domain: DigitalOceanDomain
}

struct DigitalOceanDomainRecordsResponse: Codable, Sendable {
    let domainRecords: [DigitalOceanDomainRecord]
    let links: DOLinks?
    let meta: DOMeta

    enum CodingKeys: String, CodingKey {
        case domainRecords = "domain_records"
        case links
        case meta
    }
}

struct DigitalOceanDomainRecordResponse: Codable, Sendable {
    let domainRecord: DigitalOceanDomainRecord

    enum CodingKeys: String, CodingKey {
        case domainRecord = "domain_record"
    }
}

// MARK: - Request

struct DigitalOceanCreateRecordRequest: Codable, Sendable {
    let type: String
    let name: String
    let data: String
    let priority: Int?
    let port: Int?
    let ttl: Int?
    let weight: Int?
    let flags: Int?
    let tag: String?

    init(
        type: String,
        name: String,
        data: String,
        ttl: Int? = nil,
        priority: Int? = nil,
        port: Int? = nil,
        weight: Int? = nil,
        flags: Int? = nil,
        tag: String? = nil
    ) {
        self.type = type
        self.name = name
        self.data = data
        self.ttl = ttl
        self.priority = priority
        self.port = port
        self.weight = weight
        self.flags = flags
        self.tag = tag
    }
}

// MARK: - Error

struct DigitalOceanAPIError: Codable, Sendable {
    let id: String
    let message: String

    var localizedDescription: String { message }
}

struct DigitalOceanErrorResponse: Codable, Sendable {
    let id: String
    let message: String
}

enum DigitalOceanDNSError: Error, LocalizedError {
    case unauthorized
    case rateLimited
    case notFound
    case unprocessableEntity(String)
    case networkError(Error)
    case serverError(Int, String)
    case apiError(String)
    case invalidResponse
    case timeout
    case recordAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Failed to authenticate with DigitalOcean", comment: "Auth error description")
        case .rateLimited:
            return String(localized: "Too many requests to DigitalOcean API", comment: "Rate limit error description")
        case .notFound:
            return String(localized: "Domain or record not found", comment: "Not found error description")
        case .unprocessableEntity(let message):
            return String(localized: "Invalid request: \(message)", comment: "Validation error description")
        case .networkError:
            return String(localized: "Network connection error", comment: "Network error description")
        case .serverError(let code, _):
            return String(localized: "DigitalOcean server error (code: \(code))", comment: "Server error description")
        case .apiError(let message):
            return String(localized: "DigitalOcean API Error: \(message)", comment: "API error description")
        case .invalidResponse:
            return String(localized: "Invalid response from DigitalOcean", comment: "Invalid response error description")
        case .timeout:
            return String(localized: "Request to DigitalOcean timed out", comment: "Timeout error description")
        case .recordAlreadyExists(let message):
            return String(localized: "DNS record already exists: \(message)", comment: "Record exists error description")
        }
    }

    var failureReason: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Your DigitalOcean API token is incorrect or has expired.", comment: "Auth error reason")
        case .rateLimited:
            return String(localized: "You've made too many requests in a short time.", comment: "Rate limit error reason")
        case .notFound:
            return String(localized: "The requested domain or DNS record doesn't exist.", comment: "Not found error reason")
        case .unprocessableEntity(let message):
            return message
        case .networkError(let error):
            return error.localizedDescription
        case .serverError(_, let message):
            return message
        case .apiError(let message):
            return message
        case .invalidResponse:
            return String(localized: "The response from DigitalOcean was not in the expected format.", comment: "Invalid response reason")
        case .timeout:
            return String(localized: "The connection to DigitalOcean took too long.", comment: "Timeout error reason")
        case .recordAlreadyExists(let message):
            return message
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Check your DigitalOcean API token in Settings, then try again.", comment: "Auth error recovery")
        case .rateLimited:
            return String(localized: "Wait a few minutes before trying again.", comment: "Rate limit recovery")
        case .notFound:
            return String(localized: "Verify that the domain exists in your DigitalOcean account.", comment: "Not found recovery")
        case .unprocessableEntity:
            return String(localized: "Check the DNS record parameters and try again.", comment: "Validation error recovery")
        case .networkError:
            return String(localized: "Check your internet connection and try again.", comment: "Network error recovery")
        case .serverError:
            return String(localized: "Try again in a few minutes. If the problem persists, check DigitalOcean's status page.", comment: "Server error recovery")
        case .apiError:
            return String(localized: "If this error persists, contact DigitalOcean support.", comment: "API error recovery")
        case .invalidResponse:
            return String(localized: "Try again. If the problem persists, contact support.", comment: "Invalid response recovery")
        case .timeout:
            return String(localized: "Check your internet connection and try again.", comment: "Timeout recovery")
        case .recordAlreadyExists:
            return String(localized: "Use a different name or delete the existing record first.", comment: "Record exists recovery")
        }
    }
}
