import CryptoKit
import Foundation

private let caddyVersion = "2.10.2"
private let caddyPlatform = "mac_arm64"

extension BinaryDownloader {
    static func downloadCaddy() async throws {
        let checksums = try await downloadChecksums(version: caddyVersion)

        guard let expectedChecksum = checksums[caddyPlatform] else {
            throw DownloadError.unsupportedArchitecture("arm64")
        }

        let downloadURL = try url(from: "https://github.com/caddyserver/caddy/releases/download/v\(caddyVersion)/caddy_\(caddyVersion)_\(caddyPlatform).tar.gz")
        let (tempURL, _) = try await session.download(from: downloadURL)
        try verifyChecksum(fileURL: tempURL, expectedChecksum: expectedChecksum, using: SHA512.self)

        let destinationDir = URL(fileURLWithPath: "\(getResourcesPath())/caddy").deletingLastPathComponent().path
        try await extractArchive(
            from: tempURL,
            to: destinationDir,
            extractSpecificFiles: ["caddy"],
            chmodFiles: ["caddy"]
        )
    }

    private static func downloadChecksums(version: String) async throws -> [String: String] {
        let (data, _) = try await session.data(from: try url(from: "https://github.com/caddyserver/caddy/releases/download/v\(version)/caddy_\(version)_checksums.txt"))

        guard let content = String(data: data, encoding: .utf8) else {
            throw DownloadError.invalidChecksumsFile
        }

        let expectedFilename = "caddy_\(version)_\(caddyPlatform).tar.gz"
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let components = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard components.count >= 2 else { continue }

            if components[1] == expectedFilename {
                return [caddyPlatform: components[0]]
            }
        }

        throw DownloadError.noMacOSChecksums
    }
}
