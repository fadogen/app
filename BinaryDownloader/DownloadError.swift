import Foundation

enum DownloadError: Error, LocalizedError {
    case unsupportedArchitecture(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed
    case invalidChecksumsFile
    case noMacOSChecksums
    case invalidMetadata(filename: String)
    case noPHPLatestVersion
    case noNodeLTSVersion
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let arch):
            return "Unsupported architecture: \(arch)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch. Expected: \(expected), Got: \(actual)"
        case .extractionFailed:
            return "Failed to extract archive"
        case .invalidChecksumsFile:
            return "Failed to download or parse checksums file"
        case .noMacOSChecksums:
            return "No macOS checksums found in checksums file"
        case .invalidMetadata(let filename):
            return "Failed to download or parse \(filename)"
        case .noPHPLatestVersion:
            return "No latest PHP version found in metadata"
        case .noNodeLTSVersion:
            return "No active LTS Node.js version found"
        case .invalidURL(let urlString):
            return "Invalid URL: \(urlString)"
        }
    }
}
