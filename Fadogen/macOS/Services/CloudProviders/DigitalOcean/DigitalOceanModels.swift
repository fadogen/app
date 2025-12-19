import Foundation

// MARK: - Utility

/// Skips unknown JSON fields during decoding
private struct AnyCodable: Decodable {
    init(from decoder: Decoder) throws {
        // Accept anything, discard everything - allows skipping unknown fields
        if let container = try? decoder.singleValueContainer() {
            // Try to decode as various types, discard the result
            if (try? container.decode(Bool.self)) != nil { return }
            if (try? container.decode(Int.self)) != nil { return }
            if (try? container.decode(Double.self)) != nil { return }
            if (try? container.decode(String.self)) != nil { return }
        }
    }
}

// MARK: - Region

struct DORegion {
    let slug: String
    let name: String
    let available: Bool
}

extension DORegion: Decodable {
    private enum CodingKeys: String, CodingKey {
        case slug, name, available
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decode(String.self, forKey: .name)
        available = try container.decode(Bool.self, forKey: .available)
    }
}

struct DORegionsResponse: Decodable {
    let regions: [DORegion]
}

// MARK: - Size

struct DOSize {
    let slug: String
    let memory: Int  // MB
    let vcpus: Int
    let disk: Int  // GB
    let priceMonthly: Double
    let available: Bool

    nonisolated var memoryFormatted: String {
        memory >= 1024 ? "\(memory / 1024) GB" : "\(memory) MB"
    }

    nonisolated var diskFormatted: String { "\(disk) GB" }
    nonisolated var priceFormatted: String { "$\(String(format: "%.2f", priceMonthly))/mo" }
}

extension DOSize: Decodable {
    private enum CodingKeys: String, CodingKey {
        case slug, memory, vcpus, disk, available
        case priceMonthly = "price_monthly"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        memory = try container.decode(Int.self, forKey: .memory)
        vcpus = try container.decode(Int.self, forKey: .vcpus)
        disk = try container.decode(Int.self, forKey: .disk)
        priceMonthly = try container.decode(Double.self, forKey: .priceMonthly)
        available = try container.decode(Bool.self, forKey: .available)
    }
}

struct DOSizesResponse: Decodable {
    let sizes: [DOSize]
}

// MARK: - Image

struct DOImage: Decodable, Sendable {
    let id: Int
    let name: String
    let distribution: String
    let slug: String
    let type: String
}

struct DOImagesResponse: Decodable {
    let images: [DOImage]
}

// MARK: - SSH Key

struct DOSSHKey: Codable, Identifiable {
    let id: Int
    let fingerprint: String
    let publicKey: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id, fingerprint, name
        case publicKey = "public_key"
    }
}

struct DOSSHKeysResponse: Codable {
    let sshKeys: [DOSSHKey]
    enum CodingKeys: String, CodingKey { case sshKeys = "ssh_keys" }
}

struct DOSSHKeyResponse: Codable {
    let sshKey: DOSSHKey

    enum CodingKeys: String, CodingKey {
        case sshKey = "ssh_key"
    }
}

// MARK: - Droplet

struct DODroplet: Identifiable {
    let id: Int
    let name: String
    let status: String
    let publicIPv4: String?

    var isActive: Bool { status == "active" }
}

extension DODroplet: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, status, networks
    }

    private enum NetworkKeys: String, CodingKey {
        case v4
    }

    private enum InterfaceKeys: String, CodingKey {
        case ipAddress = "ip_address"
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        publicIPv4 = Self.extractPublicIPv4(from: container)
    }

    private static func extractPublicIPv4(from container: KeyedDecodingContainer<CodingKeys>) -> String? {
        guard let networksContainer = try? container.nestedContainer(keyedBy: NetworkKeys.self, forKey: .networks) else {
            return nil
        }

        // Try to get v4 array
        guard var v4Array = try? networksContainer.nestedUnkeyedContainer(forKey: .v4) else {
            return nil
        }

        // Iterate through v4 interfaces looking for public IP
        while !v4Array.isAtEnd {
            // Try to decode this interface
            if let interface = try? v4Array.nestedContainer(keyedBy: InterfaceKeys.self),
               let type = try? interface.decode(String.self, forKey: .type),
               type == "public",
               let ip = try? interface.decode(String.self, forKey: .ipAddress) {
                return ip
            } else {
                // Skip this interface gracefully (might have unknown fields)
                _ = try? v4Array.decode(AnyCodable.self)
            }
        }

        return nil
    }
}

struct DODropletResponse: Decodable {
    let droplet: DODroplet
}

// MARK: - Error

struct DOErrorResponse: Codable {
    let id: String
    let message: String
}

struct DOErrorWrapper: Codable {
    let errors: [DOErrorResponse]
}

// MARK: - Protocol Conformance

extension DORegion: @unchecked Sendable {}
extension DOSize: @unchecked Sendable {}

nonisolated extension DORegion: Identifiable {
    var id: String { slug }
}

nonisolated extension DORegion: Hashable {}

nonisolated extension DORegion: ServerRegion {
    var displayName: String { name }
}

nonisolated extension DOSize: Identifiable {
    var id: String { slug }
}

nonisolated extension DOSize: Hashable {}

nonisolated extension DOSize: ServerSize {
    var displayName: String {
        "\(slug) - \(vcpus) CPU, \(memoryFormatted), \(diskFormatted) (\(priceFormatted))"
    }

    var specs: ServerSpecs {
        ServerSpecs(vcpus: vcpus, memoryMB: memory, diskGB: disk)
    }

    func isAvailableInRegion(_ regionSlug: String) -> Bool {
        true  // DigitalOcean sizes are available in all regions
    }
}
