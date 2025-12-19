import Foundation
import SwiftData

@Model
final class PHPVersion {

    /// Only one version per major branch (enforced in service layer)
    var major: String = ""  // e.g., "8.4"
    var minor: String = ""  // e.g., "8.4.7"

    /// Only one true at a time (enforced in service layer)
    var isDefault: Bool = false

    var projects: [LocalProject]? = []

    /// e.g., ~/Library/Application Support/Fadogen/bin/php84
    var binaryPath: URL {
        FadogenPaths.binaryPath(for: major)
    }

    /// e.g., ~/Library/Application Support/Fadogen/config/php/84
    var configPath: URL {
        FadogenPaths.configPath(for: major)
    }

    init(major: String, minor: String, isDefault: Bool = false) {
        self.major = major
        self.minor = minor
        self.isDefault = isDefault
    }
}
