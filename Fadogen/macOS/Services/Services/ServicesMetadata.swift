import Foundation

/// From https://binaries.fadogen.app/metadata-services.json
nonisolated struct ServiceMetadata: Decodable, Sendable {
    let latest: String  // e.g., "10.11.14"
    let sha256: String
    let filename: String
}

/// e.g., { "mariadb": { "10": ServiceMetadata(...) }, "mysql": { "8": ... } }
typealias ServiceMetadataCollection = [String: [String: ServiceMetadata]]
