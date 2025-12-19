import Foundation

enum PHPConfigParserError: LocalizedError {
    case fileNotFound
    case invalidFormat
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            "php.ini file not found"
        case .invalidFormat:
            "Invalid INI file format"
        case .writeFailed:
            "Failed to write php.ini file"
        }
    }
}

@MainActor
final class PHPConfigParser {

    func parse(iniPath: URL) throws -> PHPConfig {
        guard FileManager.default.fileExists(atPath: iniPath.path) else {
            throw PHPConfigParserError.fileNotFound
        }

        let content = try String(contentsOf: iniPath, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var uploadMaxFilesize: Int?
        var memoryLimit: Int?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            guard !trimmed.isEmpty, !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#") else {
                continue
            }

            // Parse directive = value
            if let directive = parseDirective(line: trimmed) {
                switch directive.name {
                case "upload_max_filesize":
                    uploadMaxFilesize = parseSize(directive.value)
                case "post_max_size":
                    // Use post_max_size as fallback if upload_max_filesize not found
                    if uploadMaxFilesize == nil {
                        uploadMaxFilesize = parseSize(directive.value)
                    }
                case "memory_limit":
                    memoryLimit = parseSize(directive.value)
                default:
                    continue
                }
            }
        }

        return PHPConfig(
            uploadMaxFilesize: uploadMaxFilesize ?? PHPConfig.default.uploadMaxFilesize,
            memoryLimit: memoryLimit ?? PHPConfig.default.memoryLimit
        )
    }

    func update(iniPath: URL, config: PHPConfig) throws {
        guard FileManager.default.fileExists(atPath: iniPath.path) else {
            throw PHPConfigParserError.fileNotFound
        }

        let content = try String(contentsOf: iniPath, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var updatedLines: [String] = []
        var foundUpload = false
        var foundPost = false
        var foundMemory = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Preserve comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
                updatedLines.append(line)
                continue
            }

            // Check if this line contains one of our directives
            if let directive = parseDirective(line: trimmed) {
                switch directive.name {
                case "upload_max_filesize":
                    updatedLines.append("upload_max_filesize = \(config.uploadMaxFilesize)M")
                    foundUpload = true
                case "post_max_size":
                    updatedLines.append("post_max_size = \(config.uploadMaxFilesize)M")
                    foundPost = true
                case "memory_limit":
                    updatedLines.append("memory_limit = \(config.memoryLimit)M")
                    foundMemory = true
                default:
                    updatedLines.append(line)
                }
            } else {
                updatedLines.append(line)
            }
        }

        // Append missing directives if not found
        if !foundUpload {
            updatedLines.append("upload_max_filesize = \(config.uploadMaxFilesize)M")
        }
        if !foundPost {
            updatedLines.append("post_max_size = \(config.uploadMaxFilesize)M")
        }
        if !foundMemory {
            updatedLines.append("memory_limit = \(config.memoryLimit)M")
        }

        // Write updated content
        let updatedContent = updatedLines.joined(separator: "\n")
        do {
            try updatedContent.write(to: iniPath, atomically: true, encoding: .utf8)
        } catch {
            throw PHPConfigParserError.writeFailed
        }
    }

    // MARK: - Private

    private func parseDirective(line: String) -> (name: String, value: String)? {
        let components = line.components(separatedBy: "=")
        guard components.count == 2 else { return nil }

        let name = components[0].trimmingCharacters(in: .whitespaces)
        let value = components[1].trimmingCharacters(in: .whitespaces)

        return (name, value)
    }

    private func parseSize(_ value: String) -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespaces).uppercased()

        // Extract numeric part
        let numeric = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()

        guard let number = Int(numeric) else {
            return PHPConfig.default.uploadMaxFilesize
        }

        // Check suffix
        if trimmed.hasSuffix("G") {
            return number * 1024 // Convert GB to MB
        } else if trimmed.hasSuffix("K") {
            return max(1, number / 1024) // Convert KB to MB (minimum 1)
        } else {
            // Assume MB or no suffix
            return number
        }
    }
}
