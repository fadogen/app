import Foundation
import OSLog

/// Idempotent filesystem operations
nonisolated enum FileSystemUtilities {

    // MARK: - Directory

    static func deleteDirectory(
        at url: URL,
        logger: Logger,
        itemName: String
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            logger.info("Deleted \(itemName) at \(url.path)")
        } else {
            logger.debug("\(itemName) not found (already deleted) at \(url.path)")
        }
    }

    static func createDirectory(
        at url: URL,
        logger: Logger,
        itemName: String,
        permissions: Int? = nil
    ) throws {
        var attributes: [FileAttributeKey: Any]? = nil
        if let permissions {
            attributes = [.posixPermissions: permissions]
        }

        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: attributes
        )

        logger.debug("Created \(itemName) at \(url.path)")
    }

    // MARK: - Symlink

    static func removeSymlink(
        at url: URL,
        logger: Logger,
        itemName: String
    ) {
        do {
            try FileManager.default.removeItem(at: url)
            logger.debug("Removed \(itemName)")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // Symlink doesn't exist - that's fine
            logger.debug("\(itemName) does not exist, skipping")
        } catch {
            // Other error - log warning but don't throw
            logger.warning("Failed to remove \(itemName): \(error.localizedDescription)")
        }
    }
}
