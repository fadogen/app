import CryptoKit
import Foundation

extension BinaryDownloader {
    static func downloadNode() async throws {
        // Step 1: Fetch LTS versions from endoflife.date API
        let apiURL = try url(from: "https://endoflife.date/api/v1/products/nodejs")
        let (apiData, apiResponse) = try await session.data(from: apiURL)

        guard let httpResponse = apiResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DownloadError.invalidMetadata(filename: "endoflife.date API response")
        }

        // Decode API response
        let apiWrapper = try JSONDecoder().decode(EndOfLifeAPIResponse.self, from: apiData)
        let allVersions = apiWrapper.result.releases

        // Filter to get CURRENTLY active LTS versions (isLts = true, isEol = false)
        let ltsVersions = allVersions.filter { $0.isLts && !$0.isEol }

        // Sort by cycle (descending) and get the latest LTS
        guard let latestLTS = ltsVersions.sorted(by: { Int($0.cycle) ?? 0 > Int($1.cycle) ?? 0 }).first else {
            throw DownloadError.noNodeLTSVersion
        }

        let version = latestLTS.latestVersion

        // Step 2: Download SHASUMS256.txt from nodejs.org
        let (shasumsData, _) = try await session.data(from: try url(from: "https://nodejs.org/dist/v\(version)/SHASUMS256.txt"))

        guard let shasumsText = String(data: shasumsData, encoding: .utf8) else {
            throw DownloadError.invalidChecksumsFile
        }

        // Extract SHA256 for node-vX.Y.Z-darwin-arm64.tar.gz
        let targetFilename = "node-v\(version)-darwin-arm64.tar.gz"
        guard let sha256 = extractSHA256(from: shasumsText, filename: targetFilename) else {
            throw DownloadError.noMacOSChecksums
        }

        // Step 3: Download archive
        let (tempURL, _) = try await session.download(from: try url(from: "https://nodejs.org/dist/v\(version)/\(targetFilename)"))

        // Step 4: Verify checksum
        try verifyChecksum(fileURL: tempURL, expectedChecksum: sha256, using: SHA256.self)

        // Step 5: Extract archive to Resources/node/ (strip 1 level)
        let destinationDir = "\(getResourcesPath())/node"
        try await extractArchive(
            from: tempURL,
            to: destinationDir,
            stripComponents: 1,
            chmodFiles: ["bin/node"]
        )
    }

    /// Extracts SHA256 hash for a specific filename from SHASUMS256.txt content
    private static func extractSHA256(from content: String, filename: String) -> String? {
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            if line.contains(filename) {
                // Format: "abc123...  node-v22.21.0-darwin-arm64.tar.gz"
                let components = line.components(separatedBy: .whitespaces)
                if let hash = components.first, !hash.isEmpty {
                    return hash
                }
            }
        }

        return nil
    }
}

// MARK: - EndOfLife.date API Models

struct EndOfLifeAPIResponse: Codable {
    let result: EndOfLifeResult
}

struct EndOfLifeResult: Codable {
    let releases: [EndOfLifeVersion]
}

struct EndOfLifeVersion: Codable {
    let cycle: String         // Version number (e.g., "22", "20")
    let latest: LatestVersion // Latest patch version info
    let isLts: Bool           // Whether version is CURRENTLY in LTS
    let isEol: Bool           // Whether version has reached End of Life

    enum CodingKeys: String, CodingKey {
        case cycle = "name"  // API v1 uses "name" instead of "cycle"
        case latest
        case isLts
        case isEol
    }

    var latestVersion: String {
        latest.name
    }
}

struct LatestVersion: Codable {
    let name: String // Version number (e.g., "22.21.0")
}
