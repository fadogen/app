import Foundation

// MARK: - Region

struct LinodeRegion {
    let regionId: String     // "us-east", "eu-west"
    let label: String        // "Newark, NJ"
    let country: String      // "us"
}

extension LinodeRegion: Decodable {
    private enum CodingKeys: String, CodingKey {
        case regionId = "id"
        case label
        case country
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        regionId = try container.decode(String.self, forKey: .regionId)
        label = try container.decode(String.self, forKey: .label)
        country = try container.decode(String.self, forKey: .country)
    }
}

struct LinodeRegionsResponse: Decodable {
    let data: [LinodeRegion]
}

// MARK: - Type

struct LinodeType {
    let typeId: String       // "g6-nanode-1"
    let label: String        // "Nanode 1GB"
    let disk: Int            // MB
    let memory: Int          // MB
    let vcpus: Int
    let price: LinodePrice
}

struct LinodePrice: Decodable {
    let hourly: Double?
    let monthly: Double?
}

extension LinodeType: Decodable {
    private enum CodingKeys: String, CodingKey {
        case typeId = "id"
        case label
        case disk
        case memory
        case vcpus
        case price
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        typeId = try container.decode(String.self, forKey: .typeId)
        label = try container.decode(String.self, forKey: .label)
        disk = try container.decode(Int.self, forKey: .disk)
        memory = try container.decode(Int.self, forKey: .memory)
        vcpus = try container.decode(Int.self, forKey: .vcpus)
        price = try container.decode(LinodePrice.self, forKey: .price)
    }
}

struct LinodeTypesResponse: Decodable {
    let data: [LinodeType]
}

// MARK: - Image

struct LinodeImage {
    let id: String           // "linode/debian12"
    let label: String
    let deprecated: Bool
    let vendor: String?
}

extension LinodeImage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, label, deprecated, vendor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        deprecated = try container.decode(Bool.self, forKey: .deprecated)
        vendor = try container.decodeIfPresent(String.self, forKey: .vendor)
    }
}

extension LinodeImage: Sendable {}

struct LinodeImagesResponse: Decodable {
    let data: [LinodeImage]
}

// MARK: - Instance

struct LinodeInstance: Identifiable {
    let id: Int
    let label: String
    let status: String       // "running", "provisioning", "offline", "booting"
    let ipv4: [String]
    let region: String
    let type: String

    var publicIPv4: String? { ipv4.first }
    var isRunning: Bool { status == "running" }
}

extension LinodeInstance: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, label, status, ipv4, region, type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        status = try container.decode(String.self, forKey: .status)
        ipv4 = try container.decode([String].self, forKey: .ipv4)
        region = try container.decode(String.self, forKey: .region)
        type = try container.decode(String.self, forKey: .type)
    }
}

struct LinodeInstancesResponse: Decodable {
    let data: [LinodeInstance]
}

// MARK: - SSH Key

struct LinodeSSHKey: Codable, Identifiable {
    let id: Int
    let label: String
    let sshKey: String

    enum CodingKeys: String, CodingKey {
        case id, label
        case sshKey = "ssh_key"
    }
}

struct LinodeSSHKeysResponse: Decodable {
    let data: [LinodeSSHKey]
}

// MARK: - Error

struct LinodeErrorResponse: Decodable {
    let errors: [LinodeAPIError]
}

struct LinodeAPIError: Decodable {
    let reason: String
    let field: String?
}

enum LinodeError: LocalizedError {
    case unauthorized
    case rateLimited
    case notFound
    case validation(String)
    case networkError(String)
    case serverError(String)
    case apiError(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Invalid or expired API token")
        case .rateLimited:
            return String(localized: "Rate limit exceeded, please try again later")
        case .notFound:
            return String(localized: "Resource not found")
        case .validation(let message):
            return String(localized: "Validation error: \(message)")
        case .networkError(let message):
            return String(localized: "Network error: \(message)")
        case .serverError(let message):
            return String(localized: "Server error: \(message)")
        case .apiError(let message):
            return String(localized: "API error: \(message)")
        case .timeout(let message):
            return String(localized: "Request timed out: \(message)")
        }
    }
}

// MARK: - Protocol Conformance

extension LinodeRegion: @unchecked Sendable {}
extension LinodeType: @unchecked Sendable {}
extension LinodeInstance: @unchecked Sendable {}

nonisolated extension LinodeRegion: Identifiable {
    var id: String { regionId }
}

nonisolated extension LinodeRegion: Hashable {
    static func == (lhs: LinodeRegion, rhs: LinodeRegion) -> Bool {
        lhs.regionId == rhs.regionId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(regionId)
    }
}

nonisolated extension LinodeRegion: ServerRegion {
    var displayName: String { label }
    var slug: String { regionId }
}

nonisolated extension LinodeType: Identifiable {
    var id: String { typeId }
}

nonisolated extension LinodeType: Hashable {
    static func == (lhs: LinodeType, rhs: LinodeType) -> Bool {
        lhs.typeId == rhs.typeId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(typeId)
    }
}

nonisolated extension LinodeType: ServerSize {
    var slug: String { typeId }

    var displayName: String {
        let memoryGB = memory / 1024
        let diskGB = disk / 1024
        let priceStr = String(format: "%.2f", price.monthly ?? 0)
        return "\(typeId) - \(vcpus) CPU, \(memoryGB) GB, \(diskGB) GB ($\(priceStr)/mo)"
    }

    var specs: ServerSpecs {
        ServerSpecs(vcpus: vcpus, memoryMB: memory, diskGB: disk / 1024)
    }

    var priceMonthly: Double {
        price.monthly ?? 0
    }

    func isAvailableInRegion(_ regionSlug: String) -> Bool {
        true  // Linode types are generally available in all regions
    }
}
