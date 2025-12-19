import Foundation

/// From https://binaries.fadogen.app/metadata-php.json
nonisolated struct PHPMetadata: Decodable, Sendable {
    let latest: String  // e.g., "8.4.2"
    let filename: String
    let sha256: String
    let isEol: Bool
}

/// e.g., ["8.4": PHPMetadata(...), "8.3": PHPMetadata(...)]
typealias PHPMetadataCollection = [String: PHPMetadata]
