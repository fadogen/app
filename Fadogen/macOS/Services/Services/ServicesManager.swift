import Foundation
import SwiftData

@Observable
final class ServicesManager {

    var availableServices: ServiceMetadataCollection = [:]
    var isLoading = false
    var errorMessage: String?

    /// Key format: "mariadb-10"
    var installingServices: Set<String> = []
    var removingServices: Set<String> = []
    var updatingServices: Set<String> = []
    var operationErrors: [String: String] = [:]
    var operationProgress: [String: Double] = [:]

    private let metadataURL = GenericDownloadService.metadataURL(for: "services")
    private let modelContext: ModelContext
    private weak var serviceProcesses: ServiceProcessManager?

    init(modelContext: ModelContext, serviceProcesses: ServiceProcessManager? = nil) {
        self.modelContext = modelContext
        self.serviceProcesses = serviceProcesses
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

            // Create request with cache-busting headers to bypass Cloudflare cache
            var request = URLRequest(url: self.metadataURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ServicesManagerError.invalidResponse
            }

            let decoder = JSONDecoder()
            availableServices = try decoder.decode(ServiceMetadataCollection.self, from: data)

        } catch {
            errorMessage = "Unable to check for updates"
        }

        isLoading = false
    }

    // MARK: - Operation State

    func isOperationActive(service: ServiceType, major: String) -> Bool {
        let id = identifier(service: service, major: major)
        return installingServices.contains(id) ||
               removingServices.contains(id) ||
               updatingServices.contains(id)
    }

    private func identifier(service: ServiceType, major: String) -> String {
        "\(service.rawValue)-\(major)"
    }

    // MARK: - Updates

    func hasUpdate(service: ServiceType, major: String, currentMinor: String?) -> Bool {
        guard let currentMinor else { return false }
        let allMetadata = availableServices[service.rawValue]

        if service.isSingleInstallation {
            guard let highestMajor = allMetadata?.keys.sorted(by: >).first,
                  let highestMetadata = allMetadata?[highestMajor] else { return false }
            return major != highestMajor || currentMinor != highestMetadata.latest
        } else {
            guard let metadata = allMetadata?[major] else { return false }
            return currentMinor != metadata.latest
        }
    }

    func latestAvailable(service: ServiceType, major: String) -> String? {
        let allMetadata = availableServices[service.rawValue]

        if service.isSingleInstallation {
            guard let highestMajor = allMetadata?.keys.sorted(by: >).first,
                  let highestMetadata = allMetadata?[highestMajor] else { return nil }
            return highestMetadata.latest
        } else {
            return allMetadata?[major]?.latest
        }
    }

    // MARK: - Installation

    func install(
        service: ServiceType,
        major: String,
        port: Int,
        autoStart: Bool = false
    ) async throws {
        let id = identifier(service: service, major: major)

        // GUARD: Check for active operation on this specific service+version
        guard !isOperationActive(service: service, major: major) else {
            throw ServicesInstallError.anotherOperationInProgress
        }

        // Set state BEFORE async work
        installingServices.insert(id)
        operationErrors[id] = nil
        serviceProcesses?.clearStartupError(service: service, major: major)

        // Cleanup in ALL cases (success or error)
        defer {
            installingServices.remove(id)
        }

        do {
            // Step 1: Validate metadata exists
            guard let metadata = availableServices[service.rawValue]?[major] else {
                throw ServicesInstallError.versionNotAvailable(service, major)
            }

            // Step 2: Check not already installed
            let descriptor = FetchDescriptor<ServiceVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == id }
            )
            if try modelContext.fetch(descriptor).first != nil {
                throw ServicesInstallError.alreadyInstalled(service, major)
            }

            // Step 2b: For single-installation services, check if ANY version exists
            if service.isSingleInstallation {
                // Fetch all and filter in memory - SwiftData has issues with enum predicates
                let allVersionsDescriptor = FetchDescriptor<ServiceVersion>()
                let allVersions = try modelContext.fetch(allVersionsDescriptor)
                if allVersions.first(where: { $0.serviceType == service }) != nil {
                    throw ServicesInstallError.anotherVersionAlreadyInstalled(service)
                }
            }

            // Step 3: Check if binaries already exist (multi-user optimization)
            let binariesExist = BinaryValidationService.validateServiceBinaries(service: service, major: major)

            if !binariesExist {
                // Step 3b: Preventive deletion of binary directory (if partial/corrupted)
                let binaryPath = FadogenPaths.binaryPath(for: service, major: major)
                if FileManager.default.fileExists(atPath: binaryPath.path) {
                    try FileManager.default.removeItem(at: binaryPath)
                }

                // Step 4: Download
                let archiveURL = try await ServicesDownloadService.download(
                    service: service,
                    major: major,
                    metadata: metadata,
                    progressHandler: { _ in }
                )

                // Step 5: Extract and install
                try await ServicesDownloadService.extractAndInstall(
                    archiveURL: archiveURL,
                    service: service,
                    major: major
                )
            }

            // Step 6a: Create data directory
            try ServicesFileSystemService.createDataDirectory(service: service, major: major)

            // Step 6b: Initialize data directory
            try await ServicesFileSystemService.initializeDataDirectory(service: service, major: major)

            // Step 7: Create log directory
            try ServicesFileSystemService.createLogDirectory(service: service, major: major)

            // Step 8: Create SwiftData model
            let serviceVersion = ServiceVersion(
                serviceType: service,
                major: major,
                minor: metadata.latest,
                port: port,
                autoStart: autoStart
            )
            modelContext.insert(serviceVersion)
            try modelContext.save()

            // Step 9: Start service immediately if autoStart is enabled
            if autoStart {
                try await serviceProcesses?.start(service: service, major: major, port: port)
            }

        } catch {
            operationErrors[id] = error.localizedDescription
            throw error
        }
    }

    // MARK: - Update

    func update(
        service: ServiceType,
        major: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let id = identifier(service: service, major: major)

        // GUARD: Check for active operation
        guard !isOperationActive(service: service, major: major) else {
            throw ServicesUpdateError.anotherOperationInProgress
        }

        // Set state BEFORE async work
        updatingServices.insert(id)
        operationProgress[id] = 0.0
        operationErrors[id] = nil

        // Cleanup in ALL cases (success or error)
        defer {
            updatingServices.remove(id)
            operationProgress[id] = nil
        }

        // Wrap progress to update centralized state
        let wrappedProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.operationProgress[id] = p
            }
            progress(p)
        }

        do {
            wrappedProgress(0.05)

            // Step 1: Fetch existing version
            let descriptor = FetchDescriptor<ServiceVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == id }
            )
            guard let existingVersion = try modelContext.fetch(descriptor).first else {
                throw ServicesUpdateError.versionNotInstalled
            }

            wrappedProgress(0.10)

            // Step 2: Determine target version
            // For single-installation services: find highest available major
            // For standard services: update within same major
            let targetMajor: String
            let targetMetadata: ServiceMetadata

            if service.isSingleInstallation {
                guard let allMajors = availableServices[service.rawValue],
                      let highestMajor = allMajors.keys.sorted(by: >).first,
                      let metadata = allMajors[highestMajor] else {
                    throw ServicesUpdateError.noUpdateAvailable
                }
                targetMajor = highestMajor
                targetMetadata = metadata
            } else {
                guard let metadata = availableServices[service.rawValue]?[major] else {
                    throw ServicesUpdateError.noUpdateAvailable
                }
                targetMajor = major
                targetMetadata = metadata
            }

            wrappedProgress(0.15)

            // Step 3: Check if update needed
            let isMajorUpgrade = targetMajor != major
            let isMinorUpdate = existingVersion.minor != targetMetadata.latest

            guard isMajorUpgrade || isMinorUpdate else {
                throw ServicesUpdateError.noUpdateAvailable
            }

            wrappedProgress(0.20)

            // Step 4: Check if service is running, store state for restart
            let wasRunning = serviceProcesses?.isRunning(service: service, major: major) ?? false
            let port = existingVersion.port

            wrappedProgress(0.25)

            // Step 5: Stop service if running (wait for completion)
            if wasRunning {
                try await serviceProcesses?.stop(service: service, major: major)
            }

            wrappedProgress(0.30)

            // Step 6: Download with progress (30% → 60%)
            let archiveURL = try await ServicesDownloadService.download(
                service: service,
                major: targetMajor,
                metadata: targetMetadata,
                progressHandler: { downloadProgress in
                    let mappedProgress = 0.30 + (downloadProgress * 0.30)
                    wrappedProgress(mappedProgress)
                }
            )

            wrappedProgress(0.65)

            // Step 7: Delete old binaries
            try ServicesFileSystemService.deleteBinaries(service: service, major: major)

            wrappedProgress(0.70)

            // Step 8: Extract new binaries (70% → 85%)
            try await ServicesDownloadService.extractAndInstall(
                archiveURL: archiveURL,
                service: service,
                major: targetMajor
            )

            wrappedProgress(0.90)

            // Step 9: Update model (preserve port and autoStart)
            // For major upgrades: also update major and uniqueIdentifier
            if isMajorUpgrade {
                existingVersion.major = targetMajor
                existingVersion.uniqueIdentifier = "\(service.rawValue)-\(targetMajor)"
            }
            existingVersion.minor = targetMetadata.latest
            try modelContext.save()

            wrappedProgress(0.95)

            // Step 10: Restart service if was running (with target major)
            if wasRunning {
                try await serviceProcesses?.start(service: service, major: targetMajor, port: port)
            }

            wrappedProgress(1.0)

        } catch {
            operationErrors[id] = error.localizedDescription
            throw error
        }
    }

    // MARK: - Removal

    func remove(service: ServiceType, major: String) async throws {
        let id = identifier(service: service, major: major)

        // GUARD: Check for active operation
        guard !isOperationActive(service: service, major: major) else {
            throw ServicesRemoveError.anotherOperationInProgress
        }

        // Set state
        removingServices.insert(id)
        operationErrors[id] = nil
        serviceProcesses?.clearStartupError(service: service, major: major)

        defer {
            removingServices.remove(id)
        }

        do {
            // Step 1: Fetch version from SwiftData
            let descriptor = FetchDescriptor<ServiceVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == id }
            )
            guard let versionToRemove = try modelContext.fetch(descriptor).first else {
                throw ServicesRemoveError.versionNotInstalled(service, major)
            }

            // Step 2: Delete binaries
            try ServicesFileSystemService.deleteBinaries(service: service, major: major)

            // Step 3: Delete data directory
            try ServicesFileSystemService.deleteDataDirectory(service: service, major: major)

            // Step 4: Delete SwiftData model
            modelContext.delete(versionToRemove)
            try modelContext.save()

        } catch {
            operationErrors[id] = error.localizedDescription
            throw error
        }
    }

    // MARK: - Port Management

    func detectPortConflict(port: Int, excludingID: String? = nil) throws -> String? {
        let descriptor = FetchDescriptor<ServiceVersion>()
        let allServices = try modelContext.fetch(descriptor)

        for service in allServices {
            // Skip the service being edited
            if let excludingID, service.uniqueIdentifier == excludingID {
                continue
            }

            if service.port == port {
                return "\(service.serviceType.displayName) \(service.major)"
            }
        }

        return nil
    }

    func suggestPort(for service: ServiceType) throws -> Int {
        let defaultPort = service.defaultPort

        // Check if default port is available
        if try detectPortConflict(port: defaultPort) == nil {
            return defaultPort
        }

        // Find next available port
        var candidatePort = defaultPort + 1
        while candidatePort < 65535 {
            if try detectPortConflict(port: candidatePort) == nil {
                return candidatePort
            }
            candidatePort += 1
        }

        // Fallback (should never happen)
        return defaultPort
    }
}

// MARK: - Errors

enum ServicesManagerError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from metadata server"
        }
    }
}

enum ServicesInstallError: LocalizedError {
    case versionNotAvailable(ServiceType, String)
    case alreadyInstalled(ServiceType, String)
    case anotherVersionAlreadyInstalled(ServiceType)
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .versionNotAvailable(let service, let version):
            return "\(service.displayName) \(version) is not available for installation"
        case .alreadyInstalled(let service, let version):
            return "\(service.displayName) \(version) is already installed"
        case .anotherVersionAlreadyInstalled(let service):
            return "\(service.displayName) is already installed. Use Update to upgrade to a newer version."
        case .anotherOperationInProgress:
            return "Another operation is in progress for this service. Please wait."
        }
    }
}

enum ServicesRemoveError: LocalizedError {
    case versionNotInstalled(ServiceType, String)
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .versionNotInstalled(let service, let version):
            return "\(service.displayName) \(version) is not installed"
        case .anotherOperationInProgress:
            return "Another operation is in progress for this service. Please wait."
        }
    }
}

enum ServicesUpdateError: LocalizedError {
    case versionNotInstalled
    case noUpdateAvailable
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .versionNotInstalled:
            return "Service version is not installed"
        case .noUpdateAvailable:
            return "Already using the latest version"
        case .anotherOperationInProgress:
            return "Another operation is in progress for this service. Please wait."
        }
    }
}
