import Foundation
import SwiftData

@Observable
final class ReverbManager {

    var availableMetadata: ReverbMetadata?
    var isLoading = false
    var errorMessage: String?

    var isInstalling = false
    var isRemoving = false
    var isUpdating = false
    var operationError: String?

    private let metadataURL = GenericDownloadService.metadataURL(for: "reverb")
    private let modelContext: ModelContext
    private weak var reverbProcess: ReverbProcessManager?
    private weak var caddyConfig: CaddyConfigService?

    init(modelContext: ModelContext, reverbProcess: ReverbProcessManager? = nil, caddyConfig: CaddyConfigService? = nil) {
        self.modelContext = modelContext
        self.reverbProcess = reverbProcess
        self.caddyConfig = caddyConfig
    }

    func initialize() async {
        await refresh()
    }

    // MARK: - Metadata

    func refresh() async {
        // GUARD: Prevent concurrent fetches
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            // Create URLSession without cache to avoid 404 cached errors
            let session = DownloadUtilities.createNoCacheSession()

            let (data, response) = try await session.data(from: self.metadataURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ReverbManagerError.invalidResponse
            }

            let decoder = JSONDecoder()
            let collection = try decoder.decode(ReverbMetadataCollection.self, from: data)

            // Extract "reverb" key
            guard let metadata = collection["reverb"] else {
                throw ReverbManagerError.invalidMetadata
            }

            availableMetadata = metadata

        } catch {
            errorMessage = "Unable to check for updates"
        }

        isLoading = false
    }

    var isAnyOperationActive: Bool {
        isInstalling || isRemoving || isUpdating
    }

    // MARK: - Installation

    func install(port: Int = 8080, autoStart: Bool = false) async throws {
        // GUARD: Check for active operation
        guard !isAnyOperationActive else {
            throw ReverbInstallError.anotherOperationInProgress
        }

        // Set state BEFORE async work
        isInstalling = true
        operationError = nil
        reverbProcess?.clearStartupError()

        // Cleanup in ALL cases (success or error)
        defer {
            isInstalling = false
        }

        do {
            // Step 1: Validate metadata exists
            guard let metadata = availableMetadata else {
                throw ReverbInstallError.metadataNotAvailable
            }

            // Step 2: Check not already installed
            let descriptor = FetchDescriptor<ReverbVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "reverb" }
            )
            if try modelContext.fetch(descriptor).first != nil {
                throw ReverbInstallError.alreadyInstalled
            }

            // Step 3: Check if binaries already exist (multi-user optimization)
            let binariesExist = BinaryValidationService.validateReverbBinaries()

            if !binariesExist {
                // Step 3b: Preventive deletion of binary directory (if partial/corrupted)
                let binaryPath = FadogenPaths.reverbBinaryPath
                if FileManager.default.fileExists(atPath: binaryPath.path) {
                    try FileManager.default.removeItem(at: binaryPath)
                }

                // Step 4: Download
                let archiveURL = try await ReverbDownloadService.download(
                    metadata: metadata,
                    progressHandler: { _ in }
                )

                // Step 5: Extract and install
                try await ReverbDownloadService.extractAndInstall(archiveURL: archiveURL)
            }

            // Step 6: Create SwiftData model
            let reverbVersion = ReverbVersion(
                version: metadata.latest,
                port: port,
                autoStart: autoStart
            )
            modelContext.insert(reverbVersion)
            try modelContext.save()

            // Step 7: Regenerate Caddy config (adds Reverb proxy)
            try caddyConfig?.generateMainCaddyfile()

            // Step 8: Reload Caddy to apply new configuration and generate certificate
            caddyConfig?.reloadCaddy()

            // Step 8b: Wait for Caddy to generate reverb.localhost certificate
            // Similar to AppServices startup, but shorter timeout since Caddy is already running
            let certPath = FadogenPaths.caddyDataDirectory
                .appendingPathComponent("pki/authorities/local/reverb.localhost.crt")

            var attempts = 0
            let maxAttempts = 100  // 10 seconds
            while attempts < maxAttempts {
                if FileManager.default.fileExists(atPath: certPath.path) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
                attempts += 1
            }

            // Step 9: Start Reverb immediately if autoStart is enabled
            if autoStart {
                try await reverbProcess?.start(port: port)
            }

        } catch {
            operationError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Update

    func update() async throws {
        // GUARD: Check for active operation
        guard !isAnyOperationActive else {
            throw ReverbUpdateError.anotherOperationInProgress
        }

        // Set state
        isUpdating = true
        operationError = nil

        defer {
            isUpdating = false
        }

        do {
            // Step 1: Fetch metadata
            guard let metadata = availableMetadata else {
                throw ReverbUpdateError.noUpdateAvailable
            }

            // Step 2: Fetch existing version
            let descriptor = FetchDescriptor<ReverbVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "reverb" }
            )
            guard let existingVersion = try modelContext.fetch(descriptor).first else {
                throw ReverbUpdateError.notInstalled
            }

            // Step 3: Check if update needed
            guard existingVersion.version != metadata.latest else {
                throw ReverbUpdateError.noUpdateAvailable
            }

            // Step 4: Store running state before update
            let wasRunning = reverbProcess?.isRunning ?? false

            // Step 5: Stop Reverb if running
            if wasRunning {
                await reverbProcess?.stop()
            }

            // Step 6: Download
            let archiveURL = try await ReverbDownloadService.download(
                metadata: metadata,
                progressHandler: { _ in }
            )

            // Step 7: Delete old binaries
            let binaryPath = FadogenPaths.reverbBinaryPath
            if FileManager.default.fileExists(atPath: binaryPath.path) {
                try FileManager.default.removeItem(at: binaryPath)
            }

            // Step 8: Extract new binaries
            try await ReverbDownloadService.extractAndInstall(archiveURL: archiveURL)

            // Step 9: Update model (preserve port and autoStart)
            existingVersion.version = metadata.latest
            try modelContext.save()

            // Step 10: Restart Reverb if it was running
            if wasRunning {
                try await reverbProcess?.start(port: existingVersion.port)
            }

        } catch {
            operationError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Removal

    func remove() async throws {
        // GUARD: Check for active operation
        guard !isAnyOperationActive else {
            throw ReverbRemoveError.anotherOperationInProgress
        }

        // Set state
        isRemoving = true
        operationError = nil
        reverbProcess?.clearStartupError()

        defer {
            isRemoving = false
        }

        do {
            // Step 1: Fetch version from SwiftData
            let descriptor = FetchDescriptor<ReverbVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "reverb" }
            )
            guard let versionToRemove = try modelContext.fetch(descriptor).first else {
                throw ReverbRemoveError.notInstalled
            }

            // Step 2: Stop Reverb if running
            if reverbProcess?.isRunning == true {
                await reverbProcess?.stop()
            }

            // Step 3: Delete binaries
            let binaryPath = FadogenPaths.reverbBinaryPath
            if FileManager.default.fileExists(atPath: binaryPath.path) {
                try FileManager.default.removeItem(at: binaryPath)
            }

            // Step 4: Delete SwiftData model
            modelContext.delete(versionToRemove)
            try modelContext.save()

            // Step 5: Regenerate Caddy config (removes Reverb proxy)
            try caddyConfig?.generateMainCaddyfile()

            // Step 6: Reload Caddy to apply updated configuration
            caddyConfig?.reloadCaddy()

        } catch {
            operationError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Port Management

    func updatePort(newPort: Int) async throws {
        // Step 1: Fetch version from SwiftData
        let descriptor = FetchDescriptor<ReverbVersion>(
            predicate: #Predicate { $0.uniqueIdentifier == "reverb" }
        )
        guard let reverbVersion = try modelContext.fetch(descriptor).first else {
            throw ReverbPortUpdateError.notInstalled
        }

        // Step 2: Check if port actually changed
        guard reverbVersion.port != newPort else {
            return  // No change needed
        }

        let wasRunning = reverbProcess?.isRunning ?? false

        // Step 3: Stop Reverb if running
        if wasRunning {
            await reverbProcess?.stop()
        }

        // Step 4: Update port in SwiftData
        reverbVersion.port = newPort
        try modelContext.save()

        // Step 5: Regenerate Caddy config with new port
        try caddyConfig?.generateMainCaddyfile()

        // Step 6: Reload Caddy to apply new port
        caddyConfig?.reloadCaddy()

        // Step 7: Restart Reverb if it was running
        if wasRunning {
            try await reverbProcess?.start(port: newPort)
        }
    }

    func detectPortConflict(port: Int) throws -> String? {
        // Check services
        let servicesDescriptor = FetchDescriptor<ServiceVersion>()
        let allServices = try modelContext.fetch(servicesDescriptor)

        for service in allServices {
            if service.port == port {
                return "\(service.serviceType.displayName) \(service.major)"
            }
        }

        return nil
    }
}

// MARK: - Errors

enum ReverbManagerError: LocalizedError {
    case invalidResponse
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from metadata server"
        case .invalidMetadata:
            return "Invalid Reverb metadata structure"
        }
    }
}

enum ReverbInstallError: LocalizedError {
    case metadataNotAvailable
    case alreadyInstalled
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .metadataNotAvailable:
            return "Reverb metadata is not available. Please refresh and try again."
        case .alreadyInstalled:
            return "Reverb is already installed"
        case .anotherOperationInProgress:
            return "Another operation is in progress. Please wait."
        }
    }
}

enum ReverbRemoveError: LocalizedError {
    case notInstalled
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Reverb is not installed"
        case .anotherOperationInProgress:
            return "Another operation is in progress. Please wait."
        }
    }
}

enum ReverbUpdateError: LocalizedError {
    case notInstalled
    case noUpdateAvailable
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Reverb is not installed"
        case .noUpdateAvailable:
            return "Already using the latest version"
        case .anotherOperationInProgress:
            return "Another operation is in progress. Please wait."
        }
    }
}

enum ReverbPortUpdateError: LocalizedError {
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Reverb is not installed"
        }
    }
}
