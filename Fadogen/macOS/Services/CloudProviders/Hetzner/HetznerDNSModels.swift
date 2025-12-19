import Foundation

// MARK: - Zone

struct HetznerDNSZone: Codable, Sendable {
    let id: String
    let name: String
    let ttl: Int
    let createdAt: String
    let modifiedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, ttl
        case createdAt = "created"
        case modifiedAt = "modified"
    }
}

struct HetznerDNSZonesResponse: Codable {
    let zones: [HetznerDNSZone]
    let meta: HetznerDNSMeta?
}

struct HetznerDNSZoneResponse: Codable {
    let zone: HetznerDNSZone
}

// MARK: - Record

struct HetznerDNSRecord: Codable, Sendable {
    let id: String
    let type: String
    let name: String
    let value: String
    let zoneID: String
    let createdAt: String
    let modifiedAt: String

    enum CodingKeys: String, CodingKey {
        case id, type, name, value
        case zoneID = "zone_id"
        case createdAt = "created"
        case modifiedAt = "modified"
    }
}

struct HetznerDNSRecordsResponse: Codable {
    let records: [HetznerDNSRecord]
    let meta: HetznerDNSMeta?
}

struct HetznerDNSRecordResponse: Codable {
    let record: HetznerDNSRecord
}

// MARK: - Request

struct HetznerDNSCreateRecordRequest: Codable {
    let name: String
    let type: String
    let value: String
    let zoneID: String
    let ttl: Int?

    enum CodingKeys: String, CodingKey {
        case name, type, value, ttl
        case zoneID = "zone_id"
    }
}

// MARK: - Pagination

struct HetznerDNSMeta: Codable {
    let pagination: HetznerDNSPagination
}

struct HetznerDNSPagination: Codable {
    let page: Int
    let perPage: Int
    let lastPage: Int
    let totalEntries: Int

    enum CodingKeys: String, CodingKey {
        case page
        case perPage = "per_page"
        case lastPage = "last_page"
        case totalEntries = "total_entries"
    }
}

// MARK: - Error

enum HetznerDNSError: Error, Sendable {
    case unauthorized
    case notFound
    case unprocessableEntity(String)
    case rateLimited
    case serverError(Int, String)
    case apiError(String)
    case invalidResponse
    case timeout
    case networkError(Error)
    case recordAlreadyExists
}

struct HetznerDNSErrorResponse: Codable {
    let message: String
    let code: Int?
}
