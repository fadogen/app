import Foundation
import Subprocess
import System
import OSLog

/// Filesystem operations for PHP binaries (nonisolated: FileManager is thread-safe)
nonisolated enum PHPFileSystemService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "php-fs")

    /// Returns ["8.2": URL, "8.3": URL] for installed versions
    static func scanInstalledBinaries() async throws -> [String: URL] {
        let binDir = FadogenPaths.binDirectory

        // Check if bin directory exists
        guard FileManager.default.fileExists(atPath: binDir.path) else {
            logger.info("Bin directory does not exist yet: \(binDir.path)")
            return [:]
        }

        // Get all files in bin directory
        let contents = try FileManager.default.contentsOfDirectory(
            at: binDir,
            includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles]
        )

        var installedVersions: [String: URL] = [:]

        // Regex to match php binaries: php82, php83, php84, etc.
        let phpBinaryPattern = #/^php(\d)(\d)$/#

        for fileURL in contents {
            let fileName = fileURL.lastPathComponent

            // Try to match php binary pattern
            if let match = fileName.wholeMatch(of: phpBinaryPattern) {
                let majorDigit = String(match.output.1)
                let minorDigit = String(match.output.2)
                let majorVersion = "\(majorDigit).\(minorDigit)"

                // Return ALL binaries matching the pattern, even non-executable
                // Validation happens in syncInstalledVersions() which will clean corrupted ones
                installedVersions[majorVersion] = fileURL

                if isExecutable(fileURL) {
                    logger.debug("Found PHP \(majorVersion) at \(fileURL.path)")
                } else {
                    logger.warning("Found PHP \(majorVersion) but not executable (will be cleaned): \(fileURL.path)")
                }
            }
        }

        logger.info("Scanned bin directory, found \(installedVersions.count) PHP version(s)")
        return installedVersions
    }

    /// Executes `php --version` and returns e.g. "8.3.12"
    static func extractVersion(from binaryURL: URL) async throws -> String {
        guard isExecutable(binaryURL) else {
            throw PHPFileSystemError.binaryNotExecutable(binaryURL.path)
        }

        let binaryPath: FilePath = .init(binaryURL.path)

        do {
            // Execute `php --version` and capture stdout
            let result = try await Subprocess.run(
                .path(binaryPath),
                arguments: .init(["--version"]),
                output: .bytes(limit: 1024),  // Version output is small
                error: .discarded
            )

            guard result.terminationStatus.isSuccess else {
                throw PHPFileSystemError.versionExtractionFailed(
                    binaryURL.path,
                    "Process exited with \(result.terminationStatus)"
                )
            }

            // Convert output to string
            guard let outputString = String(bytes: result.standardOutput, encoding: .utf8) else {
                throw PHPFileSystemError.versionParsingFailed(binaryURL.path)
            }

            // Parse version with regex: "PHP 8.3.12 (...)"
            let versionPattern = #/PHP (\d+\.\d+\.\d+)/#
            guard let match = outputString.firstMatch(of: versionPattern) else {
                throw PHPFileSystemError.versionParsingFailed(binaryURL.path)
            }

            let version = String(match.output.1)
            logger.debug("Extracted version \(version) from \(binaryURL.lastPathComponent)")
            return version

        } catch let error as PHPFileSystemError {
            throw error
        } catch {
            throw PHPFileSystemError.versionExtractionFailed(
                binaryURL.path,
                error.localizedDescription
            )
        }
    }

    static func validateBinaryIntegrity(url: URL) async -> Bool {
        // Check if file is executable
        guard isExecutable(url) else {
            logger.warning("Binary not executable: \(url.path)")
            return false
        }

        // Try to execute php --version (reuse extractVersion)
        do {
            _ = try await extractVersion(from: url)
            return true
        } catch {
            logger.warning("Binary failed integrity check: \(url.path) - \(error.localizedDescription)")
            return false
        }
    }

    /// Returns e.g. "8.3" or nil if no bundled PHP
    static func detectBundledVersion() async -> String? {
        guard let resourcePath = Bundle.main.resourcePath else {
            logger.warning("Bundle resource path not found")
            return nil
        }

        let bundledPHPPath = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("php-cli")

        guard FileManager.default.fileExists(atPath: bundledPHPPath.path) else {
            logger.info("No bundled PHP binary found")
            return nil
        }

        do {
            let fullVersion = try await extractVersion(from: bundledPHPPath)

            // Extract major.minor from full version (e.g., "8.3.12" -> "8.3")
            let components = fullVersion.split(separator: ".")
            guard components.count >= 2 else {
                logger.error("Invalid version format: \(fullVersion)")
                return nil
            }

            let majorVersion = "\(components[0]).\(components[1])"
            logger.info("Detected bundled PHP version: \(majorVersion)")
            return majorVersion

        } catch {
            logger.error("Failed to detect bundled version: \(error.localizedDescription)")
            return nil
        }
    }

    static func copyBundledBinary(major: String) throws -> (cli: URL, fpm: URL) {
        guard let resourcePath = Bundle.main.resourcePath else {
            throw PHPFileSystemError.bundledBinaryNotFound
        }

        let resourceURL = URL(fileURLWithPath: resourcePath)
        let bundledCLI = resourceURL.appendingPathComponent("php-cli")
        let bundledFPM = resourceURL.appendingPathComponent("php-fpm")

        // Verify bundled binaries exist
        guard FileManager.default.fileExists(atPath: bundledCLI.path) else {
            throw PHPFileSystemError.bundledBinaryNotFound
        }
        guard FileManager.default.fileExists(atPath: bundledFPM.path) else {
            throw PHPFileSystemError.bundledBinaryNotFound
        }

        // Ensure bin directory exists
        let binDir = FadogenPaths.binDirectory
        try FileManager.default.createDirectory(
            at: binDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Compute destination paths
        let versionNumber = major.replacingOccurrences(of: ".", with: "")
        let destCLI = binDir.appendingPathComponent("php\(versionNumber)")
        let destFPM = binDir.appendingPathComponent("php\(versionNumber)-fpm")

        // Copy binaries (overwrite if exists)
        if FileManager.default.fileExists(atPath: destCLI.path) {
            try FileManager.default.removeItem(at: destCLI)
        }
        if FileManager.default.fileExists(atPath: destFPM.path) {
            try FileManager.default.removeItem(at: destFPM)
        }

        try FileManager.default.copyItem(at: bundledCLI, to: destCLI)
        try FileManager.default.copyItem(at: bundledFPM, to: destFPM)

        // Make executable (preserve permissions should already be set, but ensure)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destCLI.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destFPM.path
        )

        logger.info("Copied bundled PHP \(major) to bin directory")
        return (cli: destCLI, fpm: destFPM)
    }

    static func updateSymlinks(to major: String) throws {
        let binDir = FadogenPaths.binDirectory
        let versionNumber = major.replacingOccurrences(of: ".", with: "")

        // Symlink paths (using .default suffix to avoid conflict with wrapper scripts)
        let phpSymlink = binDir.appendingPathComponent("php.default")
        let phpFPMSymlink = binDir.appendingPathComponent("php-fpm.default")

        // Target binaries
        let phpTarget = "php\(versionNumber)"
        let phpFPMTarget = "php\(versionNumber)-fpm"

        // Force remove existing symlinks (works for both valid and broken symlinks)
        FileSystemUtilities.removeSymlink(at: phpSymlink, logger: logger, itemName: "php.default symlink")
        FileSystemUtilities.removeSymlink(at: phpFPMSymlink, logger: logger, itemName: "php-fpm.default symlink")

        // Create new symlinks (relative paths for portability)
        try FileManager.default.createSymbolicLink(
            atPath: phpSymlink.path,
            withDestinationPath: phpTarget
        )
        try FileManager.default.createSymbolicLink(
            atPath: phpFPMSymlink.path,
            withDestinationPath: phpFPMTarget
        )

        logger.info("Updated symlinks to PHP \(major)")
    }

    static func createConfigDirectory(for major: String) throws {
        let configDir = FadogenPaths.configPath(for: major)

        try FileManager.default.createDirectory(
            at: configDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        logger.debug("Created config directory: \(configDir.path)")
    }

    /// Returns e.g. "8.3" by resolving php.default symlink
    static func detectDefaultVersion() throws -> String? {
        let phpSymlink = FadogenPaths.binDirectory.appendingPathComponent("php.default")

        // Check if symlink exists
        guard FileManager.default.fileExists(atPath: phpSymlink.path) else {
            logger.debug("No php symlink found")
            return nil
        }

        // Read symlink destination
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: phpSymlink.path)

        // Parse "php83" -> "8.3"
        let pattern = #/^php(\d)(\d)$/#
        guard let match = destination.wholeMatch(of: pattern) else {
            logger.warning("Symlink destination has unexpected format: \(destination)")
            return nil
        }

        let majorDigit = String(match.output.1)
        let minorDigit = String(match.output.2)
        let majorVersion = "\(majorDigit).\(minorDigit)"

        logger.debug("Detected default PHP version: \(majorVersion)")
        return majorVersion
    }

    static func deleteBinary(major: String) throws {
        let binDir = FadogenPaths.binDirectory
        let versionNumber = major.replacingOccurrences(of: ".", with: "")

        let cliPath = binDir.appendingPathComponent("php\(versionNumber)")
        let fpmPath = binDir.appendingPathComponent("php\(versionNumber)-fpm")

        // Delete CLI binary if exists (idempotent)
        if FileManager.default.fileExists(atPath: cliPath.path) {
            try FileManager.default.removeItem(at: cliPath)
            logger.info("Deleted CLI binary: \(cliPath.lastPathComponent)")
        } else {
            logger.debug("CLI binary not found (already deleted): \(cliPath.lastPathComponent)")
        }

        // Delete FPM binary if exists (idempotent)
        if FileManager.default.fileExists(atPath: fpmPath.path) {
            try FileManager.default.removeItem(at: fpmPath)
            logger.info("Deleted FPM binary: \(fpmPath.lastPathComponent)")
        } else {
            logger.debug("FPM binary not found (already deleted): \(fpmPath.lastPathComponent)")
        }

        logger.info("Deleted binaries for PHP \(major)")
    }

    static func deleteConfigDirectory(major: String) throws {
        let configDir = FadogenPaths.configPath(for: major)

        // Delete config directory if exists (idempotent)
        if FileManager.default.fileExists(atPath: configDir.path) {
            try FileManager.default.removeItem(at: configDir)
            logger.info("Deleted config directory: \(configDir.path)")
        } else {
            logger.debug("Config directory not found (already deleted): \(configDir.path)")
        }
    }

    // MARK: - Private

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}

// MARK: - Errors

enum PHPFileSystemError: LocalizedError {
    case directoryNotFound(String)
    case binaryNotExecutable(String)
    case versionExtractionFailed(String, String)
    case versionParsingFailed(String)
    case bundledBinaryNotFound

    var errorDescription: String? {
        switch self {
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .binaryNotExecutable(let path):
            return "Binary is not executable: \(path)"
        case .versionExtractionFailed(let path, let reason):
            return "Failed to extract version from \(path): \(reason)"
        case .versionParsingFailed(let path):
            return "Failed to parse version output from \(path)"
        case .bundledBinaryNotFound:
            return "Bundled PHP binary not found in application resources"
        }
    }
}
