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
    /// Handles reserved hostnames (reverb, typesense, mail) by applying conflict avoidance
    /// - Parameters:
    ///   - baseName: The base name to sanitize and use
    ///   - excludingProjectID: Optional project ID to exclude from uniqueness check
    /// - Returns: A unique hostname (with conflicts resolved), or nil if baseName cannot be sanitized
    func findUniqueHostname(_ baseName: String, excludingProjectID: UUID? = nil) -> String? {
        // Use sanitizedHostnameAvoidingConflicts to handle reserved hostnames
        guard let effectiveHostname = baseName.sanitizedHostnameAvoidingConflicts() else {
            return nil
        }

        var hostname = effectiveHostname
        var suffix = 2

        while isLocalURLTaken("https://\(hostname).localhost", excludingProjectID: excludingProjectID) {
            hostname = "\(effectiveHostname)-\(suffix)"
            suffix += 1

            // Safety limit
            if suffix > 100 {
                return nil
            }
        }

        return hostname
    }
}
