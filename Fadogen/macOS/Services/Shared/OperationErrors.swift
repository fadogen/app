import Foundation

// MARK: - Manager Errors

enum MetadataError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Invalid response from metadata server")
        }
    }
}

enum OperationConflictError: LocalizedError {
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .anotherOperationInProgress:
            return String(localized: "Another operation is in progress. Please wait for it to complete.")
        }
    }
}

// MARK: - Installation Errors

enum InstallError: LocalizedError {
    case versionNotAvailable(String)
    case alreadyInstalled(String)

    var errorDescription: String? {
        switch self {
        case .versionNotAvailable(let identifier):
            return String(localized: "\(identifier) is not available for installation")
        case .alreadyInstalled(let identifier):
            return String(localized: "\(identifier) is already installed")
        }
    }
}

// MARK: - Update Errors

enum UpdateError: LocalizedError {
    case notInstalled
    case noUpdateAvailable

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return String(localized: "Version is not installed")
        case .noUpdateAvailable:
            return String(localized: "Already using the latest version")
        }
    }
}

// MARK: - Remove Errors

enum RemoveError: LocalizedError {
    case notInstalled(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let identifier):
            return String(localized: "\(identifier) is not installed")
        }
    }
}

// MARK: - Download Errors

enum DownloadError: LocalizedError {
    case downloadFailed(String, Error)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let identifier, let error):
            return String(localized: "Failed to download \(identifier): \(error.localizedDescription)")
        case .checksumMismatch(let expected, let actual):
            return String(localized: "Checksum mismatch - expected: \(expected.prefix(16))..., actual: \(actual.prefix(16))...")
        case .extractionFailed(let reason):
            return String(localized: "Failed to extract archive: \(reason)")
        case .invalidMetadata:
            return String(localized: "Invalid or missing metadata")
        }
    }
}

// MARK: - FileSystem Errors

enum FileSystemError: LocalizedError {
    case directoryNotFound(String)
    case deletionFailed(String)
    case creationFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryNotFound(let path):
            return String(localized: "Directory not found: \(path)")
        case .deletionFailed(let reason):
            return String(localized: "Failed to delete: \(reason)")
        case .creationFailed(let reason):
            return String(localized: "Failed to create directory: \(reason)")
        }
    }
}
