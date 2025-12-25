import Foundation
import OSLog

/// Wrapper around GenericDownloadService for Reverb WebSocket server
nonisolated enum ReverbDownloadService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "reverb-download")

    // MARK: - Public

    static func download(
        metadata: ReverbMetadata,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        do {
            return try await GenericDownloadService.download(
                metadata: metadata,
                identifier: "Reverb \(metadata.latest)",
                progressHandler: progressHandler
            )
        } catch let error as DownloadError {
            // Convert generic DownloadError to Reverb-specific error
            throw convertToReverbError(error)
        }
    }

    static func extractAndInstall(archiveURL: URL) async throws {
        let destinationDir = FadogenPaths.reverbBinaryPath

        do {
            try await GenericDownloadService.extractArchive(
                archiveURL: archiveURL,
                destinationDir: destinationDir,
                stripComponents: 0,  // Reverb: no strip components
                renameFiles: nil,
                identifier: "Reverb"
            )
        } catch let error as DownloadError {
            // Convert generic DownloadError to Reverb-specific error
            throw convertToReverbError(error)
        }

        logger.info("Reverb installed successfully at \(destinationDir.path)")
    }

    // MARK: - Private

    private static func convertToReverbError(_ error: DownloadError) -> ReverbDownloadError {
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

// MARK: - Metadata

/// From https://binaries.fadogen.app/metadata-reverb.json
nonisolated struct ReverbMetadata: BinaryMetadata {
    let latest: String  // e.g., "v1.6.0"
    let sha256: String
    let filename: String
}

typealias ReverbMetadataCollection = [String: ReverbMetadata]

// MARK: - Error Types

enum ReverbDownloadError: LocalizedError {
    case downloadFailed(Error)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let error):
            return "Failed to download Reverb: \(error.localizedDescription)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch - expected: \(expected.prefix(16))..., actual: \(actual.prefix(16))..."
        case .extractionFailed(let reason):
            return "Failed to extract Reverb archive: \(reason)"
        case .invalidMetadata:
            return "Invalid or missing Reverb metadata"
        }
    }
}
