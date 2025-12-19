import Foundation
import Subprocess
import System

@Observable
final class SSHService {

    // MARK: - Key Detection

    /// Returns paths to SSH private keys in ~/.ssh, sorted by modification date (newest first)
    func detectSSHKeys() -> [String] {
        let sshDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sshDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        var validKeys: [(path: String, date: Date)] = []

        for fileURL in contents {
            let filePath = fileURL.path(percentEncoded: false)

            guard !filePath.hasSuffix(".pub"),
                  !filePath.hasSuffix("known_hosts"),
                  !filePath.hasSuffix("config"),
                  !filePath.hasSuffix("authorized_keys"),
                  !filePath.contains("known_hosts."),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let isRegularFile = attributes[.type] as? FileAttributeType,
                  isRegularFile == .typeRegular else {
                continue
            }

            if isValidSSHPrivateKey(at: filePath) {
                let modificationDate = attributes[.modificationDate] as? Date ?? Date.distantPast
                validKeys.append((path: filePath, date: modificationDate))
            }
        }

        return validKeys
            .sorted { $0.date > $1.date }
            .map { $0.path }
    }

    private func isValidSSHPrivateKey(at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let header = String(data: data.prefix(200), encoding: .utf8) else {
            return false
        }

        let validHeaders = [
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN DSA PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN ENCRYPTED PRIVATE KEY-----"
        ]

        let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
        return validHeaders.contains { trimmedHeader.hasPrefix($0) }
    }


    // MARK: - Credential Preparation

    struct PreparedSSHConfig {
        let useSSHKey: Bool
        let keyContent: String?
        let publicKey: String?
    }

    func prepareAuthCredentials(
        authMethodType: AuthMethodType,
        selectedSSHKey: SSHKeyOption,
        customSSHKeyContent: String
    ) async throws -> PreparedSSHConfig {
        switch authMethodType {
        case .sshKey:
            let keyContent: String
            let publicKey: String

            switch selectedSSHKey {
            case .auto:
                guard let keyPair = try await getExistingSSHKey() else {
                    throw SSHError.keyNotFound(String(localized: "No SSH keys found in ~/.ssh"))
                }
                keyContent = keyPair.privateKey
                publicKey = keyPair.publicKey

            case .custom:
                let trimmed = customSSHKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw SSHError.keyNotFound(String(localized: "Custom SSH key content is empty"))
                }
                keyContent = trimmed
                publicKey = try await derivePublicKey(from: keyContent)
            }

            return PreparedSSHConfig(
                useSSHKey: true,
                keyContent: keyContent,
                publicKey: publicKey
            )

        case .password:
            return PreparedSSHConfig(
                useSSHKey: false,
                keyContent: nil,
                publicKey: nil
            )
        }
    }

    // MARK: - Key Management

    struct SSHKeyPair {
        let publicKey: String      // Content of public key (ssh-ed25519 AAA...)
        let privateKey: String     // Content of private key (-----BEGIN...)
        let path: String          // Path to private key (/Users/.../id_ed25519)
    }

    private func getExistingSSHKey() async throws -> SSHKeyPair? {
        let detectedKeys = detectSSHKeys()
        guard let existingKeyPath = detectedKeys.first else {
            return nil
        }

        let privateKey = try String(contentsOfFile: existingKeyPath, encoding: .utf8)
        let publicKey = try await derivePublicKey(from: privateKey)

        return SSHKeyPair(
            publicKey: publicKey,
            privateKey: privateKey,
            path: existingKeyPath
        )
    }

    /// Uses ssh-keygen -y to derive public key from private key content
    func derivePublicKey(from privateKey: String) async throws -> String {
        // Create temporary file for private key
        let tempDir = FileManager.default.temporaryDirectory
        let tempKeyPath = tempDir.appendingPathComponent("fadogen-temp-key-\(UUID().uuidString)")

        try privateKey.write(to: tempKeyPath, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tempKeyPath)
        }

        // Set proper permissions (ssh-keygen requires it)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tempKeyPath.path
        )

        // Derive public key using ssh-keygen -y
        let result = try await run(
            .path(FilePath("/usr/bin/ssh-keygen")),
            arguments: .init(["-y", "-f", tempKeyPath.path]),
            output: .string(limit: .max),
            error: .string(limit: 4096)
        )

        guard result.terminationStatus.isSuccess else {
            let errorDetail = (result.standardError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if errorDetail.contains("incorrect passphrase") || errorDetail.contains("bad passphrase") {
                throw SSHError.keyNotFound(String(localized: "Private key is passphrase-protected. Please use a key without passphrase."))
            }
            if errorDetail.contains("invalid format") || errorDetail.contains("not a") {
                throw SSHError.keyNotFound(String(localized: "Invalid private key format: \(errorDetail)"))
            }
            throw SSHError.keyNotFound("ssh-keygen error: \(errorDetail.isEmpty ? "unknown error" : errorDetail)")
        }

        guard let output = result.standardOutput else {
            throw SSHError.keyNotFound("ssh-keygen returned no output")
        }

        let publicKey = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicKey.isEmpty else {
            throw SSHError.keyNotFound(String(localized: "Derived public key is empty"))
        }

        return publicKey
    }

    /// Returns existing key from ~/.ssh or generates fadogen_ed25519
    func getOrGenerateSSHKey() async throws -> SSHKeyPair {
        // Try to detect existing key
        if let existingKey = try await getExistingSSHKey() {
            return existingKey
        }

        // No key found → generate new one
        let sshDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        let keyPath = sshDirectory.appendingPathComponent("fadogen_ed25519").path
        let keyURL = URL(fileURLWithPath: keyPath)

        // Create .ssh directory if needed
        try? FileManager.default.createDirectory(
            at: sshDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Remove existing key files to avoid ssh-keygen prompt
        if FileManager.default.fileExists(atPath: keyPath) {
            try? FileManager.default.removeItem(atPath: keyPath)
            try? FileManager.default.removeItem(atPath: keyPath + ".pub")
        }

        // Generate ED25519 key (no passphrase for automation)
        let generateResult = try await run(
            .path(FilePath("/usr/bin/ssh-keygen")),
            arguments: .init([
                "-t", "ed25519",
                "-f", keyPath,
                "-N", "",  // No passphrase
                "-C", "fadogen-provisioning"
            ]),
            output: .discarded,
            error: .discarded
        )

        guard generateResult.terminationStatus.isSuccess else {
            throw SSHError.keyNotFound(String(localized: "Failed to generate SSH key"))
        }

        // Set proper permissions
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyPath
        )

        let privateKey = try String(contentsOf: keyURL, encoding: .utf8)
        let publicKey = try String(contentsOf: keyURL.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SSHKeyPair(
            publicKey: publicKey,
            privateKey: privateKey,
            path: keyPath
        )
    }

}

// MARK: - Errors

enum SSHError: LocalizedError {
    case keyNotFound(String)

    var errorDescription: String? {
        switch self {
        case .keyNotFound(let message):
            return message
        }
    }
}
