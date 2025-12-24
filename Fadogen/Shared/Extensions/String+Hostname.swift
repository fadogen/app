import Foundation

extension String {

    /// Reserved hostnames used by Fadogen services
    /// Projects with these names will have "-project" appended to avoid conflicts
    nonisolated private static var reservedHostnames: Set<String> {
        ["reverb", "typesense", "mail"]
    }

    /// Sanitize to RFC 1123 hostname (a-z, 0-9, hyphen, 1-63 chars)
    nonisolated func sanitizedHostname() -> String? {
        // 1. Convert to lowercase
        var result = self.lowercased()

        // 2. Replace spaces and underscores with hyphens
        result = result.replacingOccurrences(of: " ", with: "-")
        result = result.replacingOccurrences(of: "_", with: "-")

        // 3. Keep only allowed characters: a-z, 0-9, -
        result = result.filter { character in
            character.isLetter || character.isNumber || character == "-"
        }

        // 4. Collapse consecutive hyphens into single hyphen
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }

        // 5. Trim leading and trailing hyphens
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // 6. Validate length (1-63 characters)
        guard !result.isEmpty, result.count <= 63 else {
            return nil
        }

        // 7. Validate format: must start and end with alphanumeric
        guard let first = result.first, let last = result.last else {
            return nil
        }

        guard (first.isLetter || first.isNumber) && (last.isLetter || last.isNumber) else {
            return nil
        }

        return result
    }

    /// Sanitize to RFC 1123 hostname and avoid reserved service hostnames
    /// Appends "-project" suffix if the hostname conflicts with a reserved name
    nonisolated func sanitizedHostnameAvoidingConflicts() -> String? {
        guard let sanitized = sanitizedHostname() else { return nil }
        return Self.reservedHostnames.contains(sanitized) ? "\(sanitized)-project" : sanitized
    }
}
