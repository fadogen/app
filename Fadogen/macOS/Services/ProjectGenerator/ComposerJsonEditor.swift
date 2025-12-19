import Foundation

enum ComposerJsonEditor {

    // MARK: - Public

    static func replaceNpmWithBun(in content: String) -> String {
        var result = content

        // Replace in "dev" script
        result = replaceInScript(named: "dev", replacing: "npm run dev", with: "bun run dev", in: result)
        result = replaceInScript(named: "dev", replacing: "npx ", with: "bunx ", in: result)

        // Replace in "dev:ssr" script
        result = replaceInScript(named: "dev:ssr", replacing: "npm run build:ssr", with: "bun run build:ssr", in: result)
        result = replaceInScript(named: "dev:ssr", replacing: "npx ", with: "bunx ", in: result)

        // Replace in "setup" script
        result = replaceInScript(named: "setup", replacing: "npm install", with: "bun install", in: result)
        result = replaceInScript(named: "setup", replacing: "npm run build", with: "bun run build", in: result)

        return result
    }

    static func removeArtisanServe(in content: String) -> String {
        var result = content

        // Remove from "dev" script
        result = replaceInScript(named: "dev", replacing: #"\"php artisan serve\" "#, with: "", in: result)
        result = replaceInScript(named: "dev", replacing: "#93c5fd,", with: "", in: result)
        result = replaceInScript(named: "dev", replacing: "server,", with: "", in: result)

        // Remove from "dev:ssr" script
        result = replaceInScript(named: "dev:ssr", replacing: #"\"php artisan serve\" "#, with: "", in: result)
        result = replaceInScript(named: "dev:ssr", replacing: "#93c5fd,", with: "", in: result)
        result = replaceInScript(named: "dev:ssr", replacing: "server,", with: "", in: result)

        return result
    }

    static func hasDevScript(in content: String) -> Bool {
        return hasScript(named: "dev", in: content)
    }

    static func hasDevSsrScript(in content: String) -> Bool {
        return hasScript(named: "dev:ssr", in: content)
    }

    static func hasSetupScript(in content: String) -> Bool {
        return hasScript(named: "setup", in: content)
    }

    // MARK: - Private

    private static func replaceInScript(named scriptName: String, replacing oldValue: String, with newValue: String, in content: String) -> String {
        // Find the script block: "scriptName": [...]
        // We need to find the script and replace only within its array
        let pattern = #"("\#(NSRegularExpression.escapedPattern(for: scriptName))"\s*:\s*\[)([^\]]*?)(\])"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return content
        }

        let range = NSRange(content.startIndex..., in: content)

        guard let match = regex.firstMatch(in: content, options: [], range: range),
              let fullRange = Range(match.range, in: content),
              let arrayContentRange = Range(match.range(at: 2), in: content) else {
            return content
        }

        // Get the array content and replace the target string
        let arrayContent = String(content[arrayContentRange])
        let modifiedArrayContent = arrayContent.replacingOccurrences(of: oldValue, with: newValue)

        // If nothing changed, return original
        if arrayContent == modifiedArrayContent {
            return content
        }

        // Reconstruct the full match with modified content
        let prefix = String(content[Range(match.range(at: 1), in: content)!])
        let suffix = String(content[Range(match.range(at: 3), in: content)!])

        var result = content
        result.replaceSubrange(fullRange, with: prefix + modifiedArrayContent + suffix)

        return result
    }

    private static func hasScript(named scriptName: String, in content: String) -> Bool {
        let pattern = #""\#(NSRegularExpression.escapedPattern(for: scriptName))"\s*:\s*\["#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }

        let range = NSRange(content.startIndex..., in: content)
        return regex.firstMatch(in: content, options: [], range: range) != nil
    }
}
