import Foundation

nonisolated enum NodeMetadataService {

    static func fetchLTSVersions() async throws -> NodeMetadataCollection {
        // Create URLSession without cache to avoid cached errors
        let session = DownloadUtilities.createNoCacheSession()

        // Step 1: Fetch version data from endoflife.date API v1
        let apiURL = URL(string: "https://endoflife.date/api/v1/products/nodejs")!
        let (data, response) = try await session.data(from: apiURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NodeMetadataError.endOfLifeAPIFailed
        }

        // Decode API v1 response (wrapper object with result.releases)
        let wrapper = try JSONDecoder().decode(EndOfLifeAPIResponse.self, from: data)
        let allVersions = wrapper.result.releases

        // Step 2: Fetch SHA256 for each version (all versions: Current, LTS, EOL)
        var metadata: NodeMetadataCollection = [:]

        for version in allVersions {
            let major = version.cycle
            let latest = version.latestVersion

            if let sha256 = try? await fetchSHA256(for: latest) {
                metadata[major] = NodeMetadata(
                    latest: latest,
                    filename: "node-v\(latest)-darwin-arm64.tar.gz",
                    sha256: sha256,
                    isLts: version.isLts,
                    isEol: version.isEol
                )
            }
        }

        return metadata
    }

    private static func fetchSHA256(for version: String) async throws -> String {
        let session = DownloadUtilities.createNoCacheSession()
        let shasumsURL = URL(string: "https://nodejs.org/dist/v\(version)/SHASUMS256.txt")!
        let (data, response) = try await session.data(from: shasumsURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NodeMetadataError.shasumsDownloadFailed(version)
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw NodeMetadataError.shasumsParsingFailed
        }

        return try extractSHA256(from: content, filename: "node-v\(version)-darwin-arm64.tar.gz")
    }

    private static func extractSHA256(from content: String, filename: String) throws -> String {
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

        throw NodeMetadataError.sha256NotFound(filename)
    }
}

// MARK: - EndOfLife.date API v1 Models

nonisolated private struct EndOfLifeAPIResponse: Decodable, Sendable {
    let result: EndOfLifeResult
}

nonisolated private struct EndOfLifeResult: Decodable, Sendable {
    let releases: [EndOfLifeVersion]
}

nonisolated private struct EndOfLifeVersion: Decodable, Sendable {
    let cycle: String         // Version number (e.g., "22", "20")
    let latest: LatestVersion // Latest patch version info
    let isLts: Bool           // Whether version is CURRENTLY in LTS (true/false)
    let isEol: Bool           // Whether version has reached End of Life (true/false)

    enum CodingKeys: String, CodingKey, Sendable {
        case cycle = "name"  // API v1 uses "name" instead of "cycle"
        case latest
        case isLts
        case isEol
    }

    // Computed property: latest version string
    var latestVersion: String {
        latest.name
    }
}

nonisolated private struct LatestVersion: Decodable, Sendable {
    let name: String // Version number (e.g., "22.21.0")
}

// MARK: - Errors

enum NodeMetadataError: LocalizedError {
    case endOfLifeAPIFailed
    case decodingFailed(String)
    case shasumsDownloadFailed(String)
    case shasumsParsingFailed
    case sha256NotFound(String)

    var errorDescription: String? {
        switch self {
        case .endOfLifeAPIFailed:
            return "Failed to fetch Node.js versions from endoflife.date API"
        case .decodingFailed(let details):
            return "Failed to decode Node.js metadata: \(details)"
        case .shasumsDownloadFailed(let version):
            return "Failed to download SHASUMS256.txt for Node.js \(version)"
        case .shasumsParsingFailed:
            return "Failed to parse SHASUMS256.txt"
        case .sha256NotFound(let filename):
            return "SHA256 not found for \(filename)"
        }
    }
}
