import Foundation

/// Errors that can occur during project generation
enum ProjectGeneratorError: LocalizedError {
    case invalidProjectName(String)
    case directoryAlreadyExists(String)
    case installDirectoryNotFound(String)
    case invalidCustomStarterKitRepo(String)
    case gitNotFound
    case commandFailed(command: String, exitCode: Int, output: String)
    case cancelled
    case siteNotDetected

    var errorDescription: String? {
        switch self {
        case .invalidProjectName(let name):
            return String(localized: "Invalid project name: '\(name)'. Use only letters, numbers, and hyphens.")
        case .directoryAlreadyExists(let path):
            return String(localized: "Directory already exists: \(path)")
        case .installDirectoryNotFound(let path):
            return String(localized: "Installation directory not found: \(path)")
        case .invalidCustomStarterKitRepo(let repo):
            return String(localized: "Invalid custom starter kit repository: '\(repo)'")
        case .gitNotFound:
            return String(localized: "Git not found. Xcode Command Line Tools must be installed.")
        case .commandFailed(let command, let exitCode, let output):
            return String(localized: "Command '\(command)' failed with exit code \(exitCode): \(output)")
        case .cancelled:
            return String(localized: "Operation was cancelled.")
        case .siteNotDetected:
            return String(localized: "The created project was not detected by the file watcher.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidProjectName:
            return String(localized: "Choose a name using only lowercase letters, numbers, and hyphens.")
        case .directoryAlreadyExists:
            return String(localized: "Choose a different project name or delete the existing directory.")
        case .installDirectoryNotFound:
            return String(localized: "Select an existing directory for installation.")
        case .invalidCustomStarterKitRepo:
            return String(localized: "Enter a valid Composer package name (e.g., 'vendor/package').")
        case .gitNotFound:
            return String(localized: "Run 'xcode-select --install' in Terminal.")
        case .commandFailed:
            return String(localized: "Check the logs for more details.")
        case .cancelled:
            return nil
        case .siteNotDetected:
            return String(localized: "Try refreshing the sites list or check that the project was created correctly.")
        }
    }
}
