import Foundation
import CryptoKit
import Subprocess
import System

/// Shared download logic for all binary types (PHP, Node, databases, etc.)
enum GenericDownloadService {

    // MARK: - Download

    static func download<M: BinaryMetadata>(
        baseURL: String,
        metadata: M,
        identifier: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // Construct download URL
        guard let downloadURL = URL(string: baseURL + metadata.filename) else {
            throw DownloadError.invalidMetadata
        }

        // Create download delegate for progress tracking
        let delegate = DownloadDelegate(progressHandler: progressHandler)

        // Create URLSession configuration WITHOUT cache to avoid 404 on old URLs
        let session = DownloadUtilities.createNoCacheSession(delegate: delegate, delegateQueue: nil)

        // Start download
        let (tempURL, response) = try await session.download(from: downloadURL)

        // Validate HTTP response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.downloadFailed(identifier, NSError(domain: "HTTPError", code: -1))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw DownloadError.downloadFailed(identifier, NSError(domain: "HTTPError", code: httpResponse.statusCode))
        }

        // Move to permanent temporary location
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(metadata.filename)

        // Remove existing file if present
        try? FileManager.default.removeItem(at: destinationURL)

        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

        // Verify checksum
        do {
            try DownloadUtilities.verifyChecksum(fileURL: destinationURL, expectedChecksum: metadata.sha256)
        } catch let error as ChecksumError {
            // Convert to generic DownloadError
            if case .mismatch(let expected, let actual) = error {
                throw DownloadError.checksumMismatch(expected: expected, actual: actual)
            }
            throw error
        }

        return destinationURL
    }

    // MARK: - Extract

    static func extractArchive(
        archiveURL: URL,
        destinationDir: URL,
        stripComponents: Int = 0,
        renameFiles: [(from: String, to: String)]? = nil,
        identifier: String
    ) async throws {
        // Determine if we need a temp directory for renaming
        let extractionDir: URL
        let needsTempDir = renameFiles != nil

        if needsTempDir {
            // Create unique temp directory for extraction (enables renaming before final move)
            extractionDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        } else {
            // Extract directly to destination
            extractionDir = destinationDir
        }

        // Ensure destination directory exists
        if !needsTempDir {
            // Preventive deletion of target directory (ensures consistency)
            if FileManager.default.fileExists(atPath: destinationDir.path) {
                try FileManager.default.removeItem(at: destinationDir)
            }

            // Create parent directory
            try FileManager.default.createDirectory(
                at: destinationDir.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [FileAttributeKey.posixPermissions: 0o755]
            )
        }

        // Create extraction directory
        try FileManager.default.createDirectory(
            at: extractionDir,
            withIntermediateDirectories: true,
            attributes: [FileAttributeKey.posixPermissions: 0o755]
        )

        // Cleanup (archive always, temp dir only if needed)
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            if needsTempDir {
                try? FileManager.default.removeItem(at: extractionDir)
            }
        }

        // Build tar command arguments
        var tarArgs: [String] = ["-xzf", archiveURL.path, "-C", extractionDir.path]
        if stripComponents > 0 {
            tarArgs.append("--strip-components=\(stripComponents)")
        }

        // Extract archive
        let result = try await Subprocess.run(
            .path("/usr/bin/tar"),
            arguments: .init(tarArgs),
            output: .discarded,
            error: .bytes(limit: 4096)
        )

        guard result.terminationStatus.isSuccess else {
            let errorOutput = String(bytes: result.standardError, encoding: .utf8) ?? "unknown error"
            throw DownloadError.extractionFailed(String(localized: "tar extraction failed: \(errorOutput)"))
        }

        // Rename files if specified (PHP use case: php-cli → php83)
        if let renameFiles {
            for (from, to) in renameFiles {
                let sourceURL = extractionDir.appendingPathComponent(from)
                let destURL = extractionDir.appendingPathComponent(to)

                try FileManager.default.moveItem(at: sourceURL, to: destURL)
            }
        }

        // Move renamed files to final destination if we used temp directory
        if needsTempDir {
            // Ensure destination directory exists
            try FileManager.default.createDirectory(
                at: destinationDir,
                withIntermediateDirectories: true,
                attributes: [FileAttributeKey.posixPermissions: 0o755]
            )

            // Move each renamed file
            for (_, to) in renameFiles! {
                let sourceURL = extractionDir.appendingPathComponent(to)
                let destURL = destinationDir.appendingPathComponent(to)

                // Remove existing file if present
                try? FileManager.default.removeItem(at: destURL)

                try FileManager.default.moveItem(at: sourceURL, to: destURL)
            }
        }
    }
}
