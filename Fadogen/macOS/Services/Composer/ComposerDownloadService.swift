import Foundation

/// Wrapper around GenericDownloadService for Composer-specific operations
nonisolated enum ComposerDownloadService {

    private static let baseURL = "https://binaries.fadogen.app/"

    // MARK: - Public

    static func download(
        metadata: ComposerMetadata,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        do {
            return try await GenericDownloadService.download(
                baseURL: baseURL,
                metadata: metadata,
                identifier: "Composer",
                progressHandler: progressHandler
            )
        } catch let error as DownloadError {
            // Convert generic DownloadError to Composer-specific error
            throw convertToComposerError(error)
        }
    }

    static func extractAndInstall(archiveURL: URL) async throws {
        let binDirectory = FadogenPaths.binDirectory

        // Composer-specific: rename extracted "composer" to "composer.phar" for consistency
        let renameFiles: [(String, String)] = [("composer", "composer.phar")]

        do {
            try await GenericDownloadService.extractArchive(
                archiveURL: archiveURL,
                destinationDir: binDirectory,
                stripComponents: 0,
                renameFiles: renameFiles,
                identifier: "Composer"
            )
        } catch let error as DownloadError {
            // Convert generic DownloadError to Composer-specific error
            throw convertToComposerError(error)
        }
    }

    // MARK: - Private

    private static func convertToComposerError(_ error: DownloadError) -> ComposerDownloadError {
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

enum ComposerDownloadError: LocalizedError {
    case downloadFailed(Error)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let error):
            return "Failed to download Composer: \(error.localizedDescription)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch - expected: \(expected), actual: \(actual)"
        case .extractionFailed(let reason):
            return "Failed to extract archive: \(reason)"
        case .invalidMetadata:
            return "Invalid or missing metadata"
        }
    }
}
