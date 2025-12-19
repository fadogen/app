import Foundation

extension String {
    /// Extracts normalized "owner/repo" identifier from any Git remote URL format
    /// - "git@github.com:owner/repo.git" → "owner/repo"
    /// - "https://github.com/owner/repo.git" → "owner/repo"
    /// - "https://github.com/owner/repo" → "owner/repo"
    /// - Returns nil if not a valid GitHub URL
    nonisolated func githubIdentifier() -> String? {
        // SSH format: git@github.com:owner/repo.git
        if hasPrefix("git@github.com:") {
            let path = replacingOccurrences(of: "git@github.com:", with: "")
                .replacingOccurrences(of: ".git", with: "")
            let components = path.split(separator: "/")
            guard components.count == 2 else { return nil }
            return path
        }

        // HTTPS format: https://github.com/owner/repo.git or https://github.com/owner/repo
        if contains("github.com/") {
            // Extract path after github.com/
            guard let range = range(of: "github.com/") else { return nil }
            var path = String(self[range.upperBound...])
                .replacingOccurrences(of: ".git", with: "")

            // Remove trailing slash if present
            if path.hasSuffix("/") {
                path = String(path.dropLast())
            }

            let components = path.split(separator: "/")
            guard components.count >= 2 else { return nil }

            // Return only owner/repo (ignore additional path components)
            return "\(components[0])/\(components[1])"
        }

        return nil
    }

    /// Extracts GitHub owner from remote URL
    nonisolated var githubOwner: String? {
        githubIdentifier()?.split(separator: "/").first.map(String.init)
    }

    /// Extracts GitHub repository name from remote URL
    nonisolated var githubRepo: String? {
        githubIdentifier()?.split(separator: "/").last.map(String.init)
    }

    /// Converts a Git remote URL to a GitHub web URL
    /// - "git@github.com:owner/repo.git" → "https://github.com/owner/repo"
    /// - "https://github.com/owner/repo.git" → "https://github.com/owner/repo"
    /// - Returns nil if not a valid GitHub URL
    nonisolated var gitHubURL: URL? {
        // SSH format: git@github.com:user/repo.git
        if hasPrefix("git@github.com:") {
            let path = replacingOccurrences(of: "git@github.com:", with: "")
                .replacingOccurrences(of: ".git", with: "")
            return URL(string: "https://github.com/\(path)")
        }

        // HTTPS format: https://github.com/user/repo.git
        if hasPrefix("https://github.com/") {
            let cleanURL = replacingOccurrences(of: ".git", with: "")
            return URL(string: cleanURL)
        }

        return nil
    }
}
