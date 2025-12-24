import Foundation

private let caddyVersion = "2.10.2"
private let caddyPlatform = "mac_arm64"

extension BinaryDownloader {
    static func downloadCaddy() async throws {
        // Download from GitHub releases (no checksum - GitHub releases are trusted)
        let downloadURL = try url(from: "https://github.com/caddyserver/caddy/releases/download/v\(caddyVersion)/caddy_\(caddyVersion)_\(caddyPlatform).tar.gz")
        let (tempURL, _) = try await session.download(from: downloadURL)

        let destinationDir = URL(fileURLWithPath: "\(getResourcesPath())/caddy").deletingLastPathComponent().path
        try await extractArchive(
            from: tempURL,
            to: destinationDir,
            extractSpecificFiles: ["caddy"],
            chmodFiles: ["caddy"]
        )
    }
}
