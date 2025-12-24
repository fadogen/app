import Foundation
import Subprocess
import System
import OSLog
import SwiftData

/// Fixed API key for Typesense - same across all Fadogen installations for easy migration
let typesenseAPIKey = "fadogen-typesense-key"

@Observable
final class TypesenseProcessManager {

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

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "typesense-process")
    private let modelContext: ModelContext
    weak var processCleanup: ProcessCleanupService?

    // MARK: - Initialization

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Start

    func start(port: Int) async throws {
        // Check if already running
        guard runningProcess == nil else {
            logger.info("Typesense already running")
            return
        }

        // Check if operation in progress
        guard !isStarting else {
            throw TypesenseProcessError.operationInProgress
        }

        isStarting = true
        defer { isStarting = false }

        logger.info("Starting Typesense on port \(port)")

        // Clear previous error
        startupError = nil

        // Check port availability before starting
        let portCheck = await checkPortAvailability(port: port)
        if case .inUse(let process) = portCheck {
            let errorMsg = "Port \(port) already in use by \(process)"
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw TypesenseProcessError.portInUse(port, process)
        }

        let binaryPath = FadogenPaths.typesenseBinaryPath
        let dataPath = FadogenPaths.typesenseDataDirectory

        // Verify Typesense binary exists
        let executablePath = binaryPath.appendingPathComponent("typesense-server")
        guard FileManager.default.isExecutableFile(atPath: executablePath.path) else {
            let errorMsg = "Typesense binary not found: \(executablePath.path)"
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw TypesenseProcessError.typesenseNotFound
        }

        // Ensure data directory exists
        try FileManager.default.createDirectory(at: dataPath, withIntermediateDirectories: true)

        // Build command: typesense-server --data-dir={dataPath} --api-key={key} --listen-port={port} --enable-cors
        let arguments = [
            "--data-dir=\(dataPath.path)",
            "--api-key=\(typesenseAPIKey)",
            "--listen-port=\(port)",
            "--enable-cors"
        ]

        logger.info("Typesense command: \(executablePath.path) \(arguments.joined(separator: " "))")

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
                    self.processCleanup?.writePIDFile(identifier: "typesense", pid: pid)

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
                        "Typesense exited with status: \(result.terminationStatus)"
                    }
                    self.logger.error("Typesense failed: \(errorMsg)")
                    self.startupError = errorMsg
                }
            } catch {
                if !Task.isCancelled {
                    let errorMsg = if !startupErrorLines.isEmpty {
                        startupErrorLines.joined(separator: "\n")
                    } else {
                        error.localizedDescription
                    }
                    self.logger.error("Typesense error: \(errorMsg)")
                    self.startupError = errorMsg
                }
            }

            runningProcess = nil
        }

        // Store task
        runningProcess = task

        // Wait for port to be listening
        var attempts = 0
        let maxAttempts = 25  // Max 5 seconds (25 x 200ms)
        var portIsListening = false

        while attempts < maxAttempts && !portIsListening {
            try await Task.sleep(for: .milliseconds(200))
            attempts += 1

            let portCheck = await checkPortAvailability(port: port)
            if case .inUse = portCheck {
                portIsListening = true
                break
            }
        }

        if !portIsListening {
            if let error = startupError {
                throw TypesenseProcessError.startupFailed(error)
            } else {
                throw TypesenseProcessError.failedToStart
            }
        }

        logger.info("Typesense started successfully on port \(port)")
    }

    // MARK: - Stop

    func stop() async {
        guard let task = runningProcess else {
            logger.info("Typesense not running")
            return
        }

        guard !isStopping else {
            logger.warning("Stop operation already in progress")
            return
        }

        isStopping = true
        defer { isStopping = false }

        logger.info("Stopping Typesense")

        task.cancel()
        runningProcess = nil
        processIdentifier = nil

        processCleanup?.removePIDFile(identifier: "typesense")

        logger.info("Typesense stopped")
    }

    // MARK: - Restart

    func restart(port: Int) async throws {
        if isRunning {
            await stop()
        }

        try await Task.sleep(for: .seconds(1))
        try await start(port: port)
    }

    func restartIfRunning() async throws {
        guard isRunning else {
            logger.debug("Typesense not running, skipping restart")
            return
        }

        let descriptor = FetchDescriptor<TypesenseVersion>()
        guard let typesenseVersion = try? modelContext.fetch(descriptor).first else {
            logger.warning("Cannot restart Typesense: version model not found")
            return
        }

        logger.info("Restarting Typesense with port \(typesenseVersion.port)")
        try await restart(port: typesenseVersion.port)
    }

    // MARK: - Auto-Start

    func startAutoStartService() async {
        logger.info("Checking Typesense auto-start...")

        do {
            let descriptor = FetchDescriptor<TypesenseVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "typesense" }
            )
            guard let typesenseVersion = try modelContext.fetch(descriptor).first else {
                logger.info("Typesense not installed")
                return
            }

            if typesenseVersion.autoStart {
                logger.info("Auto-starting Typesense on port \(typesenseVersion.port)")
                try await start(port: typesenseVersion.port)
            } else {
                logger.info("Typesense auto-start disabled")
            }
        } catch {
            logger.error("Failed to auto-start Typesense: \(error.localizedDescription)")
        }
    }

    // MARK: - Error

    func clearStartupError() {
        startupError = nil
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

enum TypesenseProcessError: LocalizedError {
    case operationInProgress
    case portInUse(Int, String)
    case typesenseNotFound
    case failedToStart
    case startupFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another operation is in progress. Please wait."
        case .portInUse(let port, let process):
            return "Port \(port) is already in use by \(process)"
        case .typesenseNotFound:
            return "Typesense binary not found"
        case .failedToStart:
            return "Typesense failed to start. Please check the installation."
        case .startupFailed(let details):
            return details
        }
    }
}
