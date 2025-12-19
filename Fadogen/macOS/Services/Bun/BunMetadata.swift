import Foundation

/// From https://binaries.fadogen.app/metadata-bun.json
nonisolated struct BunMetadata: Decodable, Sendable {
    let latest: String  // e.g., "1.1.38"
    let filename: String
    let sha256: String
}
