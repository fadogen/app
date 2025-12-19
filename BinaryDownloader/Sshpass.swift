import CryptoKit
import Foundation

extension BinaryDownloader {
    static func downloadSshpass() async throws {
        let metadata = try await downloadMetadata(filename: "metadata-sshpass.json", type: SshpassMetadata.self)

        let (tempURL, _) = try await session.download(from: try url(from: "\(binariesBaseURL)/\(metadata.filename)"))
        try verifyChecksum(fileURL: tempURL, expectedChecksum: metadata.sha256, using: SHA256.self)
        try await extractArchive(
            from: tempURL,
            to: getResourcesPath(),
            chmodFiles: ["sshpass"]
        )
    }
}

// MARK: - Models

struct SshpassMetadata: Codable {
    let version: String
    let sha256: String
    let filename: String
}
