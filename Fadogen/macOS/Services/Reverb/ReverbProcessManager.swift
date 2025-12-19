import Foundation
import Subprocess
import System
import OSLog
import SwiftData

@Observable
final class ReverbProcessManager {

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

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "reverb-process")
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
            logger.info("Reverb already running")
            return
        }

        // Check if operation in progress
        guard !isStarting else {
            throw ReverbProcessError.operationInProgress
        }

        isStarting = true
        defer { isStarting = false }

        logger.info("Starting Reverb on port \(port)")

        // Clear previous error
        startupError = nil

        // Check port availability before starting
        let portCheck = await checkPortAvailability(port: port)
        if case .inUse(let process) = portCheck {
            let errorMsg = "Port \(port) already in use by \(process)"
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw ReverbProcessError.portInUse(port, process)
        }

        let binaryPath = FadogenPaths.reverbBinaryPath

        // Find default PHP version installed by Fadogen
        let descriptor = FetchDescriptor<PHPVersion>(
            predicate: #Predicate { $0.isDefault == true }
        )
        guard let defaultPHP = try modelContext.fetch(descriptor).first else {
            let errorMsg = "No default PHP version found. Please install PHP first."
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw ReverbProcessError.phpNotFound
        }

        let phpExecutable = FilePath(defaultPHP.binaryPath.path)

        // Prepare environment to use Fadogen's php.ini (includes Caddy CA in cacert.pem)
        let shortVersion = defaultPHP.major.replacingOccurrences(of: ".", with: "")
        let envVarName = "FADOGEN_PHP_\(shortVersion)_INI_SCAN_DIR"
        let configPath = FadogenPaths.configPath(for: defaultPHP.major)
        let envVarValue = "\(configPath.path)/"
        let envKey = Environment.Key(rawValue: envVarName)!

        // Verify Reverb directory exists
        guard FileManager.default.fileExists(atPath: binaryPath.path) else {
            let errorMsg = "Reverb directory not found: \(binaryPath.path)"
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw ReverbProcessError.reverbNotFound
        }

        // Verify artisan exists
        let artisanPath = binaryPath.appendingPathComponent("artisan")
        guard FileManager.default.fileExists(atPath: artisanPath.path) else {
            let errorMsg = "Artisan not found: \(artisanPath.path)"
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw ReverbProcessError.artisanNotFound
        }

        // Build command: php artisan reverb:start --port={port} --host=127.0.0.1
        // Note: artisan is relative to workingDirectory
        let arguments = [
            "artisan",
            "reverb:start",
            "--port=\(port)",
            "--host=127.0.0.1"
        ]

        logger.info("Reverb command: \(phpExecutable.string) \(arguments.joined(separator: " "))")
        logger.info("Reverb working directory: \(binaryPath.path)")

        // Launch subprocess in background task
        let task = Task {
            // Capture first few error lines for startup error detection
            var startupErrorLines: [String] = []

            do {
                let result = try await run(
                    .path(phpExecutable),
                    arguments: .init(arguments),
                    environment: .inherit.updating([envKey: envVarValue]),
                    workingDirectory: FilePath(binaryPath.path),
                    preferredBufferSize: 1
                ) { execution, standardOutput, _, standardError in
                    // Store PID immediately
                    processIdentifier = execution.processIdentifier

                    // Write PID file for orphan cleanup
                    let pid = Int32(execution.processIdentifier.value)
                    self.processCleanup?.writePIDFile(identifier: "reverb", pid: pid)

                    // Capture first 5 lines of stderr for error detection
                    // Then continue reading to keep process alive
                    var lineCount = 0
                    for try await line in standardError.lines() {
                        if lineCount < 5 {
                            startupErrorLines.append(line)
                            lineCount += 1
                        }
                        // Continue reading to keep process alive (discard lines after first 5)
                    }
                }

                // Process terminated
                if !result.terminationStatus.isSuccess && !Task.isCancelled {
                    let errorMsg = if !startupErrorLines.isEmpty {
                        startupErrorLines.joined(separator: "\n")
                    } else {
                        "Reverb exited with status: \(result.terminationStatus)"
                    }
                    logger.error("Reverb failed: \(errorMsg)")
                    startupError = errorMsg
                }
            } catch {
                // Only store error if not intentionally cancelled
                if !Task.isCancelled {
                    let errorMsg = if !startupErrorLines.isEmpty {
                        startupErrorLines.joined(separator: "\n")
                    } else {
                        error.localizedDescription
                    }
                    logger.error("Reverb error: \(errorMsg)")
                    startupError = errorMsg
                }
            }

            // Remove from running process
            runningProcess = nil
            // Note: Don't reset processIdentifier here - keep it for isRunning check
            // It will auto-cleanup when process actually dies
        }

        // Store task
        runningProcess = task

        // Wait for port to be listening (give Reverb time to bootstrap)
        // Note: Reverb doesn't log to stderr, so we can't rely on runningProcess state
        var attempts = 0
        let maxAttempts = 25  // Max 5 seconds (25 x 200ms) - Reverb can be slow to start
        var portIsListening = false

        while attempts < maxAttempts && !portIsListening {
            try await Task.sleep(for: .milliseconds(200))
            attempts += 1

            // Check if port is listening
            let portCheck = await checkPortAvailability(port: port)
            if case .inUse = portCheck {
                portIsListening = true
                break
            }
        }

        // Check if port is actually listening
        if !portIsListening {
            // Port never started listening - check if we have error details
            if let error = startupError {
                throw ReverbProcessError.startupFailed(error)
            } else {
                throw ReverbProcessError.failedToStart
            }
        }

        logger.info("Reverb started successfully on port \(port)")
    }

    // MARK: - Stop

    func stop() async {
        guard let task = runningProcess else {
            logger.info("Reverb not running")
            return
        }

        // Check if operation in progress
        guard !isStopping else {
            logger.warning("Stop operation already in progress")
            return
        }

        isStopping = true
        defer { isStopping = false }

        logger.info("Stopping Reverb")

        // Cancel the task (this will terminate the subprocess)
        task.cancel()

        // Remove from running process
        runningProcess = nil
        processIdentifier = nil

        // Remove PID file (normal shutdown)
        processCleanup?.removePIDFile(identifier: "reverb")

        logger.info("Reverb stopped")
    }

    // MARK: - Restart

    func restart(port: Int) async throws {
        // Stop if running
        if isRunning {
            await stop()
        }

        // Wait a bit before restarting
        try await Task.sleep(for: .seconds(1))

        // Start again
        try await start(port: port)
    }

    func restartIfRunning() async throws {
        guard isRunning else {
            logger.debug("Reverb not running, skipping restart")
            return
        }

        // Fetch current configuration from SwiftData
        let descriptor = FetchDescriptor<ReverbVersion>()
        guard let reverbVersion = try? modelContext.fetch(descriptor).first else {
            logger.warning("Cannot restart Reverb: version model not found")
            return
        }

        logger.info("Restarting Reverb with port \(reverbVersion.port)")
        try await restart(port: reverbVersion.port)
    }

    // MARK: - Auto-Start

    func startAutoStartService() async {
        logger.info("Checking Reverb auto-start...")

        do {
            let descriptor = FetchDescriptor<ReverbVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "reverb" }
            )
            guard let reverbVersion = try modelContext.fetch(descriptor).first else {
                logger.info("Reverb not installed")
                return
            }

            if reverbVersion.autoStart {
                logger.info("Auto-starting Reverb on port \(reverbVersion.port)")
                try await start(port: reverbVersion.port)
            } else {
                logger.info("Reverb auto-start disabled")
            }
        } catch {
            logger.error("Failed to auto-start Reverb: \(error.localizedDescription)")
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

            // If lsof returns success, port is in use
            if result.terminationStatus.isSuccess,
               let output = result.standardOutput,
               !output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                return .inUse("process using port \(port)")
            }

            return .available
        } catch {
            // lsof exits with 1 if port is free, which throws an error
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

enum ReverbProcessError: LocalizedError {
    case operationInProgress
    case portInUse(Int, String)
    case phpNotFound
    case reverbNotFound
    case artisanNotFound
    case failedToStart
    case startupFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another operation is in progress. Please wait."
        case .portInUse(let port, let process):
            return "Port \(port) is already in use by \(process)"
        case .phpNotFound:
            return "No default PHP version found. Please install PHP first."
        case .reverbNotFound:
            return "Reverb installation directory not found"
        case .artisanNotFound:
            return "Artisan command not found in Reverb directory"
        case .failedToStart:
            return "Reverb failed to start. Please check the installation."
        case .startupFailed(let details):
            return details
        }
    }
}
