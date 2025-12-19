import CryptoKit
import Foundation

extension BinaryDownloader {
    static func downloadComposer() async throws {
        let metadata = try await downloadMetadata(filename: "metadata-composer.json", type: ComposerMetadata.self)

        let (tempURL, _) = try await session.download(from: try url(from: "\(binariesBaseURL)/\(metadata.filename)"))
        try verifyChecksum(fileURL: tempURL, expectedChecksum: metadata.sha256, using: SHA256.self)
        try await extractArchive(
            from: tempURL,
            to: getResourcesPath(),
            chmodFiles: ["composer"]
        )
    }
}

// MARK: - Models

struct ComposerMetadata: Codable {
    let latest: String
    let sha256: String
    let filename: String
}
