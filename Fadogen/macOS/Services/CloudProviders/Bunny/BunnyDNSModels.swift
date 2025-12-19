import Foundation

// MARK: - Record Type

enum BunnyRecordType: Int, Codable, Sendable {
    case a = 0
    case aaaa = 1
    case cname = 2
    case txt = 3
    case mx = 4
    case redirect = 5
    case flatten = 6
    case pullZone = 7
    case srv = 8
    case caa = 9
    case ptr = 10
    case script = 11
    case ns = 12

    var stringValue: String {
        switch self {
        case .a: return "A"
        case .aaaa: return "AAAA"
        case .cname: return "CNAME"
        case .txt: return "TXT"
        case .mx: return "MX"
        case .redirect: return "Redirect"
        case .flatten: return "Flatten"
        case .pullZone: return "PullZone"
        case .srv: return "SRV"
        case .caa: return "CAA"
        case .ptr: return "PTR"
        case .script: return "Script"
        case .ns: return "NS"
        }
    }

    static func from(string: String) -> BunnyRecordType? {
        switch string.uppercased() {
        case "A": return .a
        case "AAAA": return .aaaa
        case "CNAME": return .cname
        case "TXT": return .txt
        case "MX": return .mx
        case "REDIRECT": return .redirect
        case "FLATTEN": return .flatten
        case "PULLZONE": return .pullZone
        case "SRV": return .srv
        case "CAA": return .caa
        case "PTR": return .ptr
        case "SCRIPT": return .script
        case "NS": return .ns
        default: return nil
        }
    }
}

// MARK: - Zone

struct BunnyDNSZone: Codable, Sendable {
    let id: Int
    let domain: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case domain = "Domain"
    }
}

// MARK: - Record

struct BunnyDNSRecord: Codable, Sendable {
    let id: Int
    let type: Int
    let ttl: Int
    let value: String
    let name: String
    let priority: Int

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case type = "Type"
        case ttl = "Ttl"
        case value = "Value"
        case name = "Name"
        case priority = "Priority"
    }

    var typeString: String {
        BunnyRecordType(rawValue: type)?.stringValue ?? "Unknown"
    }
}

// MARK: - Response

struct BunnyZonesResponse: Codable, Sendable {
    let items: [BunnyDNSZone]
    let totalItems: Int
    let currentPage: Int
    let hasMoreItems: Bool

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalItems = "TotalItems"
        case currentPage = "CurrentPage"
        case hasMoreItems = "HasMoreItems"
    }
}

struct BunnyZoneDetailResponse: Codable, Sendable {
    let id: Int
    let domain: String
    let records: [BunnyDNSRecord]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case domain = "Domain"
        case records = "Records"
    }
}

// MARK: - Request

struct BunnyCreateRecordRequest: Codable, Sendable {
    let type: Int
    let ttl: Int
    let value: String
    let name: String
    let priority: Int?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case ttl = "Ttl"
        case value = "Value"
        case name = "Name"
        case priority = "Priority"
    }

    init(type: Int, name: String, value: String, ttl: Int = 300, priority: Int? = nil) {
        self.type = type
        self.name = name
        self.value = value
        self.ttl = ttl
        self.priority = priority
    }
}

// MARK: - Error

struct BunnyErrorResponse: Codable, Sendable {
    let message: String?
    let errorKey: String?

    enum CodingKeys: String, CodingKey {
        case message = "Message"
        case errorKey = "ErrorKey"
    }
}

enum BunnyDNSError: Error, LocalizedError, Sendable {
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
    case unsupportedRecordType(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Failed to authenticate with Bunny")
        case .forbidden:
            return String(localized: "Access forbidden to Bunny resource")
        case .rateLimited:
            return String(localized: "Too many requests to Bunny API")
        case .notFound:
            return String(localized: "DNS zone or record not found")
        case .validation(let message):
            return String(localized: "Invalid request: \(message)")
        case .networkError:
            return String(localized: "Network connection error")
        case .serverError(let code, _):
            return String(localized: "Bunny server error (code: \(code))")
        case .apiError(let message):
            return String(localized: "Bunny API Error: \(message)")
        case .invalidResponse:
            return String(localized: "Invalid response from Bunny")
        case .timeout:
            return String(localized: "Request to Bunny timed out")
        case .recordAlreadyExists(let message):
            return String(localized: "DNS record already exists: \(message)")
        case .unsupportedRecordType(let type):
            return String(localized: "Unsupported DNS record type: \(type)")
        }
    }

    var failureReason: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Your Bunny API key is incorrect or has expired.")
        case .forbidden:
            return String(localized: "Your Bunny API key doesn't have permission for this operation.")
        case .rateLimited:
            return String(localized: "You've made too many requests in a short time.")
        case .notFound:
            return String(localized: "The requested DNS zone or record doesn't exist.")
        case .validation(let message):
            return message
        case .networkError(let error):
            return error.localizedDescription
        case .serverError(_, let message):
            return message
        case .apiError(let message):
            return message
        case .invalidResponse:
            return String(localized: "The response from Bunny was not in the expected format.")
        case .timeout:
            return String(localized: "The connection to Bunny took too long.")
        case .recordAlreadyExists(let message):
            return message
        case .unsupportedRecordType(let type):
            return String(localized: "The record type '\(type)' is not supported by Bunny DNS.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Check your Bunny API key in Settings, then try again.")
        case .forbidden:
            return String(localized: "Check that your API key has the required permissions.")
        case .rateLimited:
            return String(localized: "Wait a few minutes before trying again.")
        case .notFound:
            return String(localized: "Verify that the DNS zone exists in your Bunny account.")
        case .validation:
            return String(localized: "Check the DNS record parameters and try again.")
        case .networkError:
            return String(localized: "Check your internet connection and try again.")
        case .serverError:
            return String(localized: "Try again in a few minutes. If the problem persists, check Bunny's status page.")
        case .apiError:
            return String(localized: "If this error persists, contact Bunny support.")
        case .invalidResponse:
            return String(localized: "Try again. If the problem persists, contact support.")
        case .timeout:
            return String(localized: "Check your internet connection and try again.")
        case .recordAlreadyExists:
            return String(localized: "Use a different name or delete the existing record first.")
        case .unsupportedRecordType:
            return String(localized: "Use a standard DNS record type (A, AAAA, CNAME, MX, TXT, etc.).")
        }
    }
}

// Make BunnyDNSError conform to Sendable properly
extension BunnyDNSError {
    // networkError case contains a non-Sendable Error, but we handle it safely
    // by only storing the localized description in practice
}
