import Foundation
import OSLog

enum ShellIntegrationError: LocalizedError {
    case shellFileNotFound
    case shellFileNotWritable
    case backupFailed
    case writeFailed
    case invalidShellSyntax

    var errorDescription: String? {
        switch self {
        case .shellFileNotFound:
            return "No shell configuration file found"
        case .shellFileNotWritable:
            return "Shell configuration file is not writable"
        case .backupFailed:
            return "Failed to backup shell file"
        case .writeFailed:
            return "Failed to write shell file"
        case .invalidShellSyntax:
            return "Invalid shell syntax generated"
        }
    }
}

nonisolated enum ShellIntegrationService {

    private static let fadogenMarker = "# Fadogen"
    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "shell-integration")

    // MARK: - Public

    static func updateShellIntegration(installedVersions: [String]) throws {
        let shellInfo: ShellInfo
        do {
            shellInfo = try ShellDetectionService.detectUserShell()
        } catch {
            throw ShellIntegrationError.shellFileNotFound
        }

        let shellFile = shellInfo.configFile

        // Verify file is writable
        if FileManager.default.fileExists(atPath: shellFile.path) {
            guard FileManager.default.isWritableFile(atPath: shellFile.path) else {
                throw ShellIntegrationError.shellFileNotWritable
            }
        }

        // For fish, ensure parent directories exist (~/.config/fish/conf.d/)
        if shellInfo.type == .fish {
            let parentDir = shellFile.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(
                    at: parentDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                logger.debug("Created fish conf.d directory at: \(parentDir.path)")
            }
        }

        // Generate new Fadogen content (shell-specific)
        let newContent = generateShellContent(shellType: shellInfo.type)

        // Check if update is needed (optimization: skip if already up-to-date)
        if let existingContent = try? extractExistingFadogenContent(from: shellFile),
           existingContent == newContent {
            logger.debug("Shell integration already up-to-date, skipping update")
            return
        }

        // Create backup before modification
        let backupURL = try createBackup(of: shellFile)

        do {
            // Update shell file
            try updateShellFile(at: shellFile, newContent: newContent)

            // Clean up backup on success
            try? FileManager.default.removeItem(at: backupURL)

            logger.info("Updated shell integration for \(installedVersions.count) PHP version(s)")

        } catch {
            // Restore from backup on error
            try? restoreFromBackup(backupURL, to: shellFile)
            throw error
        }
    }

    static func removeShellIntegration() throws {
        try updateShellIntegration(installedVersions: [])
    }

    static func removeShellIntegrationCompletely() throws {
        let shellInfo: ShellInfo
        do {
            shellInfo = try ShellDetectionService.detectUserShell()
        } catch {
            throw ShellIntegrationError.shellFileNotFound
        }

        let shellFile = shellInfo.configFile

        // Verify file is writable
        if FileManager.default.fileExists(atPath: shellFile.path) {
            guard FileManager.default.isWritableFile(atPath: shellFile.path) else {
                throw ShellIntegrationError.shellFileNotWritable
            }
        }

        // Create backup before modification
        let backupURL = try createBackup(of: shellFile)

        do {
            // Completely remove all Fadogen lines
            try updateShellFile(at: shellFile, newContent: [])

            // Clean up backup on success
            try? FileManager.default.removeItem(at: backupURL)

            logger.info("Removed shell integration completely")

        } catch {
            // Restore from backup on error
            try? restoreFromBackup(backupURL, to: shellFile)
            throw error
        }
    }

    static func isIntegrationPresent() -> Bool {
        let shellInfo: ShellInfo
        do {
            shellInfo = try ShellDetectionService.detectUserShell()
        } catch {
            return false
        }

        let shellFile = shellInfo.configFile
        guard FileManager.default.fileExists(atPath: shellFile.path) else {
            return false
        }

        do {
            let content = try String(contentsOf: shellFile, encoding: .utf8)
            return content.contains(fadogenMarker)
        } catch {
            return false
        }
    }

    // MARK: - Private

    private static func extractExistingFadogenContent(from url: URL) throws -> [String]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var fadogenLines: [String] = []
        var inFadogenSection = false

        for line in lines {
            if isFadogenLine(line) {
                if line.trimmingCharacters(in: .whitespaces) == fadogenMarker {
                    inFadogenSection = true
                    continue  // Skip marker line
                }
                if inFadogenSection {
                    fadogenLines.append(line)
                }
            } else if inFadogenSection {
                // End of Fadogen section
                break
            }
        }

        return fadogenLines.isEmpty ? nil : fadogenLines
    }

    private static func generateShellContent(shellType: ShellType) -> [String] {
        switch shellType.syntax {
        case .posix:
            return generatePOSIXContent()
        case .fish:
            return generateFishContent()
        }
    }

    private static func generatePOSIXContent() -> [String] {
        var lines: [String] = []

        // Export base directory for fadogen.sh to use (enables Debug/Release switching)
        let basePath = FadogenPaths.baseDirectory.path
        lines.append("export FADOGEN_BASE=\"\(basePath)\"")

        // Add bin/ to PATH for shebang support (#!/usr/bin/env php, #!/usr/bin/env node)
        lines.append("export PATH=\"$FADOGEN_BASE/bin:$PATH\"")

        // Source main Fadogen script (manages PHP, Node.js, Bun, and all tools)
        lines.append("if [ -f \"$FADOGEN_BASE/scripts/fadogen.sh\" ]; then")
        lines.append("    source \"$FADOGEN_BASE/scripts/fadogen.sh\"")
        lines.append("fi")

        return lines
    }

    private static func generateFishContent() -> [String] {
        var lines: [String] = []

        // Export base directory for fadogen.fish to use (enables Debug/Release switching)
        let basePath = FadogenPaths.baseDirectory.path
        lines.append("set -gx FADOGEN_BASE \"\(basePath)\"")

        // Add bin/ to PATH (fish syntax: set -gx for global export)
        lines.append("set -gx PATH \"$FADOGEN_BASE/bin\" $PATH")

        // Source main Fadogen fish script
        lines.append("if test -f \"$FADOGEN_BASE/scripts/fadogen.fish\"")
        lines.append("    source \"$FADOGEN_BASE/scripts/fadogen.fish\"")
        lines.append("end")

        return lines
    }

    private static func updateShellFile(at url: URL, newContent: [String]) throws {
        // Read existing content
        let originalContent: String
        if FileManager.default.fileExists(atPath: url.path) {
            originalContent = try String(contentsOf: url, encoding: .utf8)
        } else {
            originalContent = ""
        }

        let originalLines = originalContent.components(separatedBy: .newlines)

        // Replace/add Fadogen section
        let newLines = extractAndReplaceFadogenSection(from: originalLines, newContent: newContent)

        // Write new content
        let finalContent = newLines.joined(separator: "\n")
        try finalContent.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func extractAndReplaceFadogenSection(
        from lines: [String],
        newContent: [String]
    ) -> [String] {

        var result: [String] = []
        var i = 0
        var fadogenSectionFound = false

        while i < lines.count {
            let line = lines[i]

            if isFadogenLine(line) {
                if !fadogenSectionFound {
                    // First Fadogen line found - add new content
                    if !result.isEmpty && result.last?.isEmpty == false {
                        result.append("") // Empty line before section
                    }

                    if !newContent.isEmpty {
                        result.append(fadogenMarker)
                        result.append(contentsOf: newContent)
                    }

                    fadogenSectionFound = true
                }

                // Skip all existing consecutive Fadogen lines
                while i < lines.count && isFadogenLine(lines[i]) {
                    i += 1
                }
                continue
            }

            result.append(line)
            i += 1
        }

        // If no Fadogen section found and we have content to add
        if !fadogenSectionFound && !newContent.isEmpty {
            if !result.isEmpty && result.last?.isEmpty == false {
                result.append("")
            }
            result.append(fadogenMarker)
            result.append(contentsOf: newContent)
        }

        return result
    }

    /// Handles POSIX and fish syntax, both Release and Debug builds
    private static func isFadogenLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Common marker
        if trimmed == fadogenMarker { return true }

        // Detect Fadogen paths (both Release and Debug builds)
        // Matches: "Application Support/Fadogen/" or "Application Support/Fadogen-Dev/"
        let isFadogenPath = trimmed.contains("Application Support/Fadogen")

        // Detect FADOGEN_BASE variable usage
        let usesFadogenBase = trimmed.contains("FADOGEN_BASE")

        // POSIX patterns (bash/zsh)
        if trimmed.hasPrefix("export FADOGEN_BASE=") && isFadogenPath { return true }
        if trimmed.hasPrefix("export PATH=") && (isFadogenPath || usesFadogenBase) { return true }
        if trimmed.hasPrefix("if [ -f") && (isFadogenPath || usesFadogenBase) { return true }
        if trimmed.hasPrefix("source") && (isFadogenPath || usesFadogenBase) { return true }
        if trimmed == "fi" { return true }

        // Fish patterns
        if trimmed.hasPrefix("set -gx FADOGEN_BASE") && isFadogenPath { return true }
        if trimmed.hasPrefix("set -gx PATH") && (isFadogenPath || usesFadogenBase) { return true }
        if trimmed.hasPrefix("if test -f") && (isFadogenPath || usesFadogenBase) { return true }
        if trimmed.hasPrefix("source") && (isFadogenPath || usesFadogenBase) { return true }
        if trimmed == "end" { return true }

        return false
    }

    private static func createBackup(of url: URL) throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = url.appendingPathExtension("fadogen-backup-\(timestamp)")

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.copyItem(at: url, to: backupURL)
            } else {
                // Create empty backup for non-existent file
                try "".write(to: backupURL, atomically: true, encoding: .utf8)
            }
            logger.debug("Created backup: \(backupURL.lastPathComponent)")
            return backupURL
        } catch {
            throw ShellIntegrationError.backupFailed
        }
    }

    private static func restoreFromBackup(_ backupURL: URL, to originalURL: URL) throws {
        try? FileManager.default.removeItem(at: originalURL)
        try FileManager.default.moveItem(at: backupURL, to: originalURL)
        logger.warning("Restored from backup due to error")
    }
}
