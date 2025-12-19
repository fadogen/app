import Foundation
import OSLog

/// Downloads from official GitHub releases
nonisolated enum BunDownloadService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "BunDownloadService")
    private static let baseURL = "https://github.com/oven-sh/bun/releases/latest/download/"

    // MARK: - Public

    static func download(
        metadata: BunMetadata,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        do {
            return try await GenericDownloadService.download(
                baseURL: baseURL,
                metadata: metadata,
                identifier: "Bun",
                progressHandler: progressHandler
            )
        } catch let error as DownloadError {
            // Convert generic DownloadError to Bun-specific error
            throw convertToBunError(error)
        }
    }

    /// Archives contain single executable: bun-darwin-aarch64/bun
    static func extractAndInstall(archiveURL: URL) async throws {
        let binDirectory = FadogenPaths.binDirectory

        // Bun archives have structure: bun-darwin-aarch64/bun
        // Extract and rename to just "bun"
        let renameFiles = [
            ("bun", "bun")
        ]

        do {
            try await GenericDownloadService.extractArchive(
                archiveURL: archiveURL,
                destinationDir: binDirectory,
                stripComponents: 1,  // Strip bun-darwin-aarch64/ directory
                renameFiles: renameFiles,
                identifier: "Bun"
            )
        } catch let error as DownloadError {
            // Convert generic DownloadError to Bun-specific error
            throw convertToBunError(error)
        }

        logger.info("Bun installed successfully")
    }

    // MARK: - Private

    private static func convertToBunError(_ error: DownloadError) -> BunDownloadError {
        switch error {
        case .downloadFailed(_, let underlyingError):
            return .downloadFailed(underlyingError)
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

enum BunDownloadError: LocalizedError {
    case downloadFailed(Error)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let error):
            return "Failed to download Bun: \(error.localizedDescription)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch - expected: \(expected), actual: \(actual)"
        case .extractionFailed(let reason):
            return "Failed to extract archive: \(reason)"
        case .invalidMetadata:
            return "Invalid or missing metadata"
        }
    }
}
