import Foundation

enum ViteConfigEditor {

    static func addFadogenPlugin(in content: String) -> String {
        var result = content

        // Skip if fadogen is already imported
        if content.contains("@fadogen/vite-plugin") {
            return content
        }

        // Add import statement after the last import
        result = addFadogenImport(in: result)

        // Add fadogen() as the first plugin in the plugins array
        result = addFadogenToPlugins(in: result)

        return result
    }

    // MARK: - Private

    private static func addFadogenImport(in content: String) -> String {
        let importStatement = "import fadogen from '@fadogen/vite-plugin';"

        // Find the last import statement using regex
        // Match: import ... from '...' or import ... from "..."
        let importPattern = #"import\s+.*\s+from\s+['"][^'"]+['"];?"#

        guard let regex = try? NSRegularExpression(pattern: importPattern, options: []) else {
            return content
        }

        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)

        guard let lastMatch = matches.last else {
            // No imports found, add at the beginning
            return importStatement + "\n" + content
        }

        // Find the end of the last import line (including newline if present)
        let lastMatchEnd = lastMatch.range.location + lastMatch.range.length
        guard let insertIndex = content.index(content.startIndex, offsetBy: lastMatchEnd, limitedBy: content.endIndex) else {
            return content
        }

        var result = content
        result.insert(contentsOf: "\n" + importStatement, at: insertIndex)

        return result
    }

    private static func addFadogenToPlugins(in content: String) -> String {
        // Pattern to match: plugins: [ followed by whitespace
        // Capture the whitespace separately to extract indentation
        let pluginsPattern = #"(plugins:\s*\[)(\s*)"#

        guard let regex = try? NSRegularExpression(pattern: pluginsPattern, options: []) else {
            return content
        }

        let range = NSRange(content.startIndex..., in: content)

        guard let match = regex.firstMatch(in: content, options: [], range: range) else {
            return content
        }

        // Get the matched groups
        guard let fullMatchRange = Range(match.range(at: 0), in: content),
              let pluginsOpenRange = Range(match.range(at: 1), in: content) else {
            return content
        }

        let pluginsOpen = String(content[pluginsOpenRange])

        // Extract the whitespace after plugins: [
        // This contains the newline + indentation for the first plugin
        let whitespaceAfter = match.range(at: 2).length > 0
            ? String(content[Range(match.range(at: 2), in: content)!])
            : ""

        // Determine the indentation from the captured whitespace
        // The whitespace contains newline + indentation (e.g., "\n        ")
        let indentation = extractIndentation(from: whitespaceAfter)

        // Build the replacement: plugins: [\n        fadogen(),\n        (for next plugin)
        let replacement = pluginsOpen + "\n" + indentation + "fadogen()," + whitespaceAfter

        var result = content
        result.replaceSubrange(fullMatchRange, with: replacement)

        return result
    }

    private static func extractIndentation(from whitespace: String) -> String {
        // The whitespace typically contains: \n + spaces/tabs
        // We want to extract just the spaces/tabs part (after the last newline)
        if let lastNewline = whitespace.lastIndex(of: "\n") {
            let afterNewline = whitespace.index(after: lastNewline)
            return String(whitespace[afterNewline...])
        }

        // No newline found, return the whitespace as-is or default
        if !whitespace.isEmpty {
            return whitespace
        }

        // Default to 8 spaces (common for Vite configs)
        return "        "
    }
}
