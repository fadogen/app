import Foundation
import OSLog

/// Filesystem operations for Composer binary
nonisolated enum ComposerFileSystemService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "composer-fs")

    // MARK: - Configuration

    private static let versionConfig = VersionExtractionConfig(
        versionArgs: ["--version", "--no-ansi"],
        extractVersion: { output in
            let pattern = #/Composer version (\d+\.\d+\.\d+)/#
            guard let match = output.firstMatch(of: pattern) else {
                throw BinaryError.versionParsingFailed(output)
            }
            return String(match.1)
        },
        requiresBinary: "php"  // Composer is a PHAR, needs PHP
    )

    private static let copyConfig = BinaryCopyConfig(
        resourceName: "composer",
        destinationName: "composer.phar"
    )

    // MARK: - Public

    static func copyBundledBinary() throws -> URL {
        try BinaryManagementUtilities.copyBundledBinary(
            config: copyConfig,
            logger: logger
        )
    }

    static func extractVersion(from binaryURL: URL) async throws -> String {
        try await BinaryManagementUtilities.extractVersion(
            from: binaryURL,
            config: versionConfig,
            logger: logger
        )
    }

    static func validateBinaryIntegrity(url: URL) async -> Bool {
        await BinaryManagementUtilities.validateBinaryIntegrity(
            url: url,
            config: versionConfig,
            logger: logger
        )
    }

    static func deleteBinary() throws {
        try BinaryManagementUtilities.deleteBinary(
            named: copyConfig.destinationName,
            logger: logger
        )
    }

    static func detectBundledBinary() -> Bool {
        BinaryManagementUtilities.detectBundledBinary(
            named: copyConfig.resourceName
        )
    }

    static func isInstalled() -> Bool {
        BinaryManagementUtilities.isInstalled(
            binaryName: copyConfig.destinationName
        )
    }
}
