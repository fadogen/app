import Foundation
import OSLog

/// Filesystem operations for Bun binary
nonisolated enum BunFileSystemService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "bun-fs")

    // MARK: - Configuration

    private static let versionConfig = VersionExtractionConfig(
        versionArgs: ["--version"],
        extractVersion: { output in
            let pattern = #/(\d+\.\d+\.\d+)/#  // Bun outputs just: "1.1.38\n"
            guard let match = output.firstMatch(of: pattern) else {
                throw BinaryError.versionParsingFailed(output)
            }
            return String(match.1)
        }
    )

    private static let copyConfig = BinaryCopyConfig(
        resourceName: "bun",
        destinationName: "bun"
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
