import Foundation

/// Pure utility functions for Ansible operations
enum AnsibleHelpers {

    // MARK: - Inventory

    static func createInventory(for server: Server, forceTunnel: Bool = false) -> String {
        var inventory = "[servers]\n"

        let port = server.port ?? 22

        // Determine connection host: tunnel if ready/forced, otherwise direct IP
        let useTunnel = (server.status == .ready || forceTunnel) && server.cloudflareTunnel != nil
        let host = useTunnel ? server.cloudflareTunnel!.sshHostname : (server.host ?? "unknown")

        let username = server.username!
        let useSSHKey = server.useSSHKey!

        // Build inventory line
        var line = "\(host) ansible_user=\(username) ansible_port=\(port)"

        // Add password if using password auth
        if !useSSHKey, let password = server.password {
            line += " ansible_password='\(password)'"
        }

        // Add become password for sudo privilege escalation
        // Priority: sudoPassword > SSH password (for password auth)
        if let sudoPassword = server.sudoPassword, !sudoPassword.isEmpty {
            line += " ansible_become_password='\(sudoPassword)'"
        } else if !useSSHKey, let password = server.password {
            // Fallback: use SSH password for sudo if no explicit sudo password
            line += " ansible_become_password='\(password)'"
        }

        // Add ProxyCommand if using tunnel
        if useTunnel {
            let cloudflaredPath = FadogenPaths.cloudflaredPath.path
            if FileManager.default.fileExists(atPath: cloudflaredPath) {
                let proxyCommand = "\(cloudflaredPath) access ssh --hostname %h"
                line += " ansible_ssh_common_args='-o ProxyCommand=\"\(proxyCommand)\"'"
            }
        }

        inventory += line + "\n"
        return inventory
    }

    // MARK: - Temp Files

    static func createTempFile(content: String, extension ext: String = "txt") throws -> String {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL.path
    }

    /// Creates temp SSH key file with 0600 permissions
    static func createTempSSHKey(content: String, serverId: UUID) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let tempKeyPath = tempDir.appendingPathComponent("fadogen-ssh-key-\(serverId.uuidString)")

        try content.write(to: tempKeyPath, atomically: true, encoding: .utf8)

        // Set proper permissions (0600 - read/write for owner only)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tempKeyPath.path
        )

        return tempKeyPath.path
    }

    // MARK: - Log Parsing

    /// Extracts task name from "TASK [name] ***" output
    static func extractTaskName(from line: String) -> String {
        // Extract task name from "TASK [task name] ***"
        if let start = line.firstIndex(of: "["),
           let end = line.firstIndex(of: "]") {
            let taskName = String(line[line.index(after: start)..<end])
            return "Running: \(taskName)"
        }
        return "Running task..."
    }

    /// Extracts role from "TASK [geerlingguy.security : name] ***" output
    static func extractRoleName(from line: String) -> String {
        // Extract role name from "TASK [geerlingguy.security : Configure SSH] ***"
        if let start = line.firstIndex(of: "["),
           let colon = line.firstIndex(of: ":") {
            let rolePart = String(line[line.index(after: start)..<colon])
            if rolePart.hasPrefix("geerlingguy.") {
                let roleName = rolePart.replacingOccurrences(of: "geerlingguy.", with: "")
                return "Applying: \(roleName)"
            }
        }
        return "Provisioning..."
    }
}
