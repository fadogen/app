import Foundation
import SwiftData

/// Typesense search server
@Model
final class TypesenseVersion {

    var version: String = ""  // e.g., "28.0"
    var port: Int = 8108
    var autoStart: Bool = false
    var uniqueIdentifier: String = ""

    var binaryPath: URL {
        FadogenPaths.typesenseBinaryPath
    }

    var dataPath: URL {
        FadogenPaths.typesenseDataDirectory
    }

    init(version: String, port: Int = 8108, autoStart: Bool = false) {
        self.version = version
        self.port = port
        self.autoStart = autoStart
        self.uniqueIdentifier = "typesense"
    }
}
