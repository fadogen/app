import Foundation
import SwiftData

extension ModelContext {
    /// Checks if a localURL is already in use by a LocalProject
    /// - Parameters:
    ///   - url: The URL to check
    ///   - excludingProjectID: Optional project ID to exclude from check (for editing existing project)
    /// - Returns: true if URL is taken by another project
    func isLocalURLTaken(_ url: String, excludingProjectID: UUID? = nil) -> Bool {
        let urlToCheck = url
        let descriptor = FetchDescriptor<LocalProject>(
            predicate: #Predicate { $0.localURL == urlToCheck }
        )
        guard let existingProject = try? fetch(descriptor).first else {
            return false
        }
        if let excludeID = excludingProjectID {
            return existingProject.id != excludeID
        }
        return true
    }

    /// Finds a unique hostname by appending suffixes (-2, -3, etc.) if needed
    /// - Parameters:
    ///   - baseName: The base name to sanitize and use
    ///   - excludingProjectID: Optional project ID to exclude from uniqueness check
    /// - Returns: A unique hostname, or nil if baseName cannot be sanitized
    func findUniqueHostname(_ baseName: String, excludingProjectID: UUID? = nil) -> String? {
        guard let sanitized = baseName.sanitizedHostname() else {
            return nil
        }

        var hostname = sanitized
        var suffix = 2

        while isLocalURLTaken("https://\(hostname).localhost", excludingProjectID: excludingProjectID) {
            hostname = "\(sanitized)-\(suffix)"
            suffix += 1

            // Safety limit
            if suffix > 100 {
                return nil
            }
        }

        return hostname
    }
}
