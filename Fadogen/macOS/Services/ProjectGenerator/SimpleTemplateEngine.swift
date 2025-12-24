import Foundation

/// {{VARIABLE}} replacement and {{#IF CONDITION}}...{{/IF}} conditionals
enum SimpleTemplateEngine {

    static func render(
        _ template: String,
        variables: [String: String] = [:],
        conditions: [String: Bool] = [:]
    ) -> String {
        var result = template

        // Process conditionals from innermost to outermost
        // Pattern matches IFs that don't contain nested IFs (innermost first)
        let conditionalPattern = /\{\{#IF (\w+)\}\}((?:(?!\{\{#IF)[\s\S])*?)\{\{\/IF\}\}/
        while let match = result.firstMatch(of: conditionalPattern) {
            let conditionName = String(match.1)
            var content = String(match.2)
            // Remove leading newline that comes from template structure
            if content.hasPrefix("\n") {
                content.removeFirst()
            }
            let shouldInclude = conditions[conditionName] ?? false
            result.replaceSubrange(match.range, with: shouldInclude ? content : "")
        }

        // Process variables: {{VAR}}
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        // Clean up empty lines left by conditionals
        result = result
            .components(separatedBy: "\n")
            .filter { line in
                // Keep non-empty lines or lines that are just whitespace within content
                !line.trimmingCharacters(in: .whitespaces).isEmpty || line.isEmpty
            }
            .joined(separator: "\n")

        // Reduce any sequence of 3+ newlines to exactly 2 (one blank line)
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        // Ensure file ends with exactly one newline
        result = result.trimmingCharacters(in: .newlines) + "\n"

        return result
    }
}
