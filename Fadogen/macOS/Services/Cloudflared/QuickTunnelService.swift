import Foundation
import Subprocess
import System
import OSLog
import SwiftData

/// Manages temporary quick tunnels for sharing projects publicly without Cloudflare integration.
/// Each project gets its own cloudflared process with an auto-generated trycloudflare.com URL.
/// Tunnels are in-memory only and do not persist between app restarts.
@Observable
final class QuickTunnelService {
    // MARK: - State

    /// Active quick tunnels by project ID
    private(set) var activeTunnels: [UUID: QuickTunnel] = [:]

    /// Per-project operation state for UI feedback
    private(set) var projectStates: [UUID: QuickTunnelState] = [:]

    /// Running process tasks by project ID
    private var runningProcesses: [UUID: Task<Void, Never>] = [:]
    private var processIdentifiers: [UUID: ProcessIdentifier] = [:]

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "quick-tunnel")
    private let modelContext: ModelContext
    weak var processCleanup: ProcessCleanupService?
    weak var caddyConfig: CaddyConfigService?

    // MARK: - Initialization

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Public API

    /// Check if a project has an active quick tunnel
    func isActive(for projectID: UUID) -> Bool {
        activeTunnels[projectID] != nil
    }

    /// Get the current state for a project
    func state(for projectID: UUID) -> QuickTunnelState {
        projectStates[projectID] ?? .idle
    }

    /// Get the active tunnel for a project
    func tunnel(for projectID: UUID) -> QuickTunnel? {
        activeTunnels[projectID]
    }

    /// Start a quick tunnel for a project
    func start(for project: LocalProject) async throws {
        let projectID = project.id

        // Guard against concurrent operations
        if case .starting = projectStates[projectID] {
            throw QuickTunnelError.operationInProgress
        }

        guard activeTunnels[projectID] == nil else {
            throw QuickTunnelError.tunnelAlreadyActive
        }

        projectStates[projectID] = .starting

        do {
            let tunnel = try await launchTunnel(project: project)
            activeTunnels[projectID] = tunnel
            projectStates[projectID] = .running(tunnel)
            logger.info("Quick tunnel started for \(project.name): \(tunnel.publicURL)")

            // Update Caddyfile to include the public hostname
            caddyConfig?.reconcile(project: project)
        } catch {
            projectStates[projectID] = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Stop a quick tunnel for a project
    func stop(for projectID: UUID) async {
        guard runningProcesses[projectID] != nil else {
            return
        }

        projectStates[projectID] = .stopping

        // Kill the process
        if let pid = processIdentifiers[projectID] {
            kill(pid_t(pid.value), SIGTERM)
        }

        // Cancel the monitoring task
        runningProcesses[projectID]?.cancel()

        // Cleanup
        cleanup(projectID: projectID)

        projectStates[projectID] = .idle
        logger.info("Quick tunnel stopped for project \(projectID)")

        // Update Caddyfile to remove the public hostname
        if let project = fetchProject(by: projectID) {
            caddyConfig?.reconcile(project: project)
        }
    }

    /// Fetch a LocalProject by ID
    private func fetchProject(by projectID: UUID) -> LocalProject? {
        let descriptor = FetchDescriptor<LocalProject>(
            predicate: #Predicate { $0.id == projectID }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Stop all active quick tunnels (called on app quit)
    func stopAll() async {
        let projectIDs = Array(runningProcesses.keys)
        for projectID in projectIDs {
            await stop(for: projectID)
        }
    }

    // MARK: - Private

    private func launchTunnel(project: LocalProject) async throws -> QuickTunnel {
        let projectID = project.id

        // Verify cloudflared binary exists
        let cloudflaredPath = FadogenPaths.cloudflaredPath
        guard FileManager.default.fileExists(atPath: cloudflaredPath.path) else {
            throw QuickTunnelError.binaryNotFound
        }

        // Use the project's local URL (e.g., "https://myproject.localhost")
        // This is the same approach as permanent tunnels in CloudflaredTunnelService
        let targetURL = project.localURL
        guard !targetURL.isEmpty else {
            throw QuickTunnelError.processExitedUnexpectedly("Project has no local URL")
        }

        // Actor to safely capture URL and connection state from subprocess
        actor TunnelCapture {
            var capturedURL: String?
            var isConnected = false
            var startupError: String?

            func setURL(_ url: String) {
                capturedURL = url
            }

            func setConnected() {
                isConnected = true
            }

            func setError(_ error: String) {
                if startupError == nil {
                    startupError = error
                }
            }

            func getURL() -> String? {
                capturedURL
            }

            func isReady() -> Bool {
                capturedURL != nil && isConnected
            }

            func getError() -> String? {
                startupError
            }
        }

        let capture = TunnelCapture()

        let task = Task {
            do {
                let result = try await run(
                    .path(FilePath(cloudflaredPath.path)),
                    arguments: [
                        "tunnel",
                        "--url", targetURL,
                        "--no-tls-verify"  // Skip TLS verification (Caddy uses internal CA)
                    ],
                    environment: .inherit,
                    preferredBufferSize: 1
                ) { execution, _, _, standardError in
                    self.processIdentifiers[projectID] = execution.processIdentifier

                    let pid = Int32(execution.processIdentifier.value)
                    self.processCleanup?.writePIDFile(
                        identifier: "quick-tunnel-\(projectID)",
                        pid: pid
                    )

                    // Parse output for tunnel URL (cloudflared outputs to stderr)
                    for try await line in standardError.lines() {
                        self.logger.debug("cloudflared[\(projectID)]: \(line)")

                        // Look for the trycloudflare.com URL
                        if let url = self.extractTunnelURL(from: line) {
                            await capture.setURL(url)
                        }

                        // Wait for tunnel to be fully connected
                        if line.contains("Registered tunnel connection") {
                            await capture.setConnected()
                        }

                        // Capture errors before URL is found
                        if line.contains("ERR") {
                            let urlAlreadyCaptured = await capture.getURL() != nil
                            if !urlAlreadyCaptured {
                                await capture.setError(line)
                            }
                        }
                    }
                }

                if !result.terminationStatus.isSuccess && !Task.isCancelled {
                    self.logger.error("Quick tunnel exited with: \(result.terminationStatus)")
                }
            } catch {
                if !Task.isCancelled {
                    self.logger.error("Quick tunnel error: \(error.localizedDescription)")
                }
            }

            // Process ended - cleanup if not already done
            if self.activeTunnels[projectID] != nil {
                self.cleanup(projectID: projectID)
                self.projectStates[projectID] = .idle
            }
        }

        runningProcesses[projectID] = task

        // Wait for tunnel to be fully ready (URL + connection established)
        let maxWaitSeconds = 60
        let pollIntervalMs = 100
        let maxIterations = (maxWaitSeconds * 1000) / pollIntervalMs

        for _ in 0..<maxIterations {
            try await Task.sleep(for: .milliseconds(pollIntervalMs))

            // Wait for both URL and "Registered tunnel connection"
            if await capture.isReady(), let url = await capture.getURL() {
                // Wait for DNS to propagate before declaring tunnel ready
                if let hostname = URL(string: url)?.host {
                    await DNSHelper.waitForDNS(hostname: hostname)
                }
                return QuickTunnel(projectID: projectID, publicURL: url)
            }

            if let error = await capture.getError() {
                // Only fail if URL hasn't been captured yet
                let urlCaptured = await capture.getURL() != nil
                if !urlCaptured {
                    throw QuickTunnelError.processExitedUnexpectedly(error)
                }
            }

            // Check if process died
            if runningProcesses[projectID] == nil {
                throw QuickTunnelError.processExitedUnexpectedly("Process terminated unexpectedly")
            }
        }

        // Timeout - cleanup and throw
        await stop(for: projectID)
        throw QuickTunnelError.timeout
    }

    /// Extract tunnel URL from cloudflared output.
    /// Matches: https://something.trycloudflare.com
    private func extractTunnelURL(from line: String) -> String? {
        let pattern = #"(https://[a-z0-9-]+\.trycloudflare\.com)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range])
    }

    /// Cleanup resources for a project
    private func cleanup(projectID: UUID) {
        runningProcesses.removeValue(forKey: projectID)
        processIdentifiers.removeValue(forKey: projectID)
        activeTunnels.removeValue(forKey: projectID)
        processCleanup?.removePIDFile(identifier: "quick-tunnel-\(projectID)")
    }

}
