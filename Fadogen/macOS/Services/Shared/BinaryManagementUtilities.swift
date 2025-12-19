import Foundation
import Subprocess
import System
import OSLog

// MARK: - Configuration

struct VersionExtractionConfig: Sendable {
    let versionArgs: [String]
    let extractVersion: @Sendable (String) throws -> String
    /// Composer needs PHP to run
    let requiresBinary: String?

    nonisolated init(
        versionArgs: [String] = ["--version"],
        extractVersion: @escaping @Sendable (String) throws -> String,
        requiresBinary: String? = nil
    ) {
        self.versionArgs = versionArgs
        self.extractVersion = extractVersion
        self.requiresBinary = requiresBinary
    }
}

struct BinaryCopyConfig: Sendable {
    let resourceName: String
    let destinationName: String
    let permissions: Int

    nonisolated init(resourceName: String, destinationName: String, permissions: Int = 0o755) {
        self.resourceName = resourceName
        self.destinationName = destinationName
        self.permissions = permissions
    }
}

// MARK: - Utilities

/// Shared operations for PHP/Node/Composer/Bun FileSystemServices
nonisolated enum BinaryManagementUtilities {

    static func extractVersion(
        from binaryURL: URL,
        config: VersionExtractionConfig,
        logger: Logger
    ) async throws -> String {
        // Check executable (unless it requires another binary to run)
        if config.requiresBinary == nil {
            guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
                throw BinaryError.notExecutable(binaryURL.path)
            }
        }

        // Determine which binary to execute
        let executablePath: FilePath
        let arguments: [String]

        if let requiredBinary = config.requiresBinary {
            // e.g., Composer requires PHP
            let requiredBinaryPath = FadogenPaths.binDirectory
                .appendingPathComponent(requiredBinary)

            guard FileManager.default.fileExists(atPath: requiredBinaryPath.path) else {
                throw BinaryError.requiredBinaryNotFound(requiredBinary)
            }

            executablePath = FilePath(requiredBinaryPath.path)
            arguments = [binaryURL.path] + config.versionArgs
        } else {
            executablePath = FilePath(binaryURL.path)
            arguments = config.versionArgs
        }

        // Execute version command
        let result = try await Subprocess.run(
            .path(executablePath),
            arguments: .init(arguments),
            output: .bytes(limit: 1024),
            error: .discarded
        )

        guard result.terminationStatus.isSuccess else {
            throw BinaryError.versionCommandFailed(binaryURL.path)
        }

        // Parse output
        guard let output = String(bytes: result.standardOutput, encoding: .utf8) else {
            throw BinaryError.versionParsingFailed(binaryURL.path)
        }

        // Extract version using the config's closure
        let version = try config.extractVersion(output)
        logger.debug("Extracted version \(version) from \(binaryURL.lastPathComponent)")

        return version
    }

    // MARK: - Validation

    static func validateBinaryIntegrity(
        url: URL,
        config: VersionExtractionConfig,
        logger: Logger
    ) async -> Bool {
        // Check file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.warning("Binary not found at \(url.path)")
            return false
        }

        // Check executable (unless requires another binary)
        if config.requiresBinary == nil {
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                logger.warning("Binary not executable at \(url.path)")
                return false
            }
        }

        // Try version extraction
        do {
            _ = try await extractVersion(from: url, config: config, logger: logger)
            return true
        } catch {
            logger.warning("Binary validation failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Copying

    static func copyBundledBinary(
        config: BinaryCopyConfig,
        logger: Logger
    ) throws -> URL {
        guard let resourcePath = Bundle.main.resourcePath else {
            throw BinaryError.bundledResourceNotFound(config.resourceName)
        }

        let resourceURL = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent(config.resourceName)

        guard FileManager.default.fileExists(atPath: resourceURL.path) else {
            throw BinaryError.bundledResourceNotFound(config.resourceName)
        }

        // Ensure bin directory exists
        let binDir = FadogenPaths.binDirectory
        try FileManager.default.createDirectory(
            at: binDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let destinationURL = binDir.appendingPathComponent(config.destinationName)

        // Remove existing if present
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        // Copy
        try FileManager.default.copyItem(at: resourceURL, to: destinationURL)

        // Set permissions
        try FileManager.default.setAttributes(
            [.posixPermissions: config.permissions],
            ofItemAtPath: destinationURL.path
        )

        logger.info("Copied bundled binary \(config.resourceName) to \(destinationURL.path)")
        return destinationURL
    }

    // MARK: - Deletion

    static func deleteBinary(
        named binaryName: String,
        logger: Logger
    ) throws {
        let binaryURL = FadogenPaths.binDirectory.appendingPathComponent(binaryName)

        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            logger.info("Binary \(binaryName) not found, nothing to delete")
            return
        }

        try FileManager.default.removeItem(at: binaryURL)
        logger.info("Deleted binary \(binaryName) from \(binaryURL.path)")
    }

    // MARK: - Detection

    static func detectBundledBinary(named resourceName: String) -> Bool {
        guard let resourcePath = Bundle.main.resourcePath else {
            return false
        }

        let resourceURL = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent(resourceName)

        return FileManager.default.fileExists(atPath: resourceURL.path)
    }

    static func isInstalled(binaryName: String) -> Bool {
        let binaryURL = FadogenPaths.binDirectory.appendingPathComponent(binaryName)
        return FileManager.default.fileExists(atPath: binaryURL.path)
    }
}

// MARK: - Errors

enum BinaryError: LocalizedError {
    case notExecutable(String)
    case requiredBinaryNotFound(String)
    case versionCommandFailed(String)
    case versionParsingFailed(String)
    case bundledResourceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notExecutable(let path):
            return "Binary not executable: \(path)"
        case .requiredBinaryNotFound(let binary):
            return "Required binary not found: \(binary)"
        case .versionCommandFailed(let path):
            return "Version command failed for: \(path)"
        case .versionParsingFailed(let path):
            return "Failed to parse version from: \(path)"
        case .bundledResourceNotFound(let resource):
            return "Bundled resource not found: \(resource)"
        }
    }
}
