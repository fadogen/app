import Foundation
import OSLog

enum ShellSyntax: Sendable {
    case posix  // bash, zsh
    case fish
}

enum ShellType: String, CaseIterable, Sendable {
    case zsh = "zsh"
    case bash = "bash"
    case fish = "fish"

    /// .zshenv instead of .zshrc to support non-interactive shells
    nonisolated var configFileName: String {
        switch self {
        case .zsh:
            return ".zshenv"
        case .bash:
            return ".bash_profile"
        case .fish:
            return "conf.d/fadogen.fish"  // Relative to ~/.config/fish/
        }
    }

    nonisolated var alternateConfigFileName: String? {
        switch self {
        case .zsh, .fish:
            return nil  // No fallback
        case .bash:
            return ".bashrc"
        }
    }

    nonisolated var configBaseDirectory: String? {
        switch self {
        case .zsh, .bash:
            return nil  // Files are directly in ~
        case .fish:
            return ".config/fish"  // Fish configs live in ~/.config/fish/
        }
    }

    nonisolated var syntax: ShellSyntax {
        switch self {
        case .zsh, .bash:
            return .posix
        case .fish:
            return .fish
        }
    }

    nonisolated var fadogenScriptName: String {
        switch syntax {
        case .posix:
            return "fadogen.sh"
        case .fish:
            return "fadogen.fish"
        }
    }
}

struct ShellInfo {
    let executable: String
    let configFile: URL
    let type: ShellType
}

enum ShellDetectionError: LocalizedError {
    case shellNotFound
    case unsupportedShell(String)
    case configFileNotFound(ShellType)

    var errorDescription: String? {
        switch self {
        case .shellNotFound:
            return "Unable to detect user shell"
        case .unsupportedShell(let shell):
            return "Unsupported shell: \(shell). Fadogen supports zsh, bash, and fish"
        case .configFileNotFound(let type):
            return "Configuration file \(type.configFileName) not found"
        }
    }
}

nonisolated enum ShellDetectionService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "shell-detection")

    static func detectUserShell() throws -> ShellInfo {
        // 1. Detect shell from environment variable
        guard let shellPath = ProcessInfo.processInfo.environment["SHELL"] else {
            logger.error("SHELL environment variable not defined")
            throw ShellDetectionError.shellNotFound
        }

        // 2. Identify shell type from path
        guard let shellType = detectShellType(from: shellPath) else {
            logger.error("Unsupported shell: \(shellPath)")
            throw ShellDetectionError.unsupportedShell(shellPath)
        }

        // 3. Locate configuration file
        guard let configFile = findConfigFile(for: shellType) else {
            logger.error("Configuration file not found for \(shellType.rawValue)")
            throw ShellDetectionError.configFileNotFound(shellType)
        }

        logger.info("Shell detected: \(shellType.rawValue) with config \(configFile.lastPathComponent)")

        return ShellInfo(
            executable: shellPath,
            configFile: configFile,
            type: shellType
        )
    }

    // MARK: - Private

    private static func detectShellType(from path: String) -> ShellType? {
        for shellType in ShellType.allCases {
            if path.contains(shellType.rawValue) {
                return shellType
            }
        }
        return nil
    }

    private static func findConfigFile(for type: ShellType) -> URL? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

        // Determine base directory (home or subdirectory like .config/fish)
        let baseDir: URL
        if let configBase = type.configBaseDirectory {
            baseDir = homeDirectory.appendingPathComponent(configBase)
        } else {
            baseDir = homeDirectory
        }

        // Check primary configuration file
        let primaryConfig = baseDir.appendingPathComponent(type.configFileName)

        // For fish, always return the conf.d path (will be created if needed)
        if type == .fish {
            return primaryConfig
        }

        if FileManager.default.fileExists(atPath: primaryConfig.path) {
            return primaryConfig
        }

        // Check alternate file if available
        if let alternateName = type.alternateConfigFileName {
            let alternateConfig = baseDir.appendingPathComponent(alternateName)
            if FileManager.default.fileExists(atPath: alternateConfig.path) {
                return alternateConfig
            }
        }

        // If no file exists, return primary for future creation
        return primaryConfig
    }
}
