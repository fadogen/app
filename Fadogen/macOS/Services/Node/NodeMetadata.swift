import Foundation

/// From https://binaries.fadogen.app/metadata-node.json
nonisolated struct NodeMetadata: Decodable, Sendable {
    let latest: String  // e.g., "22.21.0"
    let filename: String
    let sha256: String
    let isLts: Bool
    let isEol: Bool
}

/// e.g., ["22": NodeMetadata(...), "20": NodeMetadata(...)]
typealias NodeMetadataCollection = [String: NodeMetadata]
