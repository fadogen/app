import CryptoKit
import Foundation

extension BinaryDownloader {
    static func downloadYq() async throws {
        // Step 1: Fetch latest release from GitHub API
        let apiURL = try url(from: "https://api.github.com/repos/mikefarah/yq/releases/latest")
        let apiData = try await fetchGitHubAPI(url: apiURL)

        let release = try JSONDecoder().decode(YqRelease.self, from: apiData)
        let version = release.tagName

        // Step 2: Download checksums file
        let (checksumsData, _) = try await session.data(from: try url(from: "https://github.com/mikefarah/yq/releases/download/\(version)/checksums"))

        guard let checksumsText = String(data: checksumsData, encoding: .utf8) else {
            throw DownloadError.invalidChecksumsFile
        }

        // Step 3: Extract SHA256 for yq_darwin_arm64 (plain binary, field 19)
        let sourceFilename = "yq_darwin_arm64"
        guard let sha256 = extractYqChecksum(from: checksumsText, filename: sourceFilename) else {
            throw DownloadError.noMacOSChecksums
        }

        // Step 4: Download binary directly
        let downloadURL = try url(from: "https://github.com/mikefarah/yq/releases/download/\(version)/\(sourceFilename)")
        let (tempURL, _) = try await session.download(from: downloadURL)

        // Step 5: Verify checksum
        try verifyChecksum(fileURL: tempURL, expectedChecksum: sha256, using: SHA256.self)

        // Step 6: Move binary to Resources/yq and set permissions
        let destinationPath = "\(getResourcesPath())/yq"
        try? FileManager.default.removeItem(atPath: destinationPath)
        try FileManager.default.moveItem(atPath: tempURL.path, toPath: destinationPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath)
    }

    /// Extracts SHA256 hash for a specific filename from yq checksums file
    private static func extractYqChecksum(from content: String, filename: String) -> String? {
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            if line.hasPrefix(filename) {
                // Format: "filename  CRC32  MD4  MD5  ...  SHA-256(field19)  ..."
                // SHA-256 is at index 18 (0-indexed) = field 19 (1-indexed)
                let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if components.count > 18, components[0] == filename {
                    return components[18]  // SHA-256 at index 18
                }
            }
        }

        return nil
    }
}

// MARK: - Models

struct YqRelease: Codable {
    let tagName: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}
