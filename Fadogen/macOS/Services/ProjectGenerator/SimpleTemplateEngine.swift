import Foundation

/// {{VARIABLE}} replacement and {{#IF CONDITION}}...{{/IF}} conditionals
enum SimpleTemplateEngine {

    static func render(
        _ template: String,
        variables: [String: String] = [:],
        conditions: [String: Bool] = [:]
    ) -> String {
        var result = template

        // Process conditionals: {{#IF VAR}}...{{/IF}}
        let conditionalPattern = /\{\{#IF (\w+)\}\}([\s\S]*?)\{\{\/IF\}\}/
        while let match = result.firstMatch(of: conditionalPattern) {
            let conditionName = String(match.1)
            let content = String(match.2)
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
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")

        return result
    }
}
