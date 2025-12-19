import Foundation

enum GitHubWorkflowEditor {

    // MARK: - Public

    static func replaceNpmWithBun(in content: String) -> String {
        var result = content

        // 1. Replace setup-node action with setup-bun
        result = replaceSetupNodeAction(in: result)

        // 2. Remove node-version line
        result = removeNodeVersionLine(in: result)

        // 3. Remove cache: 'npm' line
        result = removeCacheLine(in: result)

        // 4. Remove empty 'with:' block if it became empty
        result = removeEmptyWithBlock(in: result)

        // 5. Replace npm commands with bun equivalents
        result = replaceNpmCommands(in: result)

        // 6. Rename "Setup Node" step to "Setup Bun"
        result = renameSetupNodeStep(in: result)

        // 7. Add setup-bun step if bun commands exist but no setup-bun action
        result = addSetupBunIfNeeded(in: result)

        return result
    }

    // MARK: - Private

    private static func replaceSetupNodeAction(in content: String) -> String {
        // Match any version of setup-node (v3, v4, etc.)
        let pattern = #"uses:\s*actions/setup-node@v\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return content
        }

        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "uses: oven-sh/setup-bun@v2")
    }

    private static func removeNodeVersionLine(in content: String) -> String {
        // Match lines like "          node-version: '22'" or "node-version: 22"
        let pattern = #"^[ \t]*node-version:.*\n"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return content
        }

        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "")
    }

    private static func removeCacheLine(in content: String) -> String {
        // Match lines like "          cache: 'npm'" or "cache: npm"
        let pattern = #"^[ \t]*cache:[ \t]*['"]?npm['"]?[ \t]*\n"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return content
        }

        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "")
    }

    private static func removeEmptyWithBlock(in content: String) -> String {
        // Match 'with:' followed by optional empty lines, then a new step (- name:) or less/equal indented key
        // Pattern: "        with:\n\n      - name:" or "        with:\n      - name:"
        // Replace with single newline to preserve blank line separator between steps
        let pattern = #"^([ \t]*)with:[ \t]*\n([ \t]*\n)*(?=[ \t]*-)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return content
        }

        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "\n")
    }

    private static func replaceNpmCommands(in content: String) -> String {
        var result = content

        // npm ci -> bun install --frozen-lockfile
        result = result.replacingOccurrences(of: "npm ci", with: "bun install --frozen-lockfile")

        // npm install (standalone, not part of other text) -> bun install
        // Be careful not to replace "npm install" inside "bun install"
        result = result.replacingOccurrences(of: "npm install", with: "bun install")

        // npm run -> bun run
        result = result.replacingOccurrences(of: "npm run ", with: "bun run ")

        return result
    }

    private static func renameSetupNodeStep(in content: String) -> String {
        // Match variations like "- name: Setup Node" or "name: Setup Node.js"
        let pattern = #"(- name:\s*)Setup Node(\.js)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return content
        }

        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "$1Setup Bun")
    }

    private static func addSetupBunIfNeeded(in content: String) -> String {
        // Check if bun commands exist (but not just "ubuntu" which contains "bun")
        let hasBunCommands = content.contains("bun install") || content.contains("bun run ")

        // Check if setup-bun already exists
        let hasSetupBun = content.contains("oven-sh/setup-bun")

        // Only add if bun commands exist but no setup-bun
        guard hasBunCommands && !hasSetupBun else {
            return content
        }

        // Use line-based approach for robustness
        var lines = content.components(separatedBy: "\n")

        // Find insertion point after PHP setup, before the next step
        if let insertIndex = findInsertionIndexAfterPhpSetup(in: lines) {
            let indentation = detectStepIndentation(in: lines, around: insertIndex)
            // Don't add blank line before (original workflow already has one between steps)
            // Add blank line after to separate from the next step
            let setupBunLines = [
                "\(indentation)- name: Setup Bun",
                "\(indentation)  uses: oven-sh/setup-bun@v2",
                ""
            ]
            lines.insert(contentsOf: setupBunLines, at: insertIndex)
            return lines.joined(separator: "\n")
        }

        // Fallback: insert after checkout
        if let insertIndex = findInsertionIndexAfterCheckout(in: lines) {
            let indentation = detectStepIndentation(in: lines, around: insertIndex)
            let setupBunLines = [
                "\(indentation)- name: Setup Bun",
                "\(indentation)  uses: oven-sh/setup-bun@v2",
                ""
            ]
            lines.insert(contentsOf: setupBunLines, at: insertIndex)
            return lines.joined(separator: "\n")
        }

        return content
    }

    private static func findInsertionIndexAfterPhpSetup(in lines: [String]) -> Int? {
        guard let phpIndex = lines.firstIndex(where: { $0.contains("shivammathur/setup-php") }) else {
            return nil
        }

        // Find the next step after PHP setup (line starting with spaces + dash)
        for i in (phpIndex + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- name:") || trimmed.hasPrefix("- uses:") {
                return i
            }
        }

        return nil
    }

    private static func findInsertionIndexAfterCheckout(in lines: [String]) -> Int? {
        guard let checkoutIndex = lines.firstIndex(where: { $0.contains("actions/checkout") }) else {
            return nil
        }

        // Find the next step after checkout
        for i in (checkoutIndex + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- name:") || trimmed.hasPrefix("- uses:") {
                return i
            }
        }

        return nil
    }

    private static func detectStepIndentation(in lines: [String], around index: Int) -> String {
        // Look at the line at the given index to detect indentation
        if index < lines.count {
            let line = lines[index]
            let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" })
            return String(leadingSpaces)
        }
        // Default to 6 spaces (common in GitHub Actions)
        return "      "
    }
}
