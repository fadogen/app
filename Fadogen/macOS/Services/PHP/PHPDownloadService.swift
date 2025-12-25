import Foundation
import OSLog
import Subprocess
import System

/// Wrapper around GenericDownloadService for PHP-specific operations
nonisolated enum PHPDownloadService {

    private static let logger = Logger(subsystem: "com.fadogen.app", category: "PHPDownloadService")

    // MARK: - Public

    static func download(
        major: String,
        metadata: PHPMetadata,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        do {
            return try await GenericDownloadService.download(
                baseURL: GenericDownloadService.binariesBaseURL + "/",
                metadata: metadata,
                identifier: "PHP \(major)",
                progressHandler: progressHandler
            )
        } catch let error as DownloadError {
            // Convert generic DownloadError to PHP-specific error
            throw convertToPHPError(error, major: major)
        }
    }

    /// Also extracts Xdebug extension to the config directory
    static func extractAndInstall(
        archiveURL: URL,
        major: String
    ) async throws {
        let binDirectory = FadogenPaths.binDirectory
        let configDirectory = FadogenPaths.configPath(for: major)
        let versionNumber = major.replacingOccurrences(of: ".", with: "")

        // Create unique temp directory for extraction
        let extractionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        // Cleanup on exit
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: extractionDir)
        }

        // Create extraction directory
        try FileManager.default.createDirectory(
            at: extractionDir,
            withIntermediateDirectories: true,
            attributes: [FileAttributeKey.posixPermissions: 0o755]
        )

        // Extract archive
        let result = try await Subprocess.run(
            .path("/usr/bin/tar"),
            arguments: ["-xzf", archiveURL.path, "-C", extractionDir.path],
            output: .discarded,
            error: .bytes(limit: 4096)
        )

        guard result.terminationStatus.isSuccess else {
            let errorOutput = String(bytes: result.standardError, encoding: .utf8) ?? "unknown error"
            throw PHPDownloadError.extractionFailed("tar extraction failed: \(errorOutput)")
        }

        // Ensure bin directory exists
        try FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true,
            attributes: [FileAttributeKey.posixPermissions: 0o755]
        )

        // Move and rename PHP binaries
        let binaries = [
            ("php-cli", "php\(versionNumber)"),
            ("php-fpm", "php\(versionNumber)-fpm")
        ]

        for (from, to) in binaries {
            let sourceURL = extractionDir.appendingPathComponent(from)
            let destURL = binDirectory.appendingPathComponent(to)

            // Remove existing file if present
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
        }

        // Extract Xdebug extension to config directory
        let xdebugSource = extractionDir
            .appendingPathComponent("extensions")
            .appendingPathComponent("xdebug.so")

        if FileManager.default.fileExists(atPath: xdebugSource.path) {
            // Ensure config directory exists
            try FileManager.default.createDirectory(
                at: configDirectory,
                withIntermediateDirectories: true,
                attributes: [FileAttributeKey.posixPermissions: 0o755]
            )

            let xdebugDest = configDirectory.appendingPathComponent("xdebug.so")

            // Remove existing file if present
            try? FileManager.default.removeItem(at: xdebugDest)
            try FileManager.default.moveItem(at: xdebugSource, to: xdebugDest)

            logger.info("Xdebug extension installed for PHP \(major)")
        } else {
            logger.warning("Xdebug extension not found in archive for PHP \(major)")
        }

        logger.info("PHP \(major) installed successfully")
    }

    // MARK: - Private

    private static func convertToPHPError(_ error: DownloadError, major: String) -> PHPDownloadError {
        switch error {
        case .downloadFailed(_, let underlyingError):
            return .downloadFailed(major, underlyingError)
        case .checksumMismatch(let expected, let actual):
            return .checksumMismatch(expected: expected, actual: actual)
        case .extractionFailed(let reason):
            return .extractionFailed(reason)
        case .invalidMetadata:
            return .invalidMetadata
        }
    }
}

// MARK: - Error Types

enum PHPDownloadError: LocalizedError {
    case downloadFailed(String, Error)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let version, let error):
            return "Failed to download PHP \(version): \(error.localizedDescription)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch - expected: \(expected), actual: \(actual)"
        case .extractionFailed(let reason):
            return "Failed to extract archive: \(reason)"
        case .invalidMetadata:
            return "Invalid or missing metadata"
        }
    }
}
