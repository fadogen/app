import Foundation

extension BinaryDownloader {
    static func downloadMailpit() async throws {
        // Step 1: Fetch latest release from GitHub API
        let apiURL = try url(from: "https://api.github.com/repos/axllent/mailpit/releases/latest")
        let apiData = try await fetchGitHubAPI(url: apiURL)

        let release = try JSONDecoder().decode(MailpitRelease.self, from: apiData)

        // Step 2: Find darwin-arm64 asset
        let assetName = "mailpit-darwin-arm64.tar.gz"
        guard let asset = release.assets.first(where: { $0.name == assetName }) else {
            throw DownloadError.noMacOSChecksums
        }

        // Step 3: Download archive (no checksum available from Mailpit releases)
        let (tempURL, _) = try await session.download(from: try url(from: asset.browserDownloadUrl))

        // Step 4: Extract to Resources/
        try await extractArchive(
            from: tempURL,
            to: getResourcesPath(),
            extractSpecificFiles: ["mailpit"],
            chmodFiles: ["mailpit"]
        )
    }
}

// MARK: - GitHub API Models

struct MailpitRelease: Codable {
    let tagName: String
    let assets: [MailpitAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

struct MailpitAsset: Codable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}
