import Foundation
import SwiftData

/// Single-version model (unlike PHP)
@Model
final class ComposerVersion {

    var version: String = ""  // e.g., "2.8.12"

    var binaryPath: URL {
        FadogenPaths.binDirectory.appendingPathComponent("composer")
    }

    init(version: String) {
        self.version = version
    }
}
