import Foundation
import SwiftData

/// Fixed API credentials for Garage S3 - same across all Fadogen installations for easy migration
/// Access Key format: GK + 12 bytes hex (24 chars) = 26 chars total
/// Secret Key format: 32 bytes hex = 64 chars
let garageAccessKeyId = "GK6661646f67656e3067617261"
let garageSecretAccessKey = "6661646f67656e67617261676573656372657430303030303030303030303030"

/// Garage S3 storage server
@Model
final class GarageVersion {

    var version: String = ""  // e.g., "2.1.0"
    var s3Port: Int = 3900
    var rpcPort: Int = 3901
    var adminPort: Int = 3903
    var autoStart: Bool = false
    var uniqueIdentifier: String = ""
    var isInitialized: Bool = false  // Layout + key configured

    var binaryPath: URL {
        FadogenPaths.garageBinaryPath
    }

    var dataPath: URL {
        FadogenPaths.garageDataDirectory
    }

    var configPath: URL {
        FadogenPaths.garageConfigPath
    }

    init(version: String, s3Port: Int = 3900, autoStart: Bool = false) {
        self.version = version
        self.s3Port = s3Port
        self.rpcPort = s3Port + 1
        self.adminPort = s3Port + 3
        self.autoStart = autoStart
        self.uniqueIdentifier = "garage"
        self.isInitialized = false
    }
}
