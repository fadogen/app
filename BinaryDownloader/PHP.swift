import CryptoKit
import Foundation

extension BinaryDownloader {
    static func downloadPHP() async throws {
        let metadata = try await downloadMetadata(filename: "metadata-php.json", type: PHPMetadata.self)

        // Use second-to-last version for stability (or last if only one exists)
        let sortedVersions = metadata.sorted { $0.key.compare($1.key, options: .numeric) == .orderedAscending }
        guard let phpVersionInfo = (sortedVersions.count >= 2 ? sortedVersions[sortedVersions.count - 2].value : sortedVersions.last?.value) else {
            throw DownloadError.noPHPLatestVersion
        }

        // STRICT: Use filename from metadata-php.json - no hardcoded URL construction
        let (tempURL, _) = try await session.download(from: try url(from: "\(binariesBaseURL)/\(phpVersionInfo.filename)"))
        try verifyChecksum(fileURL: tempURL, expectedChecksum: phpVersionInfo.sha256, using: SHA256.self)
        try await extractArchive(
            from: tempURL,
            to: getResourcesPath(),
            chmodFiles: ["php-cli", "php-fpm"]
        )
    }
}

// MARK: - Models

typealias PHPMetadata = [String: PHPVersionInfo]

struct PHPVersionInfo: Codable {
    let latest: String
    let filename: String
    let sha256: String
}
