import Foundation

// MARK: - Location

struct HetznerLocation {
    let hetznerID: Int
    let name: String
    let description: String
    let city: String
    let country: String
}

extension HetznerLocation: Decodable {
    private enum CodingKeys: String, CodingKey {
        case hetznerID = "id"
        case name, description, city, country
    }
}

struct HetznerLocationsResponse: Decodable {
    let locations: [HetznerLocation]
}

// MARK: - Server Type

enum HetznerServerCategory: String, CaseIterable, Sendable, Hashable {
    case arm64 = "ARM64"
    case intel = "INTEL"
    case amd64 = "AMD64"
    case amdDedicated = "AMD DEDICATED"
    case other = "OTHER"
}

struct HetznerServerType {
    let hetznerID: Int
    let name: String
    let description: String
    let cores: Int
    let memory: Double  // GB
    let disk: Int       // GB
    let prices: [HetznerPrice]
    let architecture: String  // "x86" or "arm"
    let cpuType: String       // "shared" or "dedicated"

    nonisolated var priceMonthly: Double {
        prices.first(where: { $0.location == "fsn1" })?.priceMonthlyValue ?? 0.0
    }

    nonisolated var priceFormatted: String {
        let price = prices.first(where: { $0.location == "fsn1" })?.priceMonthlyValue ?? 0.0
        return "€\(String(format: "%.2f", price))/mo"
    }

    nonisolated var memoryMB: Int { Int(memory * 1024) }
    nonisolated var memoryFormatted: String { "\(Int(memory)) GB" }
    nonisolated var diskFormatted: String { "\(disk) GB" }

    nonisolated var category: HetznerServerCategory {
        let nameLower = name.lowercased()

        // ARM64: architecture is "arm" (e.g., CAX series)
        if architecture == "arm" {
            return .arm64
        }

        // Dedicated CPUs: typically AMD EPYC (e.g., DDX, PX series)
        if cpuType == "dedicated" {
            return .amdDedicated
        }

        // Shared CPUs: differentiate by name prefix
        if cpuType == "shared" {
            // CPX series: Intel shared high-performance
            if nameLower.hasPrefix("cpx") {
                return .intel
            }
            // CX series: AMD/Intel shared (standard)
            if nameLower.hasPrefix("cx") {
                return .amd64
            }
        }

        // Fallback for unknown/future server types
        return .other
    }
}

extension HetznerServerType: Decodable {
    private enum CodingKeys: String, CodingKey {
        case hetznerID = "id"
        case name, description, cores, memory, disk, prices
        case architecture
        case cpuType = "cpu_type"
    }
}

struct HetznerPrice: Decodable {
    let location: String
    let priceHourly: HetznerPriceValue
    let priceMonthly: HetznerPriceValue

    enum CodingKeys: String, CodingKey {
        case location
        case priceHourly = "price_hourly"
        case priceMonthly = "price_monthly"
    }

    nonisolated var priceMonthlyValue: Double {
        Double(priceMonthly.gross) ?? 0.0
    }
}

extension HetznerPrice: Sendable {}
nonisolated extension HetznerPrice: Hashable {}

struct HetznerPriceValue: Decodable {
    let net: String
    let gross: String
}

extension HetznerPriceValue: Sendable {}
nonisolated extension HetznerPriceValue: Hashable {}

struct HetznerServerTypesResponse: Decodable {
    let serverTypes: [HetznerServerType]

    enum CodingKeys: String, CodingKey {
        case serverTypes = "server_types"
    }
}

// MARK: - Image

struct HetznerImage {
    let hetznerID: Int
    let name: String
    let description: String
    let osFlavor: String
    let osVersion: String
    let type: String
    let architecture: String
}

extension HetznerImage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case hetznerID = "id"
        case name
        case description
        case osFlavor = "os_flavor"
        case osVersion = "os_version"
        case type
        case architecture
    }
}

extension HetznerImage: Sendable {}

struct HetznerImagesResponse: Decodable {
    let images: [HetznerImage]
}

// MARK: - SSH Key

struct HetznerSSHKey: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let fingerprint: String
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case id, name, fingerprint
        case publicKey = "public_key"
    }
}

struct HetznerSSHKeyResponse: Codable {
    let sshKey: HetznerSSHKey

    enum CodingKeys: String, CodingKey {
        case sshKey = "ssh_key"
    }
}

struct HetznerSSHKeysResponse: Codable {
    let sshKeys: [HetznerSSHKey]

    enum CodingKeys: String, CodingKey {
        case sshKeys = "ssh_keys"
    }
}

// MARK: - Server

struct HetznerServer: Identifiable, Sendable {
    let id: Int
    let name: String
    let status: String
    let publicIPv4: String?

    var isActive: Bool { status == "running" }
}

extension HetznerServer: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, status
        case publicNet = "public_net"
    }

    private enum PublicNetKeys: String, CodingKey {
        case ipv4
    }

    private enum IPv4Keys: String, CodingKey {
        case ip
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)

        publicIPv4 = Self.extractPublicIPv4(from: container)
    }

    private static func extractPublicIPv4(from container: KeyedDecodingContainer<CodingKeys>) -> String? {
        guard let publicNetContainer = try? container.nestedContainer(keyedBy: PublicNetKeys.self, forKey: .publicNet),
              let ipv4Container = try? publicNetContainer.nestedContainer(keyedBy: IPv4Keys.self, forKey: .ipv4),
              let ip = try? ipv4Container.decode(String.self, forKey: .ip) else {
            return nil
        }
        return ip
    }
}

struct HetznerServerResponse: Decodable {
    let server: HetznerServer
}

struct HetznerServerCreateResponse: Decodable {
    let server: HetznerServer
    let action: HetznerAction?
}

struct HetznerAction: Decodable, Sendable {
    let id: Int
    let status: String
    let command: String
}

// MARK: - Error

struct HetznerErrorResponse: Codable {
    let code: String
    let message: String
}

struct HetznerErrorWrapper: Codable {
    let error: HetznerErrorResponse
}

// MARK: - Protocol Conformance

extension HetznerLocation: @unchecked Sendable {}
extension HetznerServerType: @unchecked Sendable {}

nonisolated extension HetznerLocation: Identifiable {
    var id: String { String(hetznerID) }
}

nonisolated extension HetznerLocation: Hashable {}

nonisolated extension HetznerLocation: ServerRegion {
    var displayName: String { "\(city) (\(name))" }
    var slug: String { name }
}

nonisolated extension HetznerServerType: Identifiable {
    var id: String { String(hetznerID) }
}

nonisolated extension HetznerServerType: Hashable {}

nonisolated extension HetznerServerType: ServerSize {
    var displayName: String {
        "\(name) - \(cores) CPU, \(memoryFormatted), \(diskFormatted) (\(priceFormatted))"
    }

    var slug: String { name }

    var specs: ServerSpecs {
        ServerSpecs(vcpus: cores, memoryMB: memoryMB, diskGB: disk)
    }

    func isAvailableInRegion(_ regionSlug: String) -> Bool {
        prices.contains(where: { $0.location == regionSlug })
    }

    func displayNameForRegion(_ regionSlug: String) -> String {
        let price = prices.first(where: { $0.location == regionSlug })?.priceMonthlyValue ?? 0.0
        let priceFormatted = "€\(String(format: "%.2f", price))/mo"
        return "\(name) - \(cores) CPU, \(memoryFormatted), \(diskFormatted) (\(priceFormatted))"
    }
}
