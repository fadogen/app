import Foundation
import OSLog

/// Downloads from official nodejs.org
nonisolated enum NodeDownloadService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "NodeDownloadService")

    // MARK: - Public

    static func download(
        major: String,
        metadata: NodeMetadata,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // Construct base URL: https://nodejs.org/dist/v22.21.0/
        let baseURL = "https://nodejs.org/dist/v\(metadata.latest)/"

        do {
            return try await GenericDownloadService.download(
                baseURL: baseURL,
                metadata: metadata,
                identifier: "Node.js \(major)",
                progressHandler: progressHandler
            )
        } catch let error as DownloadError {
            // Convert generic DownloadError to Node.js-specific error
            throw convertToNodeError(error, major: major)
        }
    }

    /// Archives contain complete distribution (bin/, lib/, include/, share/)
    static func extractAndInstall(
        archiveURL: URL,
        major: String
    ) async throws {
        let destinationDir = FadogenPaths.nodeInstallPath(for: major)

        // Node.js archives have structure: node-v22.21.0-darwin-arm64/{bin,lib,include,share}
        // We need to strip the top-level directory
        do {
            try await GenericDownloadService.extractArchive(
                archiveURL: archiveURL,
                destinationDir: destinationDir,
                stripComponents: 1,  // Strip top-level directory
                renameFiles: nil,    // No renaming needed
                identifier: "Node.js \(major)"
            )
        } catch let error as DownloadError {
            // Convert generic DownloadError to Node.js-specific error
            throw convertToNodeError(error, major: major)
        }

        logger.info("Node.js \(major) installed successfully")
    }

    // MARK: - Private

    private static func convertToNodeError(_ error: DownloadError, major: String) -> NodeDownloadError {
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

enum NodeDownloadError: LocalizedError {
    case downloadFailed(String, Error)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let version, let error):
            return "Failed to download Node.js \(version): \(error.localizedDescription)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch - expected: \(expected), actual: \(actual)"
        case .extractionFailed(let reason):
            return "Failed to extract archive: \(reason)"
        case .invalidMetadata:
            return "Invalid or missing metadata"
        }
    }
}
