import CryptoKit
import Foundation
import Subprocess
import System

struct BinaryDownloader {
    // Base URL for Fadogen binaries hosting
    static let binariesBaseURL = "https://binaries.fadogen.app"

    /// URLSession without cache for all downloads
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// GitHub token from environment (optional, for CI rate limit bypass)
    static let githubToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]

    static func url(from string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw DownloadError.invalidURL(string)
        }
        return url
    }

    static func downloadMetadata<T: Decodable>(
        filename: String,
        type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: try url(from: "\(binariesBaseURL)/\(filename)"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await session.data(for: request)

        guard let metadata = try? JSONDecoder().decode(T.self, from: data) else {
            throw DownloadError.invalidMetadata(filename: filename)
        }

        return metadata
    }

    /// Fetch data from GitHub API with optional authentication
    static func fetchGitHubAPI(url apiURL: URL) async throws -> Data {
        var request = URLRequest(url: apiURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Add authentication if token is available (bypasses rate limit)
        if let token = githubToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DownloadError.invalidMetadata(filename: "GitHub API response")
        }

        return data
    }

    static func getResourcesPath() -> String {
        guard let builtProductsDir = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"],
            let productName = ProcessInfo.processInfo.environment["PRODUCT_NAME"]
        else {
            fatalError("Missing required environment variables: BUILT_PRODUCTS_DIR or PRODUCT_NAME")
        }
        return "\(builtProductsDir)/\(productName).app/Contents/Resources"
    }

    static func verifyChecksum<H: HashFunction>(fileURL: URL, expectedChecksum: String, using: H.Type) throws {
        let data = try Data(contentsOf: fileURL)
        let digest = H.hash(data: data)
        let hashString = digest.compactMap { String(format: "%02x", $0) }.joined()

        guard hashString == expectedChecksum else {
            throw DownloadError.checksumMismatch(expected: expectedChecksum, actual: hashString)
        }
    }

    /// Generic tar archive extraction with optional file filtering and chmod
    static func extractArchive(
        from archiveURL: URL,
        to destinationDir: String,
        extractSpecificFiles: [String]? = nil,
        stripComponents: Int = 0,
        chmodFiles: [String] = []
    ) async throws {
        // Create destination directory
        try FileManager.default.createDirectory(
            atPath: destinationDir,
            withIntermediateDirectories: true,
            attributes: [FileAttributeKey.posixPermissions: 0o755]
        )

        // Build tar arguments
        var arguments = ["-xzf", archiveURL.path, "-C", destinationDir]

        // Add --strip-components if needed
        if stripComponents > 0 {
            arguments.append("--strip-components=\(stripComponents)")
        }

        if let specificFiles = extractSpecificFiles {
            arguments.append(contentsOf: specificFiles)
        }

        // Execute tar extraction with subprocess
        let result = try await Subprocess.run(
            .path("/usr/bin/tar"),
            arguments: .init(arguments),
            output: .discarded,
            error: .discarded
        )

        guard result.terminationStatus.isSuccess else {
            throw DownloadError.extractionFailed
        }

        // Set executable permissions on specified files
        for file in chmodFiles {
            let filePath = "\(destinationDir)/\(file)"
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: filePath
            )
        }
    }

    /// Extracts a zip archive with stripping parent directory and chmod
    static func extractZipArchive(
        from archiveURL: URL,
        to destinationDir: String,
        stripComponents: Int = 1,
        chmodFiles: [String] = []
    ) async throws {
        // Create destination directory
        try FileManager.default.createDirectory(
            atPath: destinationDir,
            withIntermediateDirectories: true,
            attributes: [FileAttributeKey.posixPermissions: 0o755]
        )

        // Create temporary extraction directory
        let tempExtractionDir = "\(destinationDir)/.temp_extract_\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tempExtractionDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        defer {
            try? FileManager.default.removeItem(atPath: tempExtractionDir)
        }

        // Execute unzip extraction
        let result = try await Subprocess.run(
            .path("/usr/bin/unzip"),
            arguments: .init(["-q", archiveURL.path, "-d", tempExtractionDir]),
            output: .discarded,
            error: .discarded
        )

        guard result.terminationStatus.isSuccess else {
            throw DownloadError.extractionFailed
        }

        // Move files while stripping components
        if stripComponents > 0 {
            let contents = try FileManager.default.contentsOfDirectory(atPath: tempExtractionDir)
            guard let topLevelDir = contents.first else {
                throw DownloadError.extractionFailed
            }

            let sourcePath = "\(tempExtractionDir)/\(topLevelDir)"
            let innerContents = try FileManager.default.contentsOfDirectory(atPath: sourcePath)

            for item in innerContents {
                let sourceItem = "\(sourcePath)/\(item)"
                let destItem = "\(destinationDir)/\(item)"

                // Remove destination if exists
                if FileManager.default.fileExists(atPath: destItem) {
                    try FileManager.default.removeItem(atPath: destItem)
                }

                try FileManager.default.moveItem(atPath: sourceItem, toPath: destItem)
            }
        }

        // Set executable permissions on specified files
        for file in chmodFiles {
            let filePath = "\(destinationDir)/\(file)"
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: filePath
            )
        }
    }

    static func run() async throws {
        try await downloadCaddy()
        try await downloadPHP()
        try await downloadComposer()
        try await downloadNode()
        try await downloadMozillaCACert()
        try await downloadSshpass()
        try await downloadAnsible()
        try await downloadCloudflared()
        try await downloadYq()
        try await downloadMailpit()
    }
}
