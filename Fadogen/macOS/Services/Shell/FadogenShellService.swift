import Foundation
import OSLog

enum FadogenShellError: LocalizedError {
    case resourceNotFound(String)
    case copyFailed(String)
    case permissionDenied
    case configFileWriteFailed

    var errorDescription: String? {
        switch self {
        case .resourceNotFound(let resource):
            return "Fadogen resource not found: \(resource)"
        case .copyFailed(let file):
            return "Failed to copy Fadogen script: \(file)"
        case .permissionDenied:
            return "Permission denied when setting up Fadogen shell integration"
        case .configFileWriteFailed:
            return "Failed to write version config file"
        }
    }
}

nonisolated enum FadogenShellService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "shell")
    private static let mainScriptName = "fadogen.sh"
    private static let fishScriptName = "fadogen.fish"

    // MARK: - Public

    static func setup() throws {
        logger.info("Setting up Fadogen shell integration...")

        // Create scripts directory if it doesn't exist
        try createScriptsDirectoryIfNeeded()

        // Copy main fadogen.sh script from Resources (for POSIX shells: bash, zsh)
        try copyScriptIfNeeded(mainScriptName)

        // Copy fadogen.fish script from Resources (for fish shell)
        try copyScriptIfNeeded(fishScriptName)

        // Copy PHP wrapper to bin/ for shebang support
        try copyPHPWrapper()

        // Copy Composer wrapper to bin/
        try copyComposerWrapper()

        // Copy PHP extension manager to bin/
        try copyPHPExtensionManager()

        logger.info("Fadogen shell integration setup completed successfully")
    }

    static func syncPHPVersion(_ phpVersion: String?, in directory: URL) throws {
        do {
            try FadogenConfigParser.updateVersion(in: directory, section: "php", version: phpVersion)
            if let phpVersion {
                logger.debug("Updated .fadogen with PHP version \(phpVersion) at: \(directory.path)")
            } else {
                logger.debug("Removed PHP version from .fadogen at: \(directory.path)")
            }
        } catch {
            logger.error("Failed to update .fadogen file: \(error.localizedDescription)")
            throw FadogenShellError.configFileWriteFailed
        }
    }

    static func syncNodeVersion(_ nodeVersion: String?, in directory: URL) throws {
        do {
            try FadogenConfigParser.updateVersion(in: directory, section: "node", version: nodeVersion)
            if let nodeVersion {
                logger.debug("Updated .fadogen with Node.js version \(nodeVersion) at: \(directory.path)")
            } else {
                logger.debug("Removed Node.js version from .fadogen at: \(directory.path)")
            }
        } catch {
            logger.error("Failed to update .fadogen file: \(error.localizedDescription)")
            throw FadogenShellError.configFileWriteFailed
        }
    }

    static func syncPackageManager(_ packageManager: String?, in directory: URL) throws {
        do {
            try FadogenConfigParser.updatePackageManager(in: directory, packageManager: packageManager)
            if let packageManager {
                logger.debug("Updated .fadogen with package manager \(packageManager) at: \(directory.path)")
            } else {
                logger.debug("Removed package manager from .fadogen at: \(directory.path)")
            }
        } catch {
            logger.error("Failed to update .fadogen file: \(error.localizedDescription)")
            throw FadogenShellError.configFileWriteFailed
        }
    }

    static func isInstalled() -> Bool {
        let scriptPath = FadogenPaths.scriptsDirectory.appendingPathComponent(mainScriptName)
        return FileManager.default.fileExists(atPath: scriptPath.path)
    }

    static func installNodeWrappers() throws {
        logger.info("Installing Node.js wrappers...")
        try copyNodeWrapper()
        try copyNpmWrapper()
        try copyNpxWrapper()
        logger.info("Node.js wrappers installed successfully")
    }

    static func removeNodeWrappers() throws {
        logger.info("Removing Node.js wrappers...")

        let wrappers = ["node", "npm", "npx"]
        for wrapperName in wrappers {
            let wrapperURL = FadogenPaths.binDirectory.appendingPathComponent(wrapperName)
            if FileManager.default.fileExists(atPath: wrapperURL.path) {
                try FileManager.default.removeItem(at: wrapperURL)
                logger.debug("Removed wrapper: \(wrapperName)")
            }
        }

        logger.info("Node.js wrappers removed successfully")
    }

    // MARK: - Private

    private static func createScriptsDirectoryIfNeeded() throws {
        let scriptsDir = FadogenPaths.scriptsDirectory

        if !FileManager.default.fileExists(atPath: scriptsDir.path) {
            try FileManager.default.createDirectory(
                at: scriptsDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            logger.debug("Created scripts directory at: \(scriptsDir.path)")
        }
    }

    private static func copyScriptIfNeeded(_ scriptName: String) throws {
        // Separate name and extension (e.g., "fadogen.sh" -> name: "fadogen", extension: "sh")
        let nsString = scriptName as NSString
        let name = nsString.deletingPathExtension
        let ext = nsString.pathExtension.isEmpty ? nil : nsString.pathExtension

        // Get source path from Resources (directly, not in subdirectory)
        guard let resourcePath = Bundle.main.path(
            forResource: name,
            ofType: ext
        ) else {
            logger.error("Script not found in Resources: \(scriptName)")
            throw FadogenShellError.resourceNotFound(scriptName)
        }

        let resourceURL = URL(fileURLWithPath: resourcePath)
        let destinationURL = FadogenPaths.scriptsDirectory.appendingPathComponent(scriptName)

        // Check if update is needed
        if shouldUpdateScript(source: resourceURL, destination: destinationURL) {
            // Remove existing file if present
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            // Copy new version
            do {
                try FileManager.default.copyItem(at: resourceURL, to: destinationURL)
                logger.info("Copied \(scriptName) to scripts directory")
            } catch {
                logger.error("Failed to copy \(scriptName): \(error.localizedDescription)")
                throw FadogenShellError.copyFailed(scriptName)
            }
        } else {
            logger.debug("\(scriptName) is up-to-date, skipping copy")
        }
    }

    private static func shouldUpdateScript(source: URL, destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return true // Destination doesn't exist, needs to be copied
        }

        do {
            let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let destAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)

            guard let sourceDate = sourceAttributes[.modificationDate] as? Date,
                  let destDate = destAttributes[.modificationDate] as? Date else {
                return true // Can't compare, update to be safe
            }

            // Update if source is newer
            return sourceDate > destDate

        } catch {
            logger.warning("Failed to compare file dates, will update: \(error.localizedDescription)")
            return true
        }
    }

    // MARK: - Wrappers

    private static func copyWrapper(
        wrapperName: String,
        binaryName: String,
        description: String
    ) throws {
        let resourceURL = FadogenPaths.bundleResourcesDirectory
            .appendingPathComponent(wrapperName)

        guard FileManager.default.fileExists(atPath: resourceURL.path) else {
            logger.error("\(wrapperName) not found at: \(resourceURL.path)")
            throw FadogenShellError.resourceNotFound(wrapperName)
        }

        let destinationURL = FadogenPaths.binDirectory
            .appendingPathComponent(binaryName)

        // Remove existing wrapper if present
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        // Copy wrapper
        try FileManager.default.copyItem(at: resourceURL, to: destinationURL)

        // Make executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destinationURL.path
        )

        logger.info("Copied \(description) to bin/\(binaryName)")
    }

    private static func copyPHPWrapper() throws {
        try copyWrapper(wrapperName: "php-wrapper", binaryName: "php", description: "PHP wrapper")
    }

    private static func copyComposerWrapper() throws {
        try copyWrapper(wrapperName: "composer-wrapper", binaryName: "composer", description: "Composer wrapper")
    }

    private static func copyPHPExtensionManager() throws {
        try copyWrapper(wrapperName: "fadogen-ext", binaryName: "fadogen-ext", description: "PHP extension manager")
    }

    private static func copyNodeWrapper() throws {
        try copyWrapper(wrapperName: "node-wrapper", binaryName: "node", description: "Node wrapper")
    }

    private static func copyNpmWrapper() throws {
        try copyWrapper(wrapperName: "npm-wrapper", binaryName: "npm", description: "npm wrapper")
    }

    private static func copyNpxWrapper() throws {
        try copyWrapper(wrapperName: "npx-wrapper", binaryName: "npx", description: "npx wrapper")
    }
}
