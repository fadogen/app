import Foundation
import SwiftData

@Observable
final class TypesenseManager {

    var availableMetadata: TypesenseMetadata?
    var isLoading = false
    var errorMessage: String?

    var isInstalling = false
    var isRemoving = false
    var isUpdating = false
    var operationError: String?

    private let metadataURL = URL(string: "https://binaries.fadogen.app/metadata-typesense.json")!
    private let modelContext: ModelContext
    private weak var typesenseProcess: TypesenseProcessManager?
    private weak var caddyConfig: CaddyConfigService?

    init(modelContext: ModelContext, typesenseProcess: TypesenseProcessManager? = nil, caddyConfig: CaddyConfigService? = nil) {
        self.modelContext = modelContext
        self.typesenseProcess = typesenseProcess
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
                throw TypesenseManagerError.invalidResponse
            }

            let decoder = JSONDecoder()
            let metadata = try decoder.decode(TypesenseMetadata.self, from: data)

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

    func install(port: Int = 8108, autoStart: Bool = false) async throws {
        // GUARD: Check for active operation
        guard !isAnyOperationActive else {
            throw TypesenseInstallError.anotherOperationInProgress
        }

        // Set state BEFORE async work
        isInstalling = true
        operationError = nil
        typesenseProcess?.clearStartupError()

        // Cleanup in ALL cases (success or error)
        defer {
            isInstalling = false
        }

        do {
            // Step 1: Validate metadata exists
            guard let metadata = availableMetadata else {
                throw TypesenseInstallError.metadataNotAvailable
            }

            // Step 2: Check not already installed
            let descriptor = FetchDescriptor<TypesenseVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "typesense" }
            )
            if try modelContext.fetch(descriptor).first != nil {
                throw TypesenseInstallError.alreadyInstalled
            }

            // Step 3: Check if binaries already exist (multi-user optimization)
            let binariesExist = BinaryValidationService.validateTypesenseBinaries()

            if !binariesExist {
                // Step 3b: Preventive deletion of binary directory (if partial/corrupted)
                let binaryPath = FadogenPaths.typesenseBinaryPath
                if FileManager.default.fileExists(atPath: binaryPath.path) {
                    try FileManager.default.removeItem(at: binaryPath)
                }

                // Step 4: Download
                let archiveURL = try await TypesenseDownloadService.download(
                    metadata: metadata,
                    progressHandler: { _ in }
                )

                // Step 5: Extract and install
                try await TypesenseDownloadService.extractAndInstall(archiveURL: archiveURL)
            }

            // Step 6: Create data directory
            let dataPath = FadogenPaths.typesenseDataDirectory
            try FileManager.default.createDirectory(at: dataPath, withIntermediateDirectories: true)

            // Step 7: Create SwiftData model
            let typesenseVersion = TypesenseVersion(
                version: metadata.latest,
                port: port,
                autoStart: autoStart
            )
            modelContext.insert(typesenseVersion)
            try modelContext.save()

            // Step 8: Regenerate Caddy config (adds Typesense proxy)
            try caddyConfig?.generateMainCaddyfile()

            // Step 9: Reload Caddy to apply new configuration and generate certificate
            caddyConfig?.reloadCaddy()

            // Step 9b: Wait for Caddy to generate typesense.localhost certificate
            let certPath = FadogenPaths.caddyDataDirectory
                .appendingPathComponent("pki/authorities/local/typesense.localhost.crt")

            var attempts = 0
            let maxAttempts = 100  // 10 seconds
            while attempts < maxAttempts {
                if FileManager.default.fileExists(atPath: certPath.path) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
                attempts += 1
            }

            // Step 10: Start Typesense immediately if autoStart is enabled
            if autoStart {
                try await typesenseProcess?.start(port: port)
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
            throw TypesenseUpdateError.anotherOperationInProgress
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
                throw TypesenseUpdateError.noUpdateAvailable
            }

            // Step 2: Fetch existing version
            let descriptor = FetchDescriptor<TypesenseVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "typesense" }
            )
            guard let existingVersion = try modelContext.fetch(descriptor).first else {
                throw TypesenseUpdateError.notInstalled
            }

            // Step 3: Check if update needed
            guard existingVersion.version != metadata.latest else {
                throw TypesenseUpdateError.noUpdateAvailable
            }

            // Step 4: Store running state before update
            let wasRunning = typesenseProcess?.isRunning ?? false

            // Step 5: Stop Typesense if running
            if wasRunning {
                await typesenseProcess?.stop()
            }

            // Step 6: Download
            let archiveURL = try await TypesenseDownloadService.download(
                metadata: metadata,
                progressHandler: { _ in }
            )

            // Step 7: Delete old binaries
            let binaryPath = FadogenPaths.typesenseBinaryPath
            if FileManager.default.fileExists(atPath: binaryPath.path) {
                try FileManager.default.removeItem(at: binaryPath)
            }

            // Step 8: Extract new binaries
            try await TypesenseDownloadService.extractAndInstall(archiveURL: archiveURL)

            // Step 9: Update model (preserve port and autoStart)
            existingVersion.version = metadata.latest
            try modelContext.save()

            // Step 10: Restart Typesense if it was running
            if wasRunning {
                try await typesenseProcess?.start(port: existingVersion.port)
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
            throw TypesenseRemoveError.anotherOperationInProgress
        }

        // Set state
        isRemoving = true
        operationError = nil
        typesenseProcess?.clearStartupError()

        defer {
            isRemoving = false
        }

        do {
            // Step 1: Fetch version from SwiftData
            let descriptor = FetchDescriptor<TypesenseVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "typesense" }
            )
            guard let versionToRemove = try modelContext.fetch(descriptor).first else {
                throw TypesenseRemoveError.notInstalled
            }

            // Step 2: Stop Typesense if running
            if typesenseProcess?.isRunning == true {
                await typesenseProcess?.stop()
            }

            // Step 3: Delete binaries
            let binaryPath = FadogenPaths.typesenseBinaryPath
            if FileManager.default.fileExists(atPath: binaryPath.path) {
                try FileManager.default.removeItem(at: binaryPath)
            }

            // Step 4: Delete data directory
            let dataPath = FadogenPaths.typesenseDataDirectory
            if FileManager.default.fileExists(atPath: dataPath.path) {
                try FileManager.default.removeItem(at: dataPath)
            }

            // Step 5: Delete SwiftData model
            modelContext.delete(versionToRemove)
            try modelContext.save()

            // Step 6: Regenerate Caddy config (removes Typesense proxy)
            try caddyConfig?.generateMainCaddyfile()

            // Step 7: Reload Caddy to apply updated configuration
            caddyConfig?.reloadCaddy()

        } catch {
            operationError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Port Management

    func updatePort(newPort: Int) async throws {
        // Step 1: Fetch version from SwiftData
        let descriptor = FetchDescriptor<TypesenseVersion>(
            predicate: #Predicate { $0.uniqueIdentifier == "typesense" }
        )
        guard let typesenseVersion = try modelContext.fetch(descriptor).first else {
            throw TypesensePortUpdateError.notInstalled
        }

        // Step 2: Check if port actually changed
        guard typesenseVersion.port != newPort else {
            return  // No change needed
        }

        let wasRunning = typesenseProcess?.isRunning ?? false

        // Step 3: Stop Typesense if running
        if wasRunning {
            await typesenseProcess?.stop()
        }

        // Step 4: Update port in SwiftData
        typesenseVersion.port = newPort
        try modelContext.save()

        // Step 5: Regenerate Caddy config with new port
        try caddyConfig?.generateMainCaddyfile()

        // Step 6: Reload Caddy to apply new port
        caddyConfig?.reloadCaddy()

        // Step 7: Restart Typesense if it was running
        if wasRunning {
            try await typesenseProcess?.start(port: newPort)
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

        // Check Reverb
        let reverbDescriptor = FetchDescriptor<ReverbVersion>()
        if let reverb = try modelContext.fetch(reverbDescriptor).first {
            if reverb.port == port {
                return "Reverb"
            }
        }

        return nil
    }
}

// MARK: - Errors

enum TypesenseManagerError: LocalizedError {
    case invalidResponse
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from metadata server"
        case .invalidMetadata:
            return "Invalid Typesense metadata structure"
        }
    }
}

enum TypesenseInstallError: LocalizedError {
    case metadataNotAvailable
    case alreadyInstalled
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .metadataNotAvailable:
            return "Typesense metadata is not available. Please refresh and try again."
        case .alreadyInstalled:
            return "Typesense is already installed"
        case .anotherOperationInProgress:
            return "Another operation is in progress. Please wait."
        }
    }
}

enum TypesenseRemoveError: LocalizedError {
    case notInstalled
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Typesense is not installed"
        case .anotherOperationInProgress:
            return "Another operation is in progress. Please wait."
        }
    }
}

enum TypesenseUpdateError: LocalizedError {
    case notInstalled
    case noUpdateAvailable
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Typesense is not installed"
        case .noUpdateAvailable:
            return "Already using the latest version"
        case .anotherOperationInProgress:
            return "Another operation is in progress. Please wait."
        }
    }
}

enum TypesensePortUpdateError: LocalizedError {
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Typesense is not installed"
        }
    }
}
