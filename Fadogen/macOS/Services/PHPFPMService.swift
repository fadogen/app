import Foundation
import Subprocess
import System
import OSLog
import SwiftData

@Observable
final class PHPFPMService {
    var states: [String: ServiceState] = [:]
    var logs: [String] = []

    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var processPIDs: [String: Int32] = [:]
    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "php-fpm")
    private let modelContext: ModelContext

    // Dependency (set by AppServices)
    weak var processCleanup: ProcessCleanupService?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func startAll() async {
        // Fetch installed PHP versions from SwiftData
        let descriptor = FetchDescriptor<PHPVersion>()
        guard let versions = try? modelContext.fetch(descriptor) else {
            logger.error("Failed to fetch PHP versions")
            return
        }

        logger.info("Starting PHP-FPM for \(versions.count) version(s)")

        for version in versions {
            start(major: version.major)
        }
    }

    /// Start PHP-FPM for a specific version
    func start(major: String) {
        // Check if already running or starting
        if let state = states[major], state.isActive {
            logger.warning("PHP-FPM \(major) is already \(state.displayText)")
            return
        }

        logger.info("Starting PHP-FPM \(major)")
        states[major] = .starting

        let task = Task {
            var hasReceivedFirstLog = false

            do {
                // Get PHP-FPM binary path (not CLI binary)
                let binaryPath = FadogenPaths.fpmBinaryPath(for: major)
                let binaryFilePath: FilePath = .init(binaryPath.path)

                // Get config path
                let configPath = FadogenPaths.configPath(for: major)
                let fpmConfigPath = configPath.appendingPathComponent("php-fpm.conf")

                // Verify binary and config exist
                guard FileManager.default.fileExists(atPath: binaryPath.path) else {
                    throw PHPFPMError.binaryNotFound(major)
                }

                guard FileManager.default.fileExists(atPath: fpmConfigPath.path) else {
                    throw PHPFPMError.configNotFound(major)
                }

                // Prepare environment variable
                let shortVersion = major.replacingOccurrences(of: ".", with: "")
                let envVarName = "FADOGEN_PHP_\(shortVersion)_INI_SCAN_DIR"
                let envVarValue = "\(configPath.path)/"
                let envKey = Environment.Key(rawValue: envVarName)!

                // Run PHP-FPM in foreground mode
                let result = try await run(
                    .path(binaryFilePath),
                    arguments: ["-R", "-y", fpmConfigPath.path],
                    environment: .inherit.updating([envKey: envVarValue]),
                    preferredBufferSize: 1
                ) { execution, _, _, standardError in
                    // Store PID for process group killing
                    let pid = Int32(execution.processIdentifier.value)
                    self.processPIDs[major] = pid

                    // Write PID file for orphan cleanup
                    self.processCleanup?.writePIDFile(identifier: "php-\(major)", pid: pid)

                    // PHP-FPM logs to stderr by default
                    // Batch logs to avoid overwhelming SwiftUI with rapid updates
                    var buffer: [String] = []
                    let flushInterval: Duration = .milliseconds(100)
                    var lastFlush = ContinuousClock.now

                    let prefix = "[PHP \(major)]"

                    for try await line in standardError.lines() {
                        // Mark as running on first log
                        if !hasReceivedFirstLog {
                            self.states[major] = .running
                            hasReceivedFirstLog = true
                        }

                        buffer.append("\(prefix) \(line)")

                        let now = ContinuousClock.now
                        if buffer.count >= 10 || now - lastFlush >= flushInterval {
                            self.logs.append(contentsOf: buffer)
                            buffer.removeAll(keepingCapacity: true)
                            lastFlush = now
                        }
                    }

                    // Flush remaining logs
                    if !buffer.isEmpty {
                        self.logs.append(contentsOf: buffer)
                    }
                }

                // Check termination status
                if let currentState = self.states[major], currentState != .stopped {
                    if !result.terminationStatus.isSuccess {
                        self.logger.error("PHP-FPM \(major) exited with failure: \(result.terminationStatus)")

                        if hasReceivedFirstLog {
                            self.states[major] = .error("Exited unexpectedly")
                        } else {
                            self.states[major] = .error("Failed to start")
                        }
                    } else if currentState == .running {
                        self.states[major] = .stopped
                    }
                }
            } catch {
                self.logger.error("PHP-FPM \(major) error: \(error.localizedDescription)")
                self.states[major] = .error("Launch failed")
            }
        }

        activeTasks[major] = task
    }

    /// Stop PHP-FPM for a specific version
    func stop(major: String) async {
        guard let state = states[major], state.isActive else {
            logger.warning("PHP-FPM \(major) is not running")
            return
        }

        logger.info("Stopping PHP-FPM \(major)")
        states[major] = .stopping

        // Kill the entire process group (master + all workers)
        // Using negative PID kills the process group
        if let pid = processPIDs[major] {
            do {
                // Send SIGTERM to the entire process group
                _ = try await run(
                    .path(.init("/bin/kill")),
                    arguments: ["--", "-\(pid)"],
                    output: .discarded,
                    error: .discarded
                )

                // Give processes time to shutdown gracefully
                try? await Task.sleep(for: .milliseconds(100))

                logger.info("Killed process group for PHP-FPM \(major) (PID: \(pid))")
            } catch {
                logger.error("Failed to kill process group for PHP-FPM \(major): \(error.localizedDescription)")
            }

            processPIDs.removeValue(forKey: major)

            // Remove PID file (normal shutdown)
            processCleanup?.removePIDFile(identifier: "php-\(major)")
        }

        activeTasks[major]?.cancel()
        activeTasks.removeValue(forKey: major)

        states[major] = .stopped
    }

    /// Stop all PHP-FPM processes
    func stopAll() async {
        logger.info("Stopping all PHP-FPM processes")

        for major in activeTasks.keys {
            await stop(major: major)
        }
    }

    /// Restart PHP-FPM for a specific version (useful after updates)
    func restart(major: String) {
        logger.info("Restarting PHP-FPM \(major)")

        Task {
            await stop(major: major)
            // Small delay to ensure clean shutdown
            try? await Task.sleep(for: .milliseconds(500))
            start(major: major)
        }
    }

    /// Restart all running PHP-FPM processes
    /// Useful after updating cacert.pem or configuration changes
    func restartAll() async {
        logger.info("Restarting all PHP-FPM processes")

        // Get all currently running versions
        let runningVersions = states.filter { $0.value == .running }.map { $0.key }

        // Stop all running versions
        for major in runningVersions {
            await stop(major: major)
        }

        // Small delay to ensure clean shutdown
        try? await Task.sleep(for: .milliseconds(500))

        // Restart all previously running versions
        for major in runningVersions {
            start(major: major)
        }

        logger.info("Restarted \(runningVersions.count) PHP-FPM process(es)")
    }

    /// Clear all logs
    func clearLogs() {
        logs.removeAll()
    }
}

// MARK: - Errors

enum PHPFPMError: LocalizedError {
    case binaryNotFound(String)
    case configNotFound(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let version):
            return "PHP \(version) binary not found"
        case .configNotFound(let version):
            return "PHP-FPM config not found for version \(version)"
        }
    }
}
