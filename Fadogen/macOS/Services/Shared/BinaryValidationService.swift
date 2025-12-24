import Foundation

/// Skips downloads when binaries already exist in /Users/Shared/Fadogen
nonisolated enum BinaryValidationService {

    static func validateServiceBinaries(service: ServiceType, major: String) -> Bool {
        let path = FadogenPaths.binaryPath(for: service, major: major)
            .appendingPathComponent(service.primaryExecutable)
        return FileManager.default.isExecutableFile(atPath: path.path)
    }

    static func validateNodeBinaries(major: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: FadogenPaths.nodeBinaryPath(for: major).path)
    }

    static func validateReverbBinaries() -> Bool {
        let path = FadogenPaths.reverbBinaryPath.appendingPathComponent("artisan")
        return FileManager.default.fileExists(atPath: path.path)
    }

    static func validateTypesenseBinaries() -> Bool {
        let path = FadogenPaths.typesenseBinaryPath.appendingPathComponent("typesense-server")
        return FileManager.default.isExecutableFile(atPath: path.path)
    }
}
