import Foundation

extension BinaryDownloader {
    static func downloadCloudflared() async throws {
        // Step 1: Fetch latest release from GitHub API
        let apiURL = try url(from: "https://api.github.com/repos/cloudflare/cloudflared/releases/latest")
        let apiData = try await fetchGitHubAPI(url: apiURL)

        let release = try JSONDecoder().decode(CloudflaredRelease.self, from: apiData)

        // Step 2: Find darwin-arm64 asset and get its browser_download_url
        let targetFilename = "cloudflared-darwin-arm64.tgz"
        guard let asset = release.assets.first(where: { $0.name == targetFilename }) else {
            throw DownloadError.noMacOSChecksums
        }

        // Step 3: Download archive (no checksum - Cloudflare publishes incorrect checksums)
        let (tempURL, _) = try await session.download(from: try url(from: asset.browserDownloadUrl))

        // Step 4: Extract archive to Resources/
        try await extractArchive(
            from: tempURL,
            to: getResourcesPath(),
            extractSpecificFiles: ["cloudflared"],
            chmodFiles: ["cloudflared"]
        )
    }
}

// MARK: - GitHub API Models

struct CloudflaredRelease: Codable {
    let tagName: String
    let body: String
    let assets: [CloudflaredAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }
}

struct CloudflaredAsset: Codable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}
