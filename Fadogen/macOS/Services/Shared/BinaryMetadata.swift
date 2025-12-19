import Foundation

protocol BinaryMetadata: Decodable, Sendable {
    var latest: String { get }
    var filename: String { get }
    var sha256: String { get }
}

// MARK: - Conformance

extension PHPMetadata: BinaryMetadata {}
extension ServiceMetadata: BinaryMetadata {}
extension ComposerMetadata: BinaryMetadata {}
extension NodeMetadata: BinaryMetadata {}
extension BunMetadata: BinaryMetadata {}
