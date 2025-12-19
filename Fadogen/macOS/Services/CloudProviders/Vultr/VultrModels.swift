import Foundation

// MARK: - Region

struct VultrRegion {
    let regionId: String     // "ewr", "ams", "fra"
    let city: String         // "New Jersey", "Amsterdam", "Frankfurt"
    let country: String      // "US", "NL", "DE"
    let continent: String    // "North America", "Europe"
}

extension VultrRegion: Decodable {
    private enum CodingKeys: String, CodingKey {
        case regionId = "id"
        case city, country, continent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        regionId = try container.decode(String.self, forKey: .regionId)
        city = try container.decode(String.self, forKey: .city)
        country = try container.decode(String.self, forKey: .country)
        continent = try container.decode(String.self, forKey: .continent)
    }
}

struct VultrRegionsResponse: Decodable {
    let regions: [VultrRegion]
}

// MARK: - Plan

struct VultrPlan {
    let planId: String       // "vc2-1c-1gb"
    let vcpuCount: Int       // 1, 2, 4...
    let ram: Int             // MB
    let disk: Int            // GB
    let bandwidth: Int       // GB/month
    let monthlyCost: Double  // USD
    let locations: [String]  // Available regions
}

extension VultrPlan: Decodable {
    private enum CodingKeys: String, CodingKey {
        case planId = "id"
        case vcpuCount = "vcpu_count"
        case ram
        case disk
        case bandwidth
        case monthlyCost = "monthly_cost"
        case locations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planId = try container.decode(String.self, forKey: .planId)
        vcpuCount = try container.decode(Int.self, forKey: .vcpuCount)
        ram = try container.decode(Int.self, forKey: .ram)
        disk = try container.decode(Int.self, forKey: .disk)
        bandwidth = try container.decode(Int.self, forKey: .bandwidth)
        monthlyCost = try container.decode(Double.self, forKey: .monthlyCost)
        locations = try container.decode([String].self, forKey: .locations)
    }
}

struct VultrPlansResponse: Decodable {
    let plans: [VultrPlan]
}

// MARK: - OS

struct VultrOS {
    let id: Int              // 2136
    let name: String         // "Debian 13 x64 (bookworm)"
    let family: String       // "debian"
}

extension VultrOS: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, family
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        family = try container.decode(String.self, forKey: .family)
    }
}

extension VultrOS: Sendable {}

struct VultrOSResponse: Decodable {
    let os: [VultrOS]
}

// MARK: - Instance

struct VultrInstance: Identifiable {
    let id: String
    let label: String
    let status: String       // "active", "pending", "stopped", "installing"
    let powerStatus: String  // "running", "stopped"
    let mainIP: String
    let region: String
    let plan: String

    var publicIPv4: String? { mainIP != "0.0.0.0" ? mainIP : nil }
    var isActive: Bool { status == "active" && powerStatus == "running" }
}

extension VultrInstance: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, label, status
        case powerStatus = "power_status"
        case mainIP = "main_ip"
        case region, plan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        status = try container.decode(String.self, forKey: .status)
        powerStatus = try container.decode(String.self, forKey: .powerStatus)
        mainIP = try container.decode(String.self, forKey: .mainIP)
        region = try container.decode(String.self, forKey: .region)
        plan = try container.decode(String.self, forKey: .plan)
    }
}

struct VultrInstanceResponse: Decodable {
    let instance: VultrInstance
}

struct VultrInstancesResponse: Decodable {
    let instances: [VultrInstance]
}

// MARK: - SSH Key

struct VultrSSHKey: Codable, Identifiable {
    let id: String
    let name: String
    let sshKey: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case sshKey = "ssh_key"
    }
}

struct VultrSSHKeyResponse: Decodable {
    let sshKey: VultrSSHKey

    enum CodingKeys: String, CodingKey {
        case sshKey = "ssh_key"
    }
}

struct VultrSSHKeysResponse: Decodable {
    let sshKeys: [VultrSSHKey]

    enum CodingKeys: String, CodingKey {
        case sshKeys = "ssh_keys"
    }
}

// MARK: - Error

struct VultrErrorResponse: Decodable {
    let error: String
    let status: Int?
}

enum VultrError: LocalizedError {
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

extension VultrRegion: @unchecked Sendable {}
extension VultrPlan: @unchecked Sendable {}
extension VultrInstance: @unchecked Sendable {}

nonisolated extension VultrRegion: Identifiable {
    var id: String { regionId }
}

nonisolated extension VultrRegion: Hashable {
    static func == (lhs: VultrRegion, rhs: VultrRegion) -> Bool {
        lhs.regionId == rhs.regionId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(regionId)
    }
}

nonisolated extension VultrRegion: ServerRegion {
    var displayName: String { "\(city), \(country)" }
    var slug: String { regionId }
}

nonisolated extension VultrPlan: Identifiable {
    var id: String { planId }
}

nonisolated extension VultrPlan: Hashable {
    static func == (lhs: VultrPlan, rhs: VultrPlan) -> Bool {
        lhs.planId == rhs.planId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(planId)
    }
}

nonisolated extension VultrPlan: ServerSize {
    var slug: String { planId }

    var displayName: String {
        let ramGB = ram / 1024
        let priceStr = String(format: "%.2f", monthlyCost)
        return "\(planId) - \(vcpuCount) CPU, \(ramGB) GB, \(disk) GB ($\(priceStr)/mo)"
    }

    var specs: ServerSpecs {
        ServerSpecs(vcpus: vcpuCount, memoryMB: ram, diskGB: disk)
    }

    var priceMonthly: Double {
        monthlyCost
    }

    func isAvailableInRegion(_ regionSlug: String) -> Bool {
        locations.contains(regionSlug)
    }
}
