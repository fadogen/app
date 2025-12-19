import Foundation

nonisolated enum BunMetadataService {

    static func fetchLatestVersion() async throws -> BunMetadata {
        // Create URLSession without cache to avoid cached errors
        let session = DownloadUtilities.createNoCacheSession()

        // Step 1: Get latest release info from GitHub API
        let releaseURL = URL(string: "https://api.github.com/repos/oven-sh/bun/releases/latest")!
        let (releaseData, releaseResponse) = try await session.data(from: releaseURL)

        guard let httpResponse = releaseResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw BunMetadataError.githubAPIFailed
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: releaseData)

        // Extract version from tag_name (e.g., "bun-v1.3.1" → "1.3.1")
        let version = release.tagName.replacingOccurrences(of: "bun-v", with: "")

        // Step 2: Download SHASUMS256.txt to get checksum
        let shasumsURL = URL(string: "https://github.com/oven-sh/bun/releases/latest/download/SHASUMS256.txt")!
        let (shasumsData, shasumsResponse) = try await session.data(from: shasumsURL)

        guard let shasumsHTTP = shasumsResponse as? HTTPURLResponse,
              shasumsHTTP.statusCode == 200 else {
            throw BunMetadataError.shasumsDownloadFailed
        }

        guard let shasumsText = String(data: shasumsData, encoding: .utf8) else {
            throw BunMetadataError.shasumsParsingFailed
        }

        // Extract SHA256 for bun-darwin-aarch64.zip
        let sha256 = try extractSHA256(from: shasumsText, filename: "bun-darwin-aarch64.zip")

        return BunMetadata(
            latest: version,
            filename: "bun-darwin-aarch64.zip",
            sha256: sha256
        )
    }

    private static func extractSHA256(from content: String, filename: String) throws -> String {
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            if line.contains(filename) {
                // Format: "abc123...  bun-darwin-aarch64.zip"
                let components = line.components(separatedBy: .whitespaces)
                if let hash = components.first, !hash.isEmpty {
                    return hash
                }
            }
        }

        throw BunMetadataError.sha256NotFound(filename)
    }
}

// MARK: - GitHub API Models

nonisolated private struct GitHubRelease: Decodable, Sendable {
    let tagName: String

    enum CodingKeys: String, CodingKey, Sendable {
        case tagName = "tag_name"
    }
}

// MARK: - Errors

enum BunMetadataError: LocalizedError {
    case githubAPIFailed
    case shasumsDownloadFailed
    case shasumsParsingFailed
    case sha256NotFound(String)

    var errorDescription: String? {
        switch self {
        case .githubAPIFailed:
            return "Failed to fetch latest Bun release from GitHub API"
        case .shasumsDownloadFailed:
            return "Failed to download SHASUMS256.txt"
        case .shasumsParsingFailed:
            return "Failed to parse SHASUMS256.txt"
        case .sha256NotFound(let filename):
            return "SHA256 not found for \(filename) in SHASUMS256.txt"
        }
    }
}
