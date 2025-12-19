import Foundation
import SwiftData

@Model
final class NodeVersion {

    /// Only one version per major branch (enforced in service layer)
    var major: String = ""  // e.g., "22"
    var minor: String = ""  // e.g., "22.21.0"

    /// Only one true at a time (enforced in service layer)
    var isDefault: Bool = false

    var projects: [LocalProject]? = []

    /// e.g., /Users/Shared/Fadogen/node/22/bin/node
    var binaryPath: URL {
        FadogenPaths.nodeBinaryPath(for: major)
    }

    /// e.g., /Users/Shared/Fadogen/node/22/
    var installPath: URL {
        FadogenPaths.nodeInstallPath(for: major)
    }

    init(major: String, minor: String, isDefault: Bool = false) {
        self.major = major
        self.minor = minor
        self.isDefault = isDefault
    }
}
