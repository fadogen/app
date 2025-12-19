import Foundation
import SwiftData

/// Laravel Reverb WebSocket server
@Model
final class ReverbVersion {

    var version: String = ""  // e.g., "v1.6.0"
    var port: Int = 8080
    var autoStart: Bool = false
    var uniqueIdentifier: String = ""

    var binaryPath: URL {
        FadogenPaths.reverbBinaryPath
    }

    init(version: String, port: Int = 8080, autoStart: Bool = false) {
        self.version = version
        self.port = port
        self.autoStart = autoStart
        self.uniqueIdentifier = "reverb"
    }
}
