import Foundation
import OSLog

/// Wrapper around GenericDownloadService for Garage S3 storage server
nonisolated enum GarageDownloadService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "garage-download")

    // MARK: - Public

    static func download(
        metadata: GarageMetadata,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        do {
            return try await GenericDownloadService.download(
                metadata: metadata,
                identifier: "Garage \(metadata.latest)",
                progressHandler: progressHandler
            )
        } catch let error as DownloadError {
            throw convertToGarageError(error)
        }
    }

    static func extractAndInstall(archiveURL: URL) async throws {
        let destinationDir = FadogenPaths.garageBinaryPath

        do {
            try await GenericDownloadService.extractArchive(
                archiveURL: archiveURL,
                destinationDir: destinationDir,
                stripComponents: 0,  // Garage: binary at root level
                renameFiles: nil,
                identifier: "Garage"
            )
        } catch let error as DownloadError {
            throw convertToGarageError(error)
        }

        logger.info("Garage installed successfully at \(destinationDir.path)")
    }

    // MARK: - Private

    private static func convertToGarageError(_ error: DownloadError) -> GarageDownloadError {
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

/// From https://binaries.fadogen.app/metadata-garage.json
nonisolated struct GarageMetadata: BinaryMetadata {
    let latest: String  // e.g., "2.1.0"
    let sha256: String
    let filename: String
}

// MARK: - Error Types

enum GarageDownloadError: LocalizedError {
    case downloadFailed(Error)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let error):
            return "Failed to download Garage: \(error.localizedDescription)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch - expected: \(expected.prefix(16))..., actual: \(actual.prefix(16))..."
        case .extractionFailed(let reason):
            return "Failed to extract Garage archive: \(reason)"
        case .invalidMetadata:
            return "Invalid or missing Garage metadata"
        }
    }
}
