import Foundation
import OSLog
import Subprocess
import System

extension AnsibleManager {

    // MARK: - Private

    private var ansiblePath: String {
        let sshpassDir = FadogenPaths.sshpassPath.deletingLastPathComponent().path
        let systemPaths = "/usr/bin:/bin:/usr/sbin:/sbin"
        return "\(sshpassDir):\(systemPaths)"
    }

    private func buildAnsibleEnvironment(
        additionalVars: [Environment.Key: String] = [:]
    ) -> [Environment.Key: String] {
        // Ensure Fadogen's SSH directory exists (isolated from user's ~/.ssh/)
        let sshDir = FadogenPaths.sshDirectory
        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)

        // SSH configuration without known_hosts file
        // StrictHostKeyChecking=no: Accept any host key without saving (no known_hosts modification)
        // UserKnownHostsFile=/dev/null: Discard host keys completely
        let sshArgs = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

        var environment: [Environment.Key: String] = [
            // Ansible config file (contains warning suppression, interpreter config, etc.)
            Environment.Key("ANSIBLE_CONFIG"): FadogenPaths.ansibleConfigPath.path,
            // SSH isolation configuration
            Environment.Key("ANSIBLE_SSH_ARGS"): sshArgs,
            // System paths
            Environment.Key("PATH"): ansiblePath,
            Environment.Key("HOME"): ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
            Environment.Key("USER"): ProcessInfo.processInfo.environment["USER"] ?? NSUserName(),
            Environment.Key("TMPDIR"): ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        ]

        // Merge additional variables (allows overriding base vars if needed)
        environment.merge(additionalVars) { _, new in new }

        return environment
    }

    // MARK: - Playbook Execution

    /// Generic Ansible playbook execution with streaming and custom line processing
    /// - Parameters:
    ///   - arguments: Ansible command arguments
    ///   - environment: Custom environment variables
    ///   - lineProcessor: Closure to extract progress from output lines
    ///   - successMessage: Log message for successful execution
    private func executeAnsiblePlaybook(
        arguments: [String],
        environment: [Environment.Key: String],
        lineProcessor: @escaping (String) -> String?,
        successMessage: String
    ) async throws {
        state = .running(progress: "Connecting to server...")

        var stdoutBuffer: [String] = []  // Accumulate stdout for JSON parsing
        var stderrContent: [String] = []

        let result = try await run(
            .path(FilePath(FadogenPaths.ansiblePythonPath.path)),
            arguments: .init(arguments),
            environment: .custom(environment),
            preferredBufferSize: 1  // Stream logs in real-time
        ) { execution, _, standardOutput, standardError in
            // Store execution reference for potential cancellation
            // This allows ProvisioningService.clearManager() to kill the subprocess
            // when a server is deleted during provisioning
            await executionHolder.set(execution)

            // NOTE: Using inline batching instead of LogBatchingUtility due to custom logic
            // (task/role extraction). See LogBatchingUtility for the standard pattern.
            var buffer: [String] = []
            let flushInterval: Duration = LogBatchingUtility.defaultFlushInterval
            var lastFlush = ContinuousClock.now
            let batchSize = LogBatchingUtility.defaultBatchSize

            // Process stdout
            for try await line in standardOutput.lines() {
                guard !Task.isCancelled else { break }

                stdoutBuffer.append(line)
                buffer.append(line)

                if let progress = lineProcessor(line) {
                    await MainActor.run {
                        self.state = .running(progress: progress)
                    }
                } else if line.contains("PLAY RECAP") {
                    await MainActor.run {
                        self.state = .running(progress: "Finalizing...")
                    }
                }

                let now = ContinuousClock.now
                if buffer.count >= batchSize || now - lastFlush >= flushInterval {
                    await MainActor.run {
                        self.logs.append(contentsOf: buffer)
                    }
                    buffer.removeAll(keepingCapacity: true)
                    lastFlush = now
                }
            }

            // Flush remaining logs
            if !buffer.isEmpty {
                await MainActor.run {
                    self.logs.append(contentsOf: buffer)
                }
            }

            // Process stderr
            for try await line in standardError.lines() {
                guard !Task.isCancelled else { break }

                stderrContent.append(line)
                await MainActor.run {
                    self.logs.append(line)
                }
            }

            // Clear execution reference after subprocess completes
            // IMPORTANT: Must be outside defer to ensure it's actually awaited
            await executionHolder.set(nil)
        }

        // Build error message based on available data
        let errorMessage: String
        if !stderrContent.isEmpty {
            // SSH/connection/system errors appear on stderr
            errorMessage = stderrContent.joined(separator: "\n")
        } else {
            // Playbook task failures are in stdout (parse PLAY RECAP)
            errorMessage = extractErrorFromOutput(stdoutBuffer)
        }

        // Determine final result based ONLY on exit code (Unix convention)
        await MainActor.run {
            if result.terminationStatus.isSuccess {
                // Exit code 0 = success (warnings on stderr are acceptable)
                self.state = .completed(result: .success)
                self.logger.info("\(successMessage)")
            } else {
                // Exit code != 0 = failure
                self.state = .completed(result: .failure(error: errorMessage))
                self.logger.error("Ansible execution failed (exit code != 0): \(errorMessage)")
            }
        }

        guard result.terminationStatus.isSuccess else {
            throw AnsibleError.executionFailed(errorMessage)
        }
    }

    /// Executes test connection playbook
    func executeTestConnectionPlaybook(arguments: [String]) async throws {
        let customEnv = buildAnsibleEnvironment()

        try await executeAnsiblePlaybook(
            arguments: arguments,
            environment: customEnv,
            lineProcessor: { line in
                line.contains("TASK [") ? AnsibleHelpers.extractTaskName(from: line) : nil
            },
            successMessage: "Connection test completed successfully"
        )
    }

    /// Executes SSH preparation playbook
    func executeSSHPreparationPlaybook(arguments: [String]) async throws {
        let customEnv = buildAnsibleEnvironment()

        try await executeAnsiblePlaybook(
            arguments: arguments,
            environment: customEnv,
            lineProcessor: { line in
                line.contains("TASK [") ? AnsibleHelpers.extractTaskName(from: line) : nil
            },
            successMessage: "SSH preparation completed successfully"
        )
    }

    /// Executes provisioning playbook with access to both custom and external roles
    func executeProvisioningPlaybook(arguments: [String]) async throws {
        let customEnv = buildAnsibleEnvironment(
            additionalVars: [
                Environment.Key("ANSIBLE_ROLES_PATH"): "\(FadogenPaths.ansibleRolesPath.path):\(FadogenPaths.ansibleExternalRolesPath.path)"
            ]
        )

        try await executeAnsiblePlaybook(
            arguments: arguments,
            environment: customEnv,
            lineProcessor: { line in
                line.contains("TASK [geerlingguy.") ? AnsibleHelpers.extractRoleName(from: line) : nil
            },
            successMessage: "Provisioning completed successfully"
        )
    }

    // MARK: - Output Parsing

    /// Extracts detailed error information from Ansible text output
    /// - Parameter lines: Stdout lines containing Ansible output
    /// - Returns: Detailed error message extracted from PLAY RECAP and error lines
    private func extractErrorFromOutput(_ lines: [String]) -> String {
        var failures: [String] = []
        var errorDetails: [String] = []

        // Find PLAY RECAP section and parse it
        // Format: "hostname : ok=X changed=Y unreachable=Z failed=W skipped=A rescued=B ignored=C"
        if let recapIndex = lines.firstIndex(where: { $0.contains("PLAY RECAP") }) {
            // Parse lines after PLAY RECAP
            for line in lines[(recapIndex + 1)...] {
                // Skip separator lines
                guard !line.contains("***") && !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                    continue
                }

                // Parse stats line: "hostname : ok=X changed=Y unreachable=Z failed=W ..."
                let components = line.split(separator: ":")
                guard components.count >= 2 else { continue }

                let host = components[0].trimmingCharacters(in: .whitespaces)
                let stats = components[1].trimmingCharacters(in: .whitespaces)

                // Extract failed and unreachable counts
                let failedCount = extractCount(from: stats, key: "failed")
                let unreachableCount = extractCount(from: stats, key: "unreachable")

                if failedCount > 0 {
                    failures.append("❌ \(host): \(failedCount) failed task(s)")
                }
                if unreachableCount > 0 {
                    failures.append("❌ \(host): unreachable")
                }
            }
        }

        // Extract error details from fatal/failed lines
        let errorLines = lines.filter { line in
            line.contains("fatal:") || line.contains("failed:") ||
            (line.contains("FAILED!") && line.contains("=>"))
        }

        if !errorLines.isEmpty {
            errorDetails.append("\nError details:")
            // Take last 5 error lines to avoid overwhelming output
            for line in errorLines.suffix(5) {
                let cleaned = line.trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty {
                    errorDetails.append("  • \(cleaned)")
                }
            }
        }

        // Combine failures and details
        var result = failures
        if !errorDetails.isEmpty {
            result.append(contentsOf: errorDetails)
        }

        if result.isEmpty {
            return "Ansible execution failed with unknown error (exit code != 0)"
        }

        return result.joined(separator: "\n")
    }

    /// Extracts a count value from Ansible stats string
    /// - Parameters:
    ///   - stats: Stats string like "ok=10 changed=3 unreachable=0 failed=1"
    ///   - key: Key to extract (e.g., "failed", "unreachable")
    /// - Returns: Count value or 0 if not found
    private func extractCount(from stats: String, key: String) -> Int {
        // Look for pattern "key=number"
        guard let range = stats.range(of: "\(key)=\\d+", options: .regularExpression) else {
            return 0
        }

        let match = String(stats[range])
        let numberString = match.replacingOccurrences(of: "\(key)=", with: "")
        return Int(numberString) ?? 0
    }
}
