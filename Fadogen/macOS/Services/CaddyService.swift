import Foundation
import Subprocess
import System
import OSLog

@Observable
class CaddyService {
    var state: ServiceState = .stopped
    var logs: [String] = []

    private var caddyTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "caddy")

    // Dependencies for reload cascade (set by AppServices)
    weak var phpFPM: PHPFPMService?
    weak var reverbProcess: ReverbProcessManager?
    weak var processCleanup: ProcessCleanupService?
    weak var certificateService: CaddyCertificateService?

    /// Caddy appends /caddy to both XDG_CONFIG_HOME and XDG_DATA_HOME
    private var caddyEnvironment: [Environment.Key: String] {
        let dataDir = FadogenPaths.caddyDataDirectory
        let configDir = FadogenPaths.caddyConfigDirectory

        return [
            Environment.Key(rawValue: "XDG_CONFIG_HOME")!: configDir.deletingLastPathComponent().path,
            Environment.Key(rawValue: "XDG_DATA_HOME")!: dataDir.deletingLastPathComponent().path,
            Environment.Key(rawValue: "HOME")!: NSHomeDirectory()
        ]
    }

    func start(restartDependencies: Bool = true) async throws {
        switch state {
        case .stopped, .error:
            break  // OK to start
        default:
            logger.warning("Caddy is not in stopped state")
            return
        }

        // Clear cached leaf certificates before starting
        // This ensures Caddy generates fresh certificates with current CA
        clearLeafCertificates()

        state = .starting
        logs = []

        caddyTask = Task {
            var hasReceivedFirstLog = false

            do {
                // Create Application Support directory
                let configDir = try createConfigDirectory()

                // Convert to FilePath for Subprocess
                let caddyFilePath: FilePath = .init(FadogenPaths.caddyPath.path)
                let workingDir: FilePath = .init(configDir.path)

                // Capture the result to check termination status
                let result = try await run(
                    .path(caddyFilePath),
                    arguments: ["run"],
                    environment: .inherit.updating(caddyEnvironment),
                    workingDirectory: workingDir,
                    // Use buffer size of 1 byte to ensure logs arrive immediately
                    // (Caddy logs are sporadic, larger buffers would delay output)
                    preferredBufferSize: 1
                ) { execution, _, _, standardError in
                    // Caddy logs to stderr by default
                    // NOTE: Using inline batching instead of LogBatchingUtility due to custom logic
                    // (hasReceivedFirstLog). See LogBatchingUtility for the standard pattern.
                    var buffer: [String] = []
                    let flushInterval: Duration = LogBatchingUtility.defaultFlushInterval
                    var lastFlush = ContinuousClock.now
                    let batchSize = LogBatchingUtility.defaultBatchSize

                    for try await line in standardError.lines() {
                        // Mark as running on first log
                        if !hasReceivedFirstLog {
                            state = .running
                            hasReceivedFirstLog = true

                            // Write PID file for orphan cleanup
                            let pid = Int32(execution.processIdentifier.value)
                            processCleanup?.writePIDFile(identifier: "caddy", pid: pid)
                        }

                        buffer.append(line)

                        let now = ContinuousClock.now
                        if buffer.count >= batchSize || now - lastFlush >= flushInterval {
                            logs.append(contentsOf: buffer)
                            buffer.removeAll(keepingCapacity: true)
                            lastFlush = now
                        }
                    }

                    // Flush remaining logs
                    if !buffer.isEmpty {
                        logs.append(contentsOf: buffer)
                    }
                }

                // Check termination status after process ends
                // Only update state if not already stopped by user
                if state != .stopped {
                    if !result.terminationStatus.isSuccess {
                        logger.error("Caddy exited with failure: \(result.terminationStatus)")

                        if hasReceivedFirstLog {
                            // Caddy started but crashed later
                            state = .error("Exited unexpectedly")
                        } else {
                            // Caddy never started (no logs received)
                            state = .error("Failed to start")
                        }
                    } else if state == .running {
                        // Normal termination
                        state = .stopped
                    }
                }
            } catch {
                logger.error("Caddy error: \(error.localizedDescription)")
                state = .error("Launch failed")
            }
        }

        // Wait for Caddy to actually start (first stderr log received)
        let maxAttempts = 20  // Max 2 seconds (20 x 100ms)
        var attempts = 0

        while attempts < maxAttempts && state != .running {
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1

            // Check if startup failed
            if case .error = state {
                throw CaddyError.startupFailed
            }
        }

        // Verify Caddy actually started
        if state != .running {
            throw CaddyError.startupFailed
        }

        logger.info("Caddy started successfully")

        // Wait for CA certificate generation and install to Keychain
        await waitForCertificateAndInstall(restartDependencies: restartDependencies)
    }

    /// Waits for CA certificate generation and installs to Keychain
    private func waitForCertificateAndInstall(restartDependencies: Bool) async {
        let caPath = FadogenPaths.caddyDataDirectory
            .appendingPathComponent("pki/authorities/local/root.crt")

        // Quick check: if certificate exists and is already trusted, skip everything
        if FileManager.default.fileExists(atPath: caPath.path) {
            if certificateService?.isCertificateAlreadyInstalled() == true {
                logger.debug("Certificate already installed, skipping")
                return
            }
            // Certificate exists but not installed - proceed to install immediately
            await performCertificateInstallation(restartDependencies: restartDependencies)
            return
        }

        // Certificate doesn't exist yet - poll for up to 10 seconds
        let maxAttempts = 100  // 10 seconds (100 x 100ms)
        var attempts = 0

        while attempts < maxAttempts {
            if FileManager.default.fileExists(atPath: caPath.path) {
                await performCertificateInstallation(restartDependencies: restartDependencies)
                return
            }

            // Check if Caddy crashed while waiting
            if state != .running {
                logger.warning("Caddy stopped while waiting for certificate generation")
                return
            }

            try? await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }

        // Timeout - certificate not generated (this is OK, might be generated later on first deployedProject)
        logger.debug("Certificate not generated after 10 seconds (will check again on reload)")
    }

    private func performCertificateInstallation(restartDependencies: Bool) async {
        // Step 1: Install certificate to Keychain
        await certificateService?.installCertificateIfNeeded()

        // Step 2: Update cacert.pem with new Caddy certificate for PHP
        do {
            if try PHPConfigService.ensureCaddyCACert() {
                logger.info("Updated cacert.pem with Caddy CA certificate")
            }
        } catch {
            logger.error("Failed to update cacert.pem: \(error.localizedDescription)")
        }

        // Step 3: Restart dependent services if requested
        // Skip during initial app startup to avoid unnecessary restarts
        if restartDependencies {
            // Restart PHP-FPM processes (reload cacert.pem)
            if let phpFPM = phpFPM, !phpFPM.states.isEmpty {
                await phpFPM.restartAll()
                logger.info("Restarted PHP-FPM processes to reload certificates")
            }

            // Restart Reverb if running (reload cacert.pem)
            // Note: restartIfRunning() already logs "Restarting Reverb with port X"
            if let reverbProcess = reverbProcess, reverbProcess.isRunning {
                try? await reverbProcess.restartIfRunning()
            }
        }
    }

    func stop() async {
        switch state {
        case .running, .starting, .error:
            break  // OK to stop
        default:
            return
        }

        logger.info("Stopping Caddy...")
        state = .stopping

        caddyTask?.cancel()
        caddyTask = nil

        // Remove PID file (normal shutdown)
        processCleanup?.removePIDFile(identifier: "caddy")

        state = .stopped
    }

    func reload() {
        guard state == .running else {
            logger.warning("Cannot reload Caddy: not running")
            return
        }

        Task {
            do {
                // Note: Don't clear leaf certificates on reload
                // The CA doesn't change during reload, only the configuration (PHP socket path)
                // Existing certificates remain valid and signed by the same CA

                let configPath = FadogenPaths.caddyConfigDirectory
                    .appendingPathComponent("Caddyfile").path

                _ = try await run(
                    .path(.init(FadogenPaths.caddyPath.path)),
                    arguments: ["reload", "--config", configPath],
                    environment: .inherit.updating(caddyEnvironment),
                    output: .discarded,
                    error: .discarded
                )

                logger.info("Caddy configuration reloaded")

                // Check for certificate after reload (first project may trigger PKI generation)
                // This handles the case where app starts without projects, then user adds first project later
                await waitForCertificateAndInstall(restartDependencies: true)
            } catch {
                logger.error("Failed to reload Caddy: \(error.localizedDescription)")
            }
        }
    }

    /// Forces Caddy to regenerate project certificates on next request
    private func clearLeafCertificates() {
        let certificatesPath = FadogenPaths.caddyDataDirectory
            .appendingPathComponent("certificates")

        guard FileManager.default.fileExists(atPath: certificatesPath.path) else {
            logger.debug("No cached certificates to clear")
            return
        }

        do {
            try FileManager.default.removeItem(at: certificatesPath)
            logger.info("Cleared cached leaf certificates - Caddy will regenerate them")
        } catch {
            logger.warning("Failed to clear cached certificates: \(error.localizedDescription)")
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Private

    private func createConfigDirectory() throws -> URL {
        // Directory already created by CaddyConfigService.generateMainCaddyfile()
        // Just return the path for use as working directory
        let configDir = FadogenPaths.caddyConfigDirectory

        return configDir
    }
}

// MARK: - Errors

enum CaddyError: LocalizedError {
    case binaryNotFound
    case applicationSupportNotFound
    case startupFailed

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Caddy binary not found in app bundle"
        case .applicationSupportNotFound:
            return "Application Support directory not found"
        case .startupFailed:
            return "Caddy failed to start. Please check the logs."
        }
    }
}
