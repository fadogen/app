import Foundation
import Subprocess
import System
import OSLog
import SwiftData

/// Handles first-time initialization of Garage cluster
/// - Configures layout (single node)
/// - Imports fixed API key
/// - Grants create-bucket permission
@Observable
final class GarageInitializer {

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "garage-init")
    private let modelContext: ModelContext

    private(set) var isInitializing = false
    private(set) var initializationError: String?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Initialize Garage cluster (run once after first install)
    /// - Parameter garageVersion: The GarageVersion model to update
    func initialize(garageVersion: GarageVersion) async throws {
        guard !garageVersion.isInitialized else {
            logger.info("Garage already initialized")
            return
        }

        guard !isInitializing else {
            throw GarageInitializerError.operationInProgress
        }

        isInitializing = true
        initializationError = nil
        defer { isInitializing = false }

        let garagePath = FadogenPaths.garageBinaryPath.appendingPathComponent("garage").path
        let configPath = FadogenPaths.garageConfigPath.path

        logger.info("Initializing Garage cluster...")

        do {
            // Step 1: Get node ID from status
            let nodeId = try await getNodeId(garagePath: garagePath, configPath: configPath)
            logger.info("Got node ID: \(nodeId)")

            // Step 2: Assign layout
            try await assignLayout(garagePath: garagePath, configPath: configPath, nodeId: nodeId)
            logger.info("Layout assigned")

            // Step 3: Apply layout
            try await applyLayout(garagePath: garagePath, configPath: configPath)
            logger.info("Layout applied")

            // Step 4: Import fixed API key
            try await importApiKey(garagePath: garagePath, configPath: configPath)
            logger.info("API key imported")

            // Step 5: Allow create-bucket permission
            try await allowCreateBucket(garagePath: garagePath, configPath: configPath)
            logger.info("Create-bucket permission granted")

            // Mark as initialized
            garageVersion.isInitialized = true
            try modelContext.save()

            logger.info("Garage initialization complete")

        } catch {
            initializationError = error.localizedDescription
            logger.error("Garage initialization failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Private CLI Commands

    private func getNodeId(garagePath: String, configPath: String) async throws -> String {
        let result = try await run(
            .path(FilePath(garagePath)),
            arguments: ["-c", configPath, "status"],
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        guard result.terminationStatus.isSuccess,
              let output = result.standardOutput else {
            let errorOutput = result.standardError ?? "Unknown error"
            throw GarageInitializerError.commandFailed("status", errorOutput)
        }

        // Parse node ID from output
        // Format: "ID                Hostname       Address..."
        // Example line: "e947645311b18f97  dev.fritz.box  127.0.0.1:3901"
        let lines = output.split(separator: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip header and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("ID") || trimmed.hasPrefix("====") {
                continue
            }
            // First column is the node ID (16 hex chars)
            let columns = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if let firstColumn = columns.first {
                let nodeId = String(firstColumn)
                // Validate it looks like a node ID (16 hex chars)
                if nodeId.count == 16 && nodeId.allSatisfy({ $0.isHexDigit }) {
                    return nodeId
                }
            }
        }

        throw GarageInitializerError.nodeIdNotFound
    }

    private func assignLayout(garagePath: String, configPath: String, nodeId: String) async throws {
        let result = try await run(
            .path(FilePath(garagePath)),
            arguments: ["-c", configPath, "layout", "assign", "-z", "dc1", "-c", "1G", nodeId],
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        guard result.terminationStatus.isSuccess else {
            let errorOutput = result.standardError ?? result.standardOutput ?? "Unknown error"
            throw GarageInitializerError.commandFailed("layout assign", errorOutput)
        }
    }

    private func applyLayout(garagePath: String, configPath: String) async throws {
        // First, get the staged layout version from "garage layout show"
        let showResult = try await run(
            .path(FilePath(garagePath)),
            arguments: ["-c", configPath, "layout", "show"],
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        guard showResult.terminationStatus.isSuccess,
              let showOutput = showResult.standardOutput else {
            let errorOutput = showResult.standardError ?? "Unknown error"
            throw GarageInitializerError.commandFailed("layout show", errorOutput)
        }

        // Parse staged version from output
        // Look for: "apply --version N" or "Staged layout version: N"
        var stagedVersion: Int?

        // Pattern 1: "garage layout apply --version N"
        if let range = showOutput.range(of: "--version ") {
            let afterVersion = showOutput[range.upperBound...]
            let versionStr = afterVersion.prefix(while: { $0.isNumber })
            stagedVersion = Int(versionStr)
        }

        guard let version = stagedVersion else {
            throw GarageInitializerError.commandFailed("layout show", "Could not parse staged layout version from output: \(showOutput)")
        }

        // Apply the staged layout with the correct version
        let result = try await run(
            .path(FilePath(garagePath)),
            arguments: ["-c", configPath, "layout", "apply", "--version", String(version)],
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        guard result.terminationStatus.isSuccess else {
            let errorOutput = result.standardError ?? result.standardOutput ?? "Unknown error"
            throw GarageInitializerError.commandFailed("layout apply", errorOutput)
        }
    }

    private func importApiKey(garagePath: String, configPath: String) async throws {
        let result = try await run(
            .path(FilePath(garagePath)),
            arguments: [
                "-c", configPath,
                "key", "import",
                "--yes",
                "-n", "fadogen-garage-key",
                garageAccessKeyId,
                garageSecretAccessKey
            ],
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        guard result.terminationStatus.isSuccess else {
            let errorOutput = result.standardError ?? result.standardOutput ?? "Unknown error"
            throw GarageInitializerError.commandFailed("key import", errorOutput)
        }
    }

    private func allowCreateBucket(garagePath: String, configPath: String) async throws {
        let result = try await run(
            .path(FilePath(garagePath)),
            arguments: ["-c", configPath, "key", "allow", "--create-bucket", "fadogen-garage-key"],
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        guard result.terminationStatus.isSuccess else {
            let errorOutput = result.standardError ?? result.standardOutput ?? "Unknown error"
            throw GarageInitializerError.commandFailed("key allow", errorOutput)
        }
    }
}

// MARK: - Errors

enum GarageInitializerError: LocalizedError {
    case operationInProgress
    case nodeIdNotFound
    case commandFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Initialization already in progress"
        case .nodeIdNotFound:
            return "Could not find Garage node ID in status output"
        case .commandFailed(let command, let error):
            return "Garage \(command) failed: \(error)"
        }
    }
}
