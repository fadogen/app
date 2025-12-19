import Foundation

enum BootstrapAppEditor {

    static func addTrustedProxies(in content: String) -> String {
        // Skip if trustProxies is already configured (idempotency)
        if content.contains("trustProxies") {
            return content
        }

        // Find the withMiddleware callback and insert trustProxies as the first call
        return addTrustedProxiesCall(in: content)
    }

    // MARK: - Private

    private static let trustedProxiesBlock = """
        $middleware->trustProxies(at: [
                    '10.0.0.0/8',      // Docker Swarm overlay networks
                    '172.16.0.0/12',   // Docker bridge networks
                    '192.168.0.0/16',  // Private networks
                ]);

        """

    private static func addTrustedProxiesCall(in content: String) -> String {
        // Pattern to match: ->withMiddleware(function (Middleware $middleware): void {
        // We need to find the opening brace of the callback body
        let middlewarePattern = #"(->withMiddleware\s*\(\s*function\s*\(\s*Middleware\s+\$middleware\s*\)\s*:\s*void\s*\{)(\s*)"#

        guard let regex = try? NSRegularExpression(pattern: middlewarePattern, options: []) else {
            return content
        }

        let range = NSRange(content.startIndex..., in: content)

        guard let match = regex.firstMatch(in: content, options: [], range: range) else {
            return content
        }

        // Get the matched groups
        guard let fullMatchRange = Range(match.range(at: 0), in: content),
              let callbackOpenRange = Range(match.range(at: 1), in: content) else {
            return content
        }

        let callbackOpen = String(content[callbackOpenRange])

        // Extract the whitespace after the opening brace
        let whitespaceAfter = match.range(at: 2).length > 0
            ? String(content[Range(match.range(at: 2), in: content)!])
            : ""

        // Determine the indentation from the captured whitespace
        let indentation = extractIndentation(from: whitespaceAfter)

        // Build the trusted proxies block with proper indentation
        let indentedBlock = buildIndentedTrustedProxiesBlock(indentation: indentation)

        // Build the replacement: callback open + newline + indented trustProxies + original whitespace
        let replacement = callbackOpen + "\n" + indentedBlock + whitespaceAfter

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

        // Default to 8 spaces (common for Laravel bootstrap/app.php)
        return "        "
    }

    private static func buildIndentedTrustedProxiesBlock(indentation: String) -> String {
        // Base indentation for the $middleware->trustProxies call
        let baseIndent = indentation

        // Additional indentation for array items (4 more spaces)
        let arrayIndent = indentation + "    "

        var block = "\(baseIndent)$middleware->trustProxies(at: [\n"
        block += "\(arrayIndent)'10.0.0.0/8',      // Docker Swarm overlay networks\n"
        block += "\(arrayIndent)'172.16.0.0/12',   // Docker bridge networks\n"
        block += "\(arrayIndent)'192.168.0.0/16',  // Private networks\n"
        block += "\(baseIndent)]);\n"

        return block
    }
}
