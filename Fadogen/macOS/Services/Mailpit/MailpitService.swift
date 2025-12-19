import Foundation
import Subprocess
import System
import OSLog
import SwiftData

@Observable
final class MailpitService {
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

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "mailpit")
    private let modelContext: ModelContext
    weak var processCleanup: ProcessCleanupService?
    weak var caddyConfig: CaddyConfigService?

    // MARK: - Initialization

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Configuration

    func getOrCreateConfig() throws -> (config: MailpitConfig, wasCreated: Bool) {
        let descriptor = FetchDescriptor<MailpitConfig>(
            predicate: #Predicate { $0.uniqueIdentifier == "mailpit" }
        )

        if let existing = try modelContext.fetch(descriptor).first {
            return (existing, false)
        }

        // Create default configuration
        let config = MailpitConfig()
        modelContext.insert(config)
        try modelContext.save()
        return (config, true)
    }

    func updateConfig(smtpPort: Int, uiPort: Int, autoStart: Bool) async throws {
        let (config, _) = try getOrCreateConfig()

        let wasRunning = isRunning
        let portsChanged = config.smtpPort != smtpPort || config.uiPort != uiPort

        // Stop if running and ports changed
        if wasRunning && portsChanged {
            await stop()
        }

        // Update configuration
        config.smtpPort = smtpPort
        config.uiPort = uiPort
        config.autoStart = autoStart
        try modelContext.save()

        // Regenerate Caddy config if UI port changed
        if portsChanged {
            try caddyConfig?.generateMainCaddyfile()
            caddyConfig?.reloadCaddy()
        }

        // Restart if was running
        if wasRunning && portsChanged {
            try await start(smtpPort: smtpPort, uiPort: uiPort)
        }
    }

    // MARK: - Lifecycle

    func start(smtpPort: Int, uiPort: Int) async throws {
        // Check if already running
        guard runningProcess == nil else {
            logger.info("Mailpit already running")
            return
        }

        // Check if operation in progress
        guard !isStarting else {
            throw MailpitError.operationInProgress
        }

        isStarting = true
        defer { isStarting = false }

        logger.info("Starting Mailpit on SMTP port \(smtpPort), UI port \(uiPort)")

        // Clear previous error
        startupError = nil

        // Check port availability before starting
        let smtpPortCheck = await checkPortAvailability(port: smtpPort)
        if case .inUse(let process) = smtpPortCheck {
            let errorMsg = "SMTP port \(smtpPort) already in use by \(process)"
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw MailpitError.portInUse(smtpPort, process)
        }

        let uiPortCheck = await checkPortAvailability(port: uiPort)
        if case .inUse(let process) = uiPortCheck {
            let errorMsg = "UI port \(uiPort) already in use by \(process)"
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw MailpitError.portInUse(uiPort, process)
        }

        // Verify Mailpit binary exists
        let mailpitPath = FadogenPaths.mailpitBinaryPath
        guard FileManager.default.fileExists(atPath: mailpitPath.path) else {
            let errorMsg = "Mailpit binary not found: \(mailpitPath.path)"
            logger.error("\(errorMsg)")
            startupError = errorMsg
            throw MailpitError.binaryNotFound
        }

        // Create data directory if needed
        let dataDir = FadogenPaths.mailpitDataDirectory
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // Build command arguments
        let databasePath = dataDir.appendingPathComponent("mailpit.db").path
        let arguments = [
            "--smtp", "127.0.0.1:\(smtpPort)",
            "--listen", "127.0.0.1:\(uiPort)",
            "--database", databasePath,
            "--max", "500"
        ]

        logger.info("Mailpit command: \(mailpitPath.path) \(arguments.joined(separator: " "))")

        // Launch subprocess in background task
        let task = Task {
            var startupErrorLines: [String] = []

            do {
                let result = try await run(
                    .path(FilePath(mailpitPath.path)),
                    arguments: .init(arguments),
                    environment: .inherit,
                    preferredBufferSize: 1
                ) { execution, standardOutput, _, standardError in
                    // Store PID immediately
                    self.processIdentifier = execution.processIdentifier

                    // Write PID file for orphan cleanup
                    let pid = Int32(execution.processIdentifier.value)
                    self.processCleanup?.writePIDFile(identifier: "mailpit", pid: pid)

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
                        "Mailpit exited with status: \(result.terminationStatus)"
                    }
                    self.logger.error("Mailpit failed: \(errorMsg)")
                    self.startupError = errorMsg
                }
            } catch {
                if !Task.isCancelled {
                    let errorMsg = if !startupErrorLines.isEmpty {
                        startupErrorLines.joined(separator: "\n")
                    } else {
                        error.localizedDescription
                    }
                    self.logger.error("Mailpit error: \(errorMsg)")
                    self.startupError = errorMsg
                }
            }

            runningProcess = nil
        }

        // Store task
        runningProcess = task

        // Wait for port to be listening
        var attempts = 0
        let maxAttempts = 25  // Max 5 seconds
        var portIsListening = false

        while attempts < maxAttempts && !portIsListening {
            try await Task.sleep(for: .milliseconds(200))
            attempts += 1

            let portCheck = await checkPortAvailability(port: smtpPort)
            if case .inUse = portCheck {
                portIsListening = true
                break
            }
        }

        if !portIsListening {
            if let error = startupError {
                throw MailpitError.startupFailed(error)
            } else {
                throw MailpitError.failedToStart
            }
        }

        logger.info("Mailpit started successfully")
    }

    func stop() async {
        guard let task = runningProcess else {
            logger.info("Mailpit not running")
            return
        }

        guard !isStopping else {
            logger.warning("Stop operation already in progress")
            return
        }

        isStopping = true
        defer { isStopping = false }

        logger.info("Stopping Mailpit")

        task.cancel()
        runningProcess = nil
        processIdentifier = nil

        processCleanup?.removePIDFile(identifier: "mailpit")

        logger.info("Mailpit stopped")
    }

    // MARK: - Auto-Start

    func startAutoStartService() async {
        logger.info("Checking Mailpit auto-start...")

        do {
            let (config, wasCreated) = try getOrCreateConfig()

            // Regenerate Caddyfile only on first launch (when config is created)
            if wasCreated {
                logger.info("Mailpit config created, regenerating Caddyfile for mail.localhost")
                try? caddyConfig?.generateMainCaddyfile()
                caddyConfig?.reloadCaddy()
            }

            if config.autoStart {
                logger.info("Auto-starting Mailpit on SMTP port \(config.smtpPort), UI port \(config.uiPort)")
                try await start(smtpPort: config.smtpPort, uiPort: config.uiPort)
            } else {
                logger.info("Mailpit auto-start disabled")
            }
        } catch {
            logger.error("Failed to auto-start Mailpit: \(error.localizedDescription)")
        }
    }

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

enum MailpitError: LocalizedError {
    case operationInProgress
    case portInUse(Int, String)
    case binaryNotFound
    case failedToStart
    case startupFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another operation is in progress. Please wait."
        case .portInUse(let port, let process):
            return "Port \(port) is already in use by \(process)"
        case .binaryNotFound:
            return "Mailpit binary not found in app bundle"
        case .failedToStart:
            return "Mailpit failed to start. Please check the configuration."
        case .startupFailed(let details):
            return details
        }
    }
}
