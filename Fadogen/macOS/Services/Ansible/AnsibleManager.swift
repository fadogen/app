import Foundation
import OSLog
import Subprocess

@Observable
final class AnsibleManager {

    // MARK: - State

    enum ExecutionState: Equatable {
        case idle
        case running(progress: String)
        case completed(result: PlaybookResult)
    }

    enum PlaybookResult: Equatable {
        case success
        case failure(error: String)
    }

    var state: ExecutionState = .idle
    var logs: [String] = []

    var provisioningStatus: String = ""

    let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "ansible")

    // MARK: - Subprocess

    /// Thread-safe holder for subprocess reference (allows termination from other contexts)
    internal actor ExecutionHolder {
        var execution: Execution?

        func set(_ execution: Execution?) {
            self.execution = execution
        }

        func terminate() -> Bool {
            guard let execution = execution else {
                return false
            }

            try? execution.send(signal: .terminate, toProcessGroup: false)
            self.execution = nil
            return true
        }
    }

    internal let executionHolder = ExecutionHolder()

    // MARK: - Public

    func killExecution() async {
        let didKill = await executionHolder.terminate()

        if didKill {
            logger.info("Sent SIGTERM to running Ansible subprocess")
        }
    }

    // MARK: - Private

    /// Creates temp inventory + SSH key files, executes playbook, then cleans up
    private func executePlaybookWithTempFiles(
        server: Server,
        playbookPath: String,
        forceTunnel: Bool = false,
        extraVars: [String: String]? = nil,
        tags: [String]? = nil,
        executor: ([String]) async throws -> Void
    ) async throws {
        defer {
            if case .running = state {
                state = .idle
            }
        }

        guard FileManager.default.fileExists(atPath: playbookPath) else {
            logger.error("Playbook not found at: \(playbookPath)")
            let error = "Playbook not found in app bundle"
            state = .completed(result: .failure(error: error))
            throw AnsibleError.playbookNotFound(playbookPath)
        }

        let inventoryContent = AnsibleHelpers.createInventory(for: server, forceTunnel: forceTunnel)
        let inventoryPath = try AnsibleHelpers.createTempFile(content: inventoryContent, extension: "ini")
        defer {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: inventoryPath))
        }

        var tempKeyPath: String?
        if server.useSSHKey == true, let keyContent = server.sshPrivateKey {
            tempKeyPath = try AnsibleHelpers.createTempSSHKey(content: keyContent, serverId: server.id)
        }
        defer {
            if let keyPath = tempKeyPath {
                try? FileManager.default.removeItem(atPath: keyPath)
            }
        }

        var arguments = ["-m", "ansible", "playbook", "-i", inventoryPath, playbookPath]

        if let vars = extraVars {
            let varsData = try JSONEncoder().encode(vars)
            guard let varsJSON = String(data: varsData, encoding: .utf8) else {
                throw AnsibleError.executionFailed(String(localized: "Failed to encode extra variables as JSON"))
            }
            arguments.append(contentsOf: ["-e", varsJSON])
        }

        if let tags = tags {
            arguments.append(contentsOf: ["--tags", tags.joined(separator: ",")])
        }

        if let keyPath = tempKeyPath {
            arguments.append(contentsOf: ["--private-key", keyPath])
        }

        try await executor(arguments)
    }

    func testConnection(server: Server) async throws {
        state = .running(progress: "Preparing test...")
        logs = []

        let playbookPath = FadogenPaths.ansiblePlaybooksPath.appendingPathComponent("test-connection.yml").path

        try await executePlaybookWithTempFiles(
            server: server,
            playbookPath: playbookPath
        ) { arguments in
            try await executeTestConnectionPlaybook(arguments: arguments)
        }
    }

    func testTunnel(server: Server, forceTunnel: Bool = true) async throws {
        state = .running(progress: "Testing tunnel...")
        logs = []

        let playbookPath = FadogenPaths.ansiblePlaybooksPath.appendingPathComponent("test-tunnel.yml").path

        try await executePlaybookWithTempFiles(
            server: server,
            playbookPath: playbookPath,
            forceTunnel: forceTunnel
        ) { arguments in
            try await executeTestConnectionPlaybook(arguments: arguments)
        }
    }

    func startPreProvisioning(message: String = "Server created, preparing for provisioning...") {
        state = .running(progress: "Preparing server...")
        logs = [message]
    }

    @MainActor
    func appendLog(_ message: String) {
        logs.append(message)
    }

    @MainActor
    func updateStatus(_ message: String) {
        provisioningStatus = message
    }

    func prepareSSH(
        server: Server,
        targetUser: String,
        sshPublicKey: String
    ) async throws {
        state = .running(progress: "Preparing SSH access...")

        let playbookPath = FadogenPaths.ansiblePlaybooksPath.appendingPathComponent("prepare-ssh.yml").path

        let extraVars: [String: String] = [
            "fadogen_target_user": targetUser,
            "fadogen_ssh_public_key": sshPublicKey
        ]

        try await executePlaybookWithTempFiles(
            server: server,
            playbookPath: playbookPath,
            extraVars: extraVars
        ) { arguments in
            try await executeSSHPreparationPlaybook(arguments: arguments)
        }
    }

    func provisionServer(
        server: Server,
        targetUser: String,
        sshPublicKey: String,
        tunnelVars: [String: String]? = nil
    ) async throws {
        state = .running(progress: "Starting security hardening...")

        let playbookPath = FadogenPaths.ansiblePlaybooksPath.appendingPathComponent("provision-server.yml").path

        var extraVars: [String: String] = [
            "fadogen_target_user": targetUser,
            "fadogen_ssh_public_key": sshPublicKey,
            "has_cloudflare_tunnel": tunnelVars != nil ? "true" : "false"
        ]

        // Merge tunnel vars if present
        if let tunnelVars = tunnelVars {
            extraVars.merge(tunnelVars) { (_, new) in new }
        }

        try await executePlaybookWithTempFiles(
            server: server,
            playbookPath: playbookPath,
            extraVars: extraVars
        ) { arguments in
            try await executeProvisioningPlaybook(arguments: arguments)
        }

        if tunnelVars != nil {
            state = .running(progress: "Installing Cloudflare Tunnel...")

            let tunnelPlaybookPath = FadogenPaths.ansiblePlaybooksPath.appendingPathComponent("cloudflare-tunnel.yml").path

            try await executePlaybookWithTempFiles(
                server: server,
                playbookPath: tunnelPlaybookPath,
                extraVars: extraVars
            ) { arguments in
                try await executeProvisioningPlaybook(arguments: arguments)
            }
        }
    }

    func closeSSHPort(
        server: Server,
        tunnelVars: [String: String]
    ) async throws {
        state = .running(progress: "Closing SSH port...")

        let playbookPath = FadogenPaths.ansiblePlaybooksPath.appendingPathComponent("cloudflare-tunnel.yml").path

        var extraVars = tunnelVars
        extraVars["close_ssh_port"] = "true"

        try await executePlaybookWithTempFiles(
            server: server,
            playbookPath: playbookPath,
            extraVars: extraVars,
            tags: ["firewall", "close_ssh"]
        ) { arguments in
            try await executeProvisioningPlaybook(arguments: arguments)
        }
    }

    func configureTraefikDNS(
        server: Server,
        extraVars: [String: String]
    ) async throws {
        state = .running(progress: "Configuring Traefik DNS provider...")

        let playbookPath = FadogenPaths.ansiblePlaybooksPath.appendingPathComponent("add-dns-provider.yml").path

        try await executePlaybookWithTempFiles(
            server: server,
            playbookPath: playbookPath,
            extraVars: extraVars
        ) { arguments in
            try await executeProvisioningPlaybook(arguments: arguments)
        }
    }

}
