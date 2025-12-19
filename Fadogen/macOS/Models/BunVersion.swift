import Foundation
import SwiftData

/// Single-version model (always the latest)
@Model
final class BunVersion {

    var version: String = ""  // e.g., "1.1.38"

    var binaryPath: URL {
        FadogenPaths.binDirectory.appendingPathComponent("bun")
    }

    init(version: String) {
        self.version = version
    }
}
