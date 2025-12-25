import Foundation
import Subprocess
import System
import OSLog
import SwiftData

@Observable
final class GarageProcessManager {

    // MARK: - State

    private(set) var runningProcess: Task<Void, Never>?
    private(set) var processIdentifier: ProcessIdentifier?
    private(set) var isStarting = false
    private(set) var isStopping = false
    private(set) var startupError: String?

    var isRunning: Bool {
        guard let pid = processIdentifier else { return false }
        // Use kill(pid, 0) to check if process exists (signal 0 doesn't kill)
        let exists = kill(pid_t(pid.value), 0) == 0
        // Auto-cleanup PID if process is dead
        if !exists {
            processIdentifier = nil
        }
        return exists
    }

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "garage-process")
    private let modelContext: ModelContext
    weak var processCleanup: ProcessCleanupService?
    weak var garageInitializer: GarageInitializer?

    // MARK: - Initialization

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Start

    func start(s3Port: Int) async throws {
        // Check if already running
        guard runningProcess == nil else {
            logger.info("Garage already running")
            return
        }

        // Check if operation in progress
        guard !isStarting else {
            throw GarageProcessError.operationInProgress
        }

        isStarting = true
        defer { isStarting = false }

        logger.info("Starting Garage on S3 port \(s3Port)")

        // Clear previous error
        startupError = nil

        // Check port availability before starting
        let portCheck = await checkPortAvailability(port: s3Port)
        if case .inUse(let process) = portCheck {
            let errorMsg = "S3 port \(s3Port) already in use by \(process)"
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw GarageProcessError.portInUse(s3Port, process)
        }

        let binaryPath = FadogenPaths.garageBinaryPath
        let configPath = FadogenPaths.garageConfigPath

        // Verify Garage binary exists
        let executablePath = binaryPath.appendingPathComponent("garage")
        guard FileManager.default.isExecutableFile(atPath: executablePath.path) else {
            let errorMsg = "Garage binary not found: \(executablePath.path)"
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw GarageProcessError.garageNotFound
        }

        // Ensure config file exists (generate if needed)
        if !FileManager.default.fileExists(atPath: configPath.path) {
            try generateConfigFile(s3Port: s3Port)
        }

        // Ensure data directories exist
        let dataPath = FadogenPaths.garageDataDirectory
        try FileManager.default.createDirectory(
            at: dataPath.appendingPathComponent("meta"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dataPath.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )

        // Build command: garage -c {config} server
        let arguments = ["-c", configPath.path, "server"]

        logger.info("Garage command: \(executablePath.path) \(arguments.joined(separator: " "))")

        // Launch subprocess in background task
        let task = Task {
            // Capture first few error lines for startup error detection
            var startupErrorLines: [String] = []

            do {
                let result = try await run(
                    .path(FilePath(executablePath.path)),
                    arguments: .init(arguments),
                    environment: .inherit,
                    preferredBufferSize: 1
                ) { execution, standardOutput, _, standardError in
                    // Store PID immediately
                    self.processIdentifier = execution.processIdentifier

                    // Write PID file for orphan cleanup
                    let pid = Int32(execution.processIdentifier.value)
                    self.processCleanup?.writePIDFile(identifier: "garage", pid: pid)

                    // Capture first 5 lines of stderr for error detection
                    var lineCount = 0
                    for try await line in standardError.lines() {
                        if lineCount < 5 {
                            startupErrorLines.append(line)
                            lineCount += 1
                        }
                    }
                }

                // Process terminated
                if !result.terminationStatus.isSuccess && !Task.isCancelled {
                    let errorMsg = if !startupErrorLines.isEmpty {
                        startupErrorLines.joined(separator: "\n")
                    } else {
                        "Garage exited with status: \(result.terminationStatus)"
                    }
                    self.logger.error("Garage failed: \(errorMsg)")
                    self.startupError = errorMsg
                }
            } catch {
                if !Task.isCancelled {
                    let errorMsg = if !startupErrorLines.isEmpty {
                        startupErrorLines.joined(separator: "\n")
                    } else {
                        error.localizedDescription
                    }
                    self.logger.error("Garage error: \(errorMsg)")
                    self.startupError = errorMsg
                }
            }

            runningProcess = nil
        }

        // Store task
        runningProcess = task

        // Wait for RPC port to be listening (port + 1)
        let rpcPort = s3Port + 1
        var attempts = 0
        let maxAttempts = 25  // Max 5 seconds (25 x 200ms)
        var portIsListening = false

        while attempts < maxAttempts && !portIsListening {
            try await Task.sleep(for: .milliseconds(200))
            attempts += 1

            let portCheck = await checkPortAvailability(port: rpcPort)
            if case .inUse = portCheck {
                portIsListening = true
                break
            }
        }

        if !portIsListening {
            if let error = startupError {
                throw GarageProcessError.startupFailed(error)
            } else {
                throw GarageProcessError.failedToStart
            }
        }

        logger.info("Garage started successfully on S3 port \(s3Port)")
    }

    // MARK: - Stop

    func stop() async {
        guard let task = runningProcess else {
            logger.info("Garage not running")
            return
        }

        guard !isStopping else {
            logger.warning("Stop operation already in progress")
            return
        }

        isStopping = true
        defer { isStopping = false }

        logger.info("Stopping Garage")

        task.cancel()
        runningProcess = nil
        processIdentifier = nil

        processCleanup?.removePIDFile(identifier: "garage")

        logger.info("Garage stopped")
    }

    // MARK: - Restart

    func restart(s3Port: Int) async throws {
        if isRunning {
            await stop()
        }

        try await Task.sleep(for: .seconds(1))
        try await start(s3Port: s3Port)
    }

    func restartIfRunning() async throws {
        guard isRunning else {
            logger.debug("Garage not running, skipping restart")
            return
        }

        let descriptor = FetchDescriptor<GarageVersion>()
        guard let garageVersion = try? modelContext.fetch(descriptor).first else {
            logger.warning("Cannot restart Garage: version model not found")
            return
        }

        logger.info("Restarting Garage with S3 port \(garageVersion.s3Port)")
        try await restart(s3Port: garageVersion.s3Port)
    }

    // MARK: - Auto-Start

    func startAutoStartService() async {
        logger.info("Checking Garage auto-start...")

        do {
            let descriptor = FetchDescriptor<GarageVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "garage" }
            )
            guard let garageVersion = try modelContext.fetch(descriptor).first else {
                logger.info("Garage not installed")
                return
            }

            if garageVersion.autoStart {
                logger.info("Auto-starting Garage on S3 port \(garageVersion.s3Port)")
                try await start(s3Port: garageVersion.s3Port)

                // Initialize if not done yet
                if !garageVersion.isInitialized {
                    try await garageInitializer?.initialize(garageVersion: garageVersion)
                }
            } else {
                logger.info("Garage auto-start disabled")
            }
        } catch {
            logger.error("Failed to auto-start Garage: \(error.localizedDescription)")
        }
    }

    // MARK: - Error

    func clearStartupError() {
        startupError = nil
    }

    // MARK: - Config Generation

    private func generateConfigFile(s3Port: Int) throws {
        let configDir = FadogenPaths.garageConfigDirectory
        let configPath = FadogenPaths.garageConfigPath
        let dataPath = FadogenPaths.garageDataDirectory

        // Generate RPC secret (32 bytes hex = 64 chars)
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard result == errSecSuccess else {
            throw GarageProcessError.configGenerationFailed("Failed to generate RPC secret")
        }
        let rpcSecret = randomBytes.map { String(format: "%02x", $0) }.joined()

        let rpcPort = s3Port + 1
        let adminPort = s3Port + 3

        let config = """
        metadata_dir = "\(dataPath.path)/meta"
        data_dir = "\(dataPath.path)/data"
        db_engine = "sqlite"
        replication_factor = 1

        rpc_secret = "\(rpcSecret)"
        rpc_bind_addr = "127.0.0.1:\(rpcPort)"
        rpc_public_addr = "127.0.0.1:\(rpcPort)"

        [s3_api]
        s3_region = "garage"
        api_bind_addr = "127.0.0.1:\(s3Port)"
        root_domain = ".s3.localhost"

        [admin]
        api_bind_addr = "127.0.0.1:\(adminPort)"
        """

        // Create config directory
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Write config file
        try config.write(to: configPath, atomically: true, encoding: .utf8)

        logger.info("Generated Garage config at \(configPath.path)")
    }

    // MARK: - Private

    private func checkPortAvailability(port: Int) async -> PortStatus {
        do {
            let result = try await run(
                .path(FilePath("/usr/sbin/lsof")),
                arguments: ["-i", ":\(port)", "-sTCP:LISTEN", "-t", "-n", "-P"],
                output: .string(limit: .max)
            )

            if result.terminationStatus.isSuccess,
               let output = result.standardOutput,
               !output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                return .inUse("process using port \(port)")
            }

            return .available
        } catch {
            return .available
        }
    }
}

// MARK: - Port Status

private enum PortStatus {
    case available
    case inUse(String)
}

// MARK: - Errors

enum GarageProcessError: LocalizedError {
    case operationInProgress
    case portInUse(Int, String)
    case garageNotFound
    case failedToStart
    case startupFailed(String)
    case configGenerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another operation is in progress. Please wait."
        case .portInUse(let port, let process):
            return "Port \(port) is already in use by \(process)"
        case .garageNotFound:
            return "Garage binary not found"
        case .failedToStart:
            return "Garage failed to start. Please check the installation."
        case .startupFailed(let details):
            return details
        case .configGenerationFailed(let reason):
            return "Failed to generate Garage config: \(reason)"
        }
    }
}
