import Foundation

/// From https://binaries.fadogen.app/metadata-composer.json
nonisolated struct ComposerMetadata: Decodable, Sendable {
    let latest: String  // e.g., "2.8.12"
    let filename: String
    let sha256: String
}
