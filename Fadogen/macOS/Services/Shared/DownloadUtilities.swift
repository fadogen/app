import Foundation
import CryptoKit

/// Progress tracking and checksum verification
nonisolated enum DownloadUtilities {

    // MARK: - URLSession

    static func createNoCacheSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    static func createNoCacheSession(delegate: (any URLSessionDelegate)?, delegateQueue: OperationQueue?) -> URLSession {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config, delegate: delegate, delegateQueue: delegateQueue)
    }

    // MARK: - Checksum

    static func verifyChecksum(
        fileURL: URL,
        expectedChecksum: String
    ) throws {
        // Read file data
        let data = try Data(contentsOf: fileURL)

        // Compute SHA256 hash
        let digest = SHA256.hash(data: data)
        let hashString = digest.compactMap { String(format: "%02x", $0) }.joined()

        // Verify checksum matches
        guard hashString == expectedChecksum else {
            throw ChecksumError.mismatch(expected: expectedChecksum, actual: hashString)
        }
    }
}

// MARK: - Download Delegate

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Double) -> Void

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Final progress update
        progressHandler(1.0)
    }
}

// MARK: - Errors

enum ChecksumError: LocalizedError {
    case mismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .mismatch(let expected, let actual):
            return "Checksum mismatch - expected: \(expected.prefix(16))..., actual: \(actual.prefix(16))..."
        }
    }
}
