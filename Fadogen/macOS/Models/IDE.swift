import Foundation

/// Supported IDEs for "Open in IDE" feature
enum IDE: String, CaseIterable, Identifiable, Codable {
    case vscode
    case cursor
    case phpstorm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .phpstorm: return "PHPStorm"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .phpstorm: return "com.jetbrains.PhpStorm"
        }
    }
}
