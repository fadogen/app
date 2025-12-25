import Foundation
import OSLog

/// Wrapper around GenericDownloadService for databases and caches
nonisolated enum ServicesDownloadService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "services-download")

    // MARK: - Public

    static func download(
        service: ServiceType,
        major: String,
        metadata: ServiceMetadata,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        do {
            return try await GenericDownloadService.download(
                baseURL: GenericDownloadService.binariesBaseURL + "/",
                metadata: metadata,
                identifier: "\(service.displayName) \(major)",
                progressHandler: progressHandler
            )
        } catch let error as DownloadError {
            // Convert generic DownloadError to Services-specific error
            throw convertToServicesError(error, service: service)
        }
    }

    static func extractAndInstall(
        archiveURL: URL,
        service: ServiceType,
        major: String
    ) async throws {
        let destinationDir = FadogenPaths.binaryPath(for: service, major: major)

        do {
            try await GenericDownloadService.extractArchive(
                archiveURL: archiveURL,
                destinationDir: destinationDir,
                stripComponents: 1,  // Services use --strip-components=1
                renameFiles: nil,    // No renaming needed for services
                identifier: "\(service.displayName) \(major)"
            )
        } catch let error as DownloadError {
            // Convert generic DownloadError to Services-specific error
            throw convertToServicesError(error, service: service)
        }

        logger.info("\(service.rawValue) \(major) installed successfully at \(destinationDir.path)")
    }

    // MARK: - Private

    private static func convertToServicesError(_ error: DownloadError, service: ServiceType) -> ServicesDownloadError {
        switch error {
        case .downloadFailed(_, let underlyingError):
            return .downloadFailed(service.rawValue, underlyingError)
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

enum ServicesDownloadError: LocalizedError {
    case downloadFailed(String, Error)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let service, let error):
            return "Failed to download \(service): \(error.localizedDescription)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch - expected: \(expected.prefix(16))..., actual: \(actual.prefix(16))..."
        case .extractionFailed(let reason):
            return "Failed to extract archive: \(reason)"
        case .invalidMetadata:
            return "Invalid or missing metadata"
        }
    }
}
