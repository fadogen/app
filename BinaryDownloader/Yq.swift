import Foundation

extension BinaryDownloader {
    static func downloadYq() async throws {
        // Step 1: Fetch latest release from GitHub API
        let apiURL = try url(from: "https://api.github.com/repos/mikefarah/yq/releases/latest")
        let apiData = try await fetchGitHubAPI(url: apiURL)

        let release = try JSONDecoder().decode(YqRelease.self, from: apiData)
        let version = release.tagName

        // Step 2: Download binary directly (no checksum - GitHub releases are trusted)
        let sourceFilename = "yq_darwin_arm64"
        let downloadURL = try url(from: "https://github.com/mikefarah/yq/releases/download/\(version)/\(sourceFilename)")
        let (tempURL, _) = try await session.download(from: downloadURL)

        // Step 3: Move binary to Resources/yq and set permissions
        let destinationPath = "\(getResourcesPath())/yq"
        try? FileManager.default.removeItem(atPath: destinationPath)
        try FileManager.default.moveItem(atPath: tempURL.path, toPath: destinationPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath)
    }
}

// MARK: - Models

struct YqRelease: Codable {
    let tagName: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}
