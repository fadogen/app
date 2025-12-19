import Foundation
import Subprocess
import System
import OSLog

/// Filesystem operations for Node.js installations (nonisolated: FileManager is thread-safe)
nonisolated enum NodeFileSystemService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "node-fs")

    /// Migrates node-versions → node (backward compatibility)
    static func migrateNodeVersionsDirectory() throws {
        let oldPath = FadogenPaths.sharedBinariesDirectory.appendingPathComponent("node-versions")
        let newPath = FadogenPaths.nodeVersionsDirectory  // Points to "node" now

        // Only migrate if old directory exists and new one doesn't
        guard FileManager.default.fileExists(atPath: oldPath.path),
              !FileManager.default.fileExists(atPath: newPath.path) else {
            return
        }

        logger.info("Migrating node-versions → node directory")
        try FileManager.default.moveItem(at: oldPath, to: newPath)
        logger.info("Migration completed successfully")
    }

    /// Returns ["22": URL, "20": URL] for installed versions
    static func scanInstalledBinaries() async throws -> [String: URL] {
        let nodeVersionsDir = FadogenPaths.nodeVersionsDirectory

        // Check if node directory exists
        guard FileManager.default.fileExists(atPath: nodeVersionsDir.path) else {
            logger.info("Node versions directory does not exist yet: \(nodeVersionsDir.path)")
            return [:]
        }

        // Get all subdirectories in node-versions directory
        let contents = try FileManager.default.contentsOfDirectory(
            at: nodeVersionsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var installedVersions: [String: URL] = [:]

        // Regex to match version directories: 22, 20, 18, etc.
        let versionPattern = #/^\d+$/#

        for dirURL in contents {
            let dirName = dirURL.lastPathComponent

            // Check if directory name matches version pattern
            if dirName.wholeMatch(of: versionPattern) != nil {
                // Check if node binary exists in this directory
                let nodeBinary = dirURL
                    .appendingPathComponent("bin")
                    .appendingPathComponent("node")

                if FileManager.default.fileExists(atPath: nodeBinary.path) {
                    installedVersions[dirName] = nodeBinary

                    if isExecutable(nodeBinary) {
                        logger.debug("Found Node.js \(dirName) at \(nodeBinary.path)")
                    } else {
                        logger.warning("Found Node.js \(dirName) but not executable (will be cleaned): \(nodeBinary.path)")
                    }
                }
            }
        }

        logger.info("Scanned node directory, found \(installedVersions.count) Node.js version(s)")
        return installedVersions
    }

    /// Executes `node --version` and returns e.g. "22.21.0"
    static func extractVersion(from binaryURL: URL) async throws -> String {
        guard isExecutable(binaryURL) else {
            throw NodeFileSystemError.binaryNotExecutable(binaryURL.path)
        }

        let binaryPath: FilePath = .init(binaryURL.path)

        do {
            // Execute `node --version` and capture stdout
            let result = try await Subprocess.run(
                .path(binaryPath),
                arguments: .init(["--version"]),
                output: .bytes(limit: 1024),
                error: .discarded
            )

            guard result.terminationStatus.isSuccess else {
                throw NodeFileSystemError.versionExtractionFailed(
                    binaryURL.path,
                    "Process exited with \(result.terminationStatus)"
                )
            }

            // Convert output to string
            guard let outputString = String(bytes: result.standardOutput, encoding: .utf8) else {
                throw NodeFileSystemError.versionParsingFailed(binaryURL.path)
            }

            // Parse version: "v22.21.0" -> "22.21.0"
            let versionPattern = #/v(\d+\.\d+\.\d+)/#
            guard let match = outputString.firstMatch(of: versionPattern) else {
                throw NodeFileSystemError.versionParsingFailed(binaryURL.path)
            }

            let version = String(match.output.1)
            logger.debug("Extracted version \(version) from \(binaryURL.lastPathComponent)")
            return version

        } catch let error as NodeFileSystemError {
            throw error
        } catch {
            throw NodeFileSystemError.versionExtractionFailed(
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

        // Try to execute node --version
        do {
            _ = try await extractVersion(from: url)
            return true
        } catch {
            logger.warning("Binary failed integrity check: \(url.path) - \(error.localizedDescription)")
            return false
        }
    }

    /// Returns e.g. "22" or nil if no bundled Node.js
    static func detectBundledVersion() async -> String? {
        guard let resourcePath = Bundle.main.resourcePath else {
            logger.warning("Bundle resource path not found")
            return nil
        }

        // Bundled node is in Resources/node/bin/node
        let nodeBinary = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("node/bin/node")

        guard FileManager.default.fileExists(atPath: nodeBinary.path) else {
            logger.info("No bundled Node.js found at \(nodeBinary.path)")
            return nil
        }

        // Extract version by running node --version
        do {
            let result = try await run(
                .path(FilePath(nodeBinary.path)),
                arguments: ["--version"],
                output: .string(limit: 1000),
                error: .discarded
            )

            guard result.terminationStatus.isSuccess,
                  let output = result.standardOutput else {
                logger.warning("Failed to get Node.js version from bundled binary")
                return nil
            }

            // Parse version (e.g., "v24.5.0" -> "24")
            let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = version.wholeMatch(of: #/^v(\d+)\.\d+\.\d+$/#) {
                let major = String(match.output.1)
                logger.info("Found bundled Node.js \(major) (full version: \(version))")
                return major
            }

            logger.warning("Could not parse Node.js version: \(version)")
            return nil
        } catch {
            logger.error("Failed to detect bundled Node.js version: \(error.localizedDescription)")
            return nil
        }
    }

    static func copyBundledInstallation(major: String) throws -> URL {
        guard let resourcePath = Bundle.main.resourcePath else {
            throw NodeFileSystemError.resourceNotFound(String(localized: "Bundle resource path"))
        }

        let bundledDir = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("node")

        guard FileManager.default.fileExists(atPath: bundledDir.path) else {
            throw NodeFileSystemError.resourceNotFound(String(localized: "node"))
        }

        let destinationDir = FadogenPaths.nodeInstallPath(for: major)

        // Remove existing installation if present
        if FileManager.default.fileExists(atPath: destinationDir.path) {
            try FileManager.default.removeItem(at: destinationDir)
        }

        // Create parent directory
        try FileManager.default.createDirectory(
            at: FadogenPaths.nodeVersionsDirectory,
            withIntermediateDirectories: true
        )

        // Copy entire directory
        try FileManager.default.copyItem(at: bundledDir, to: destinationDir)

        logger.info("Copied bundled Node.js \(major) to \(destinationDir.path)")

        return FadogenPaths.nodeBinaryPath(for: major)
    }

    /// Creates node{major} symlink (e.g., node22)
    static func createVersionedSymlink(for major: String) throws {
        let binDir = FadogenPaths.binDirectory

        // Ensure bin directory exists
        if !FileManager.default.fileExists(atPath: binDir.path) {
            try FileManager.default.createDirectory(
                at: binDir,
                withIntermediateDirectories: true
            )
        }

        let nodeBinary = FadogenPaths.nodeBinaryPath(for: major)

        // Verify target binary exists
        guard FileManager.default.fileExists(atPath: nodeBinary.path) else {
            throw NodeFileSystemError.binaryNotFound(nodeBinary.path)
        }

        // Create/update node{major} symlink (e.g., node22)
        let nodeVersionSymlink = binDir.appendingPathComponent("node\(major)")
        try createOrUpdateSymlink(at: nodeVersionSymlink, target: nodeBinary)

        logger.debug("Created versioned symlink: node\(major)")
    }

    /// Updates node.default, npm, npx symlinks to point to specified version
    static func updateSymlinks(to major: String) throws {
        let binDir = FadogenPaths.binDirectory

        // Ensure bin directory exists
        if !FileManager.default.fileExists(atPath: binDir.path) {
            try FileManager.default.createDirectory(
                at: binDir,
                withIntermediateDirectories: true
            )
        }

        let nodeBinary = FadogenPaths.nodeBinaryPath(for: major)
        let npmBinary = FadogenPaths.npmBinaryPath(for: major)
        let npxBinary = FadogenPaths.npxBinaryPath(for: major)

        // Verify target binaries exist
        guard FileManager.default.fileExists(atPath: nodeBinary.path) else {
            throw NodeFileSystemError.binaryNotFound(nodeBinary.path)
        }

        // Create/update node.default symlink (used by wrappers)
        let nodeDefaultSymlink = binDir.appendingPathComponent("node.default")
        try createOrUpdateSymlink(at: nodeDefaultSymlink, target: nodeBinary)

        // Create/update node{major} symlink (e.g., node22)
        try createVersionedSymlink(for: major)

        // Create/update npm and npx symlinks (will be overwritten by wrappers)
        let npmSymlink = binDir.appendingPathComponent("npm")
        try createOrUpdateSymlink(at: npmSymlink, target: npmBinary)

        let npxSymlink = binDir.appendingPathComponent("npx")
        try createOrUpdateSymlink(at: npxSymlink, target: npxBinary)

        logger.info("Updated default symlinks to Node.js \(major)")
    }

    /// Returns e.g. "22" by resolving node.default symlink
    static func detectDefaultVersion() throws -> String? {
        let symlinkPath = FadogenPaths.binDirectory.appendingPathComponent("node.default")

        guard FileManager.default.fileExists(atPath: symlinkPath.path) else {
            return nil
        }

        // Resolve symlink
        let targetPath = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath.path)
        let targetURL = URL(fileURLWithPath: targetPath, relativeTo: FadogenPaths.binDirectory)

        // Extract major version from path: /Users/Shared/Fadogen/node/22/bin/node
        let versionPattern = #/node/(\d+)/#
        if let match = targetURL.path.firstMatch(of: versionPattern) {
            return String(match.output.1)
        }

        logger.warning("Could not parse version from symlink target: \(targetURL.path)")
        return nil
    }

    static func deleteInstallation(major: String, isLastVersion: Bool = false) throws {
        let installPath = FadogenPaths.nodeInstallPath(for: major)

        guard FileManager.default.fileExists(atPath: installPath.path) else {
            logger.warning("Node.js \(major) installation not found, nothing to delete")
            return
        }

        // Delete entire installation directory
        try FileManager.default.removeItem(at: installPath)

        let binDir = FadogenPaths.binDirectory

        // Delete versioned symlink (e.g., node22) - works for both valid and broken symlinks
        let versionSymlink = binDir.appendingPathComponent("node\(major)")
        FileSystemUtilities.removeSymlink(at: versionSymlink, logger: logger, itemName: "node\(major) symlink")

        // If last version, remove node.default symlink (wrappers removed by removeNodeWrappers())
        if isLastVersion {
            let nodeDefaultSymlink = binDir.appendingPathComponent("node.default")
            FileSystemUtilities.removeSymlink(at: nodeDefaultSymlink, logger: logger, itemName: "node.default symlink")
            logger.info("Deleted Node.js \(major) installation (last version)")
        } else {
            logger.info("Deleted Node.js \(major) installation")
        }
    }

    // MARK: - Private

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func createOrUpdateSymlink(at symlinkURL: URL, target: URL) throws {
        // Remove existing symlink/file
        if FileManager.default.fileExists(atPath: symlinkURL.path) {
            try FileManager.default.removeItem(at: symlinkURL)
        }

        // Create new symlink (absolute path)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: target
        )
    }
}

// MARK: - Errors

enum NodeFileSystemError: LocalizedError {
    case binaryNotExecutable(String)
    case binaryNotFound(String)
    case versionExtractionFailed(String, String)
    case versionParsingFailed(String)
    case resourceNotFound(String)
    case symlinkCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotExecutable(let path):
            return "Node.js binary is not executable: \(path)"
        case .binaryNotFound(let path):
            return "Node.js binary not found: \(path)"
        case .versionExtractionFailed(let path, let reason):
            return "Failed to extract version from \(path): \(reason)"
        case .versionParsingFailed(let path):
            return "Failed to parse version from \(path)"
        case .resourceNotFound(let resource):
            return "Resource not found: \(resource)"
        case .symlinkCreationFailed(let reason):
            return "Failed to create symlink: \(reason)"
        }
    }
}
