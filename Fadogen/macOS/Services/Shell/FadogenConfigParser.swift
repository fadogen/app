import Foundation

nonisolated enum FadogenConfigParser {

    struct Config {
        var phpVersion: String?
        var nodeVersion: String?
        var bunVersion: String?
        var packageManager: String?
    }

    enum ParseError: LocalizedError {
        case fileNotFound
        case invalidFormat(line: Int, content: String)
        case duplicateSection(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return ".fadogen file not found"
            case .invalidFormat(let line, let content):
                return "Invalid format at line \(line): \(content)"
            case .duplicateSection(let section):
                return "Duplicate section: [\(section)]"
            }
        }
    }

    static func parse(in directory: URL) throws -> Config? {
        let fadogenFile = directory.appendingPathComponent(".fadogen")

        guard FileManager.default.fileExists(atPath: fadogenFile.path) else {
            return nil
        }

        let content = try String(contentsOf: fadogenFile, encoding: .utf8)
        return try parse(content: content)
    }

    static func parse(content: String) throws -> Config {
        var config = Config()
        var currentSection: String?
        var seenSections: Set<String> = []

        let lines = content.components(separatedBy: .newlines)

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            // Section header: [section]
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)

                // Check for duplicate sections
                if seenSections.contains(section) {
                    throw ParseError.duplicateSection(section)
                }
                seenSections.insert(section)
                currentSection = section
                continue
            }

            // Key-value pair: key = "value"
            if line.contains("=") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else {
                    throw ParseError.invalidFormat(line: index + 1, content: line)
                }

                let key = parts[0].trimmingCharacters(in: .whitespaces)
                var value = parts[1].trimmingCharacters(in: .whitespaces)

                // Remove quotes if present
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }

                // Assign to appropriate section
                guard let section = currentSection else {
                    throw ParseError.invalidFormat(line: index + 1, content: "Key '\(key)' outside of section")
                }

                // Assign based on section and key
                switch section {
                case "php":
                    if key == "version" { config.phpVersion = value }
                case "node":
                    if key == "version" { config.nodeVersion = value }
                case "bun":
                    if key == "version" { config.bunVersion = value }
                case "javascript":
                    if key == "packageManager" { config.packageManager = value }
                default:
                    // Ignore unknown sections
                    break
                }
                continue
            }

            // Unrecognized line format
            throw ParseError.invalidFormat(line: index + 1, content: line)
        }

        return config
    }

    static func write(_ config: Config, to directory: URL) throws {
        var lines: [String] = []

        lines.append("# Fadogen Project Configuration")
        lines.append("")

        if let phpVersion = config.phpVersion {
            lines.append("[php]")
            lines.append("version = \"\(phpVersion)\"")
            lines.append("")
        }

        if let nodeVersion = config.nodeVersion {
            lines.append("[node]")
            lines.append("version = \"\(nodeVersion)\"")
            lines.append("")
        }

        if let bunVersion = config.bunVersion {
            lines.append("[bun]")
            lines.append("version = \"\(bunVersion)\"")
            lines.append("")
        }

        if let packageManager = config.packageManager {
            lines.append("[javascript]")
            lines.append("packageManager = \"\(packageManager)\"")
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        let fadogenFile = directory.appendingPathComponent(".fadogen")

        try content.write(to: fadogenFile, atomically: true, encoding: .utf8)
    }

    static func updateVersion(in directory: URL, section: String, version: String?) throws {
        // Read existing config or create new one
        var config = try parse(in: directory) ?? Config()

        // Update the appropriate section
        switch section {
        case "php":
            config.phpVersion = version
        case "node":
            config.nodeVersion = version
        case "bun":
            config.bunVersion = version
        default:
            break
        }

        // If all values are nil, remove the file
        if config.phpVersion == nil && config.nodeVersion == nil && config.bunVersion == nil && config.packageManager == nil {
            let fadogenFile = directory.appendingPathComponent(".fadogen")
            if FileManager.default.fileExists(atPath: fadogenFile.path) {
                try FileManager.default.removeItem(at: fadogenFile)
            }
            return
        }

        // Write updated config
        try write(config, to: directory)
    }

    static func updatePackageManager(in directory: URL, packageManager: String?) throws {
        // Read existing config or create new one
        var config = try parse(in: directory) ?? Config()

        // Update package manager
        config.packageManager = packageManager

        // If all values are nil, remove the file
        if config.phpVersion == nil && config.nodeVersion == nil && config.bunVersion == nil && config.packageManager == nil {
            let fadogenFile = directory.appendingPathComponent(".fadogen")
            if FileManager.default.fileExists(atPath: fadogenFile.path) {
                try FileManager.default.removeItem(at: fadogenFile)
            }
            return
        }

        // Write updated config
        try write(config, to: directory)
    }
}
