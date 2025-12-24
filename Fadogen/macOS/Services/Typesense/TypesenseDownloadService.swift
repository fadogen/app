import Foundation
import OSLog

/// Wrapper around GenericDownloadService for Typesense search server
nonisolated enum TypesenseDownloadService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "typesense-download")
    private static let baseURL = "https://binaries.fadogen.app/"

    // MARK: - Public

    static func download(
        metadata: TypesenseMetadata,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        do {
            return try await GenericDownloadService.download(
                baseURL: baseURL,
                metadata: metadata,
                identifier: "Typesense \(metadata.latest)",
                progressHandler: progressHandler
            )
        } catch let error as DownloadError {
            throw convertToTypesenseError(error)
        }
    }

    static func extractAndInstall(archiveURL: URL) async throws {
        let destinationDir = FadogenPaths.typesenseBinaryPath

        do {
            try await GenericDownloadService.extractArchive(
                archiveURL: archiveURL,
                destinationDir: destinationDir,
                stripComponents: 0,  // Typesense: binary at root level
                renameFiles: nil,
                identifier: "Typesense"
            )
        } catch let error as DownloadError {
            throw convertToTypesenseError(error)
        }

        logger.info("Typesense installed successfully at \(destinationDir.path)")
    }

    // MARK: - Private

    private static func convertToTypesenseError(_ error: DownloadError) -> TypesenseDownloadError {
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

/// From https://binaries.fadogen.app/metadata-typesense.json
nonisolated struct TypesenseMetadata: BinaryMetadata {
    let latest: String  // e.g., "28.0"
    let sha256: String
    let filename: String
}

typealias TypesenseMetadataCollection = [String: TypesenseMetadata]

// MARK: - Error Types

enum TypesenseDownloadError: LocalizedError {
    case downloadFailed(Error)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let error):
            return "Failed to download Typesense: \(error.localizedDescription)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch - expected: \(expected.prefix(16))..., actual: \(actual.prefix(16))..."
        case .extractionFailed(let reason):
            return "Failed to extract Typesense archive: \(reason)"
        case .invalidMetadata:
            return "Invalid or missing Typesense metadata"
        }
    }
}
