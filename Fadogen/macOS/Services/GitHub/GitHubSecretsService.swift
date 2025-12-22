import Foundation
import Sodium

struct RepositoryResolution: Identifiable, Sendable {
    let id = UUID()
    let owner: String
    let oldName: String
    let newName: String

    nonisolated var oldFullName: String { "\(owner)/\(oldName)" }
    nonisolated var newFullName: String { "\(owner)/\(newName)" }
    nonisolated var newRemoteURL: String { "git@github.com:\(owner)/\(newName).git" }
}

final class GitHubSecretsService {

    private let githubService: GitHubService

    init(githubService: GitHubService = GitHubService()) {
        self.githubService = githubService
    }

    // MARK: - Errors

    enum SecretsError: Error, LocalizedError {
        case invalidRepository
        case missingCredentials
        case missingToken
        case encryptionFailed
        case invalidPublicKey
        case missingServerData
        case missingEnvContent
        case repositoryNotFound
        case cannotReadHeadCommit
        case repositoryRenamed(RepositoryResolution)

        var errorDescription: String? {
            switch self {
            case .invalidRepository:
                return "Invalid GitHub repository configuration"
            case .missingCredentials:
                return "Missing GitHub integration credentials"
            case .missingToken:
                return "Missing GitHub token"
            case .encryptionFailed:
                return "Failed to encrypt secret with libsodium"
            case .invalidPublicKey:
                return "Invalid repository public key"
            case .missingServerData:
                return "Missing server connection data (host, username, or SSH key)"
            case .missingEnvContent:
                return "No environment configuration available. Relocate the project to a local folder first."
            case .repositoryNotFound:
                return "Could not find GitHub repository (may have been renamed or deleted)"
            case .cannotReadHeadCommit:
                return "Could not read local Git HEAD commit"
            case .repositoryRenamed(let resolution):
                return "Repository renamed: \(resolution.oldFullName) → \(resolution.newFullName)"
            }
        }
    }

    // MARK: - Public

    @discardableResult
    func configureDeploymentSecrets(
        deployedProject: DeployedProject,
        project: LocalProject?,
        server: Server,
        integration: Integration,
        envFileService: EnvFileService,
        additionalEnvSections: [String] = [],
        resolvedRepoName: String? = nil
    ) async throws -> String {
        // Validate GitHub repository
        guard let owner = deployedProject.githubOwner,
              let originalRepo = deployedProject.githubRepo else {
            throw SecretsError.invalidRepository
        }

        // Use resolved name if provided (user confirmed rename), otherwise use original
        let repo = resolvedRepoName ?? originalRepo

        // Get GitHub token
        guard let token = integration.credentials.token else {
            throw SecretsError.missingToken
        }

        // Get repository public key for encryption
        // If this fails with 401/404, try to resolve the repository (may have been renamed)
        let publicKey: GitHubPublicKey
        do {
            publicKey = try await githubService.getRepositoryPublicKey(
                owner: owner,
                repo: repo,
                token: token
            )
        } catch GitHubError.unauthorized, GitHubError.notFound {
            // Only attempt resolution if we haven't already been given a resolved name
            guard resolvedRepoName == nil else {
                // Resolution was already attempted and failed
                throw SecretsError.repositoryNotFound
            }

            // Strategy 1: Try redirect-based resolution (works if repo was simply renamed)
            var resolvedRepo: String?
            if let redirectResolved = try await githubService.resolveRepositoryByRedirect(
                owner: owner,
                repo: repo,
                token: token
            ) {
                resolvedRepo = redirectResolved
            } else {
                // Strategy 2: Fallback to commit-based resolution (if old name was reused)
                // This requires contents:read permission and local project
                guard let project = project else {
                    throw SecretsError.missingServerData
                }

                let commitSHA = try getLocalHeadCommit(projectPath: project.path)

                if let commitResolved = try await githubService.resolveRepositoryByCommit(
                    owner: owner,
                    commitSHA: commitSHA,
                    token: token
                ) {
                    resolvedRepo = commitResolved
                }
            }

            // If we found the new name, throw to let caller show confirmation dialog
            guard let newRepoName = resolvedRepo else {
                throw SecretsError.repositoryNotFound
            }

            let resolution = RepositoryResolution(
                owner: owner,
                oldName: originalRepo,
                newName: newRepoName
            )
            throw SecretsError.repositoryRenamed(resolution)
        }

        // Determine SSH connection details based on Cloudflare Tunnel presence
        let sshHost: String
        let sshPort: String
        let useTunnel: String

        if let tunnel = server.cloudflareTunnel {
            // Server with Cloudflare Tunnel - use tunnel hostname
            sshHost = tunnel.sshHostname
            sshPort = "22"  // Tunnel always uses port 22
            useTunnel = "true"
        } else {
            // Regular server - use direct IP connection
            guard let host = server.host else {
                throw SecretsError.missingServerData
            }
            sshHost = host
            sshPort = "\(server.port ?? 22)"
            useTunnel = "false"
        }

        // Validate server data
        guard let username = server.username,
              let privateKey = server.sshPrivateKey,
              let domain = deployedProject.productionDomain else {
            throw SecretsError.missingServerData
        }

        // Get env content: from local file if available, otherwise from saved backup
        let envContent: String
        let envFileBase64: String

        if let project = project {
            let projectURL = URL(fileURLWithPath: project.path)

            // Framework-specific env file handling (PHP projects only)
            switch project.framework {
            case .symfony?:
                // Symfony: work in memory, don't create .env.production locally
                // (Symfony's .env.production is tracked by git by default = security risk)
                // Additional sections (backup, DNS) are passed in and appended
                envContent = try await envFileService.createSymfonyProductionEnvContent(
                    at: projectURL,
                    domain: domain,
                    additionalSections: additionalEnvSections
                )
                envFileBase64 = try envFileService.encodeContentBase64(envContent)

            default:
                // Laravel and other frameworks: create/update .env.production file locally
                let phpVersion = project.phpVersion?.major ?? "8.4"
                let phpBinaryPath = FadogenPaths.binaryPath(for: phpVersion)

                let envFileURL = try await envFileService.createProductionEnvFile(
                    at: projectURL,
                    domain: domain,
                    phpBinaryPath: phpBinaryPath
                )

                // Read content for backup and encoding
                envContent = try envFileService.readEnvFileContent(at: envFileURL)
                envFileBase64 = try envFileService.encodeContentBase64(envContent)
            }
        } else if let savedContent = deployedProject.envProductionContent {
            // No local project but have saved content: use it directly
            envContent = savedContent
            envFileBase64 = try envFileService.encodeContentBase64(savedContent)
        } else {
            // No local project and no saved content: cannot proceed
            throw SecretsError.missingEnvContent
        }

        // Validate architecture is set (detected during provisioning)
        guard let systemArch = server.architecture else {
            throw SecretsError.missingServerData
        }

        // Generate STACK_ID if not already set (immutable once created)
        let stackID: String
        if let existingStackID = deployedProject.stackID {
            stackID = existingStackID
        } else {
            // Generate unique ID: repo-name + 8-char hash
            let hash = UUID().uuidString.prefix(8).lowercased()
            stackID = "\(repo)-\(hash)"
            deployedProject.stackID = stackID
        }

        // Prepare secrets to encrypt and send (sensitive data)
        let secrets: [String: String] = [
            "SSH_HOST": sshHost,
            "SSH_PORT": sshPort,
            "SSH_USER": username,
            "SSH_PRIVATE_KEY": privateKey,
            "ENV_FILE_BASE64": envFileBase64,
            "USE_CLOUDFLARE_TUNNEL": useTunnel
        ]

        // Prepare variables (non-sensitive configuration)
        let variables: [String: String] = [
            "SYSTEM_ARCH": systemArch,
            "STACK_ID": stackID
        ]

        // Encrypt and send each secret
        for (name, value) in secrets {
            let encryptedValue = try encryptSecret(value, publicKey: publicKey.key)

            try await githubService.createOrUpdateSecret(
                owner: owner,
                repo: repo,
                name: name,
                encryptedValue: encryptedValue,
                keyId: publicKey.keyId,
                token: token
            )
        }

        // Send each variable (no encryption needed)
        for (name, value) in variables {
            try await githubService.createOrUpdateVariable(
                owner: owner,
                repo: repo,
                name: name,
                value: value,
                token: token
            )
        }

        return envContent
    }

    func updateEnvSecret(
        deployedProject: DeployedProject,
        integration: Integration,
        envContent: String
    ) async throws {
        // Validate GitHub repository
        guard let owner = deployedProject.githubOwner,
              let repo = deployedProject.githubRepo else {
            throw SecretsError.invalidRepository
        }

        // Get GitHub token
        guard let token = integration.credentials.token else {
            throw SecretsError.missingToken
        }

        // Get repository public key
        let publicKey = try await githubService.getRepositoryPublicKey(
            owner: owner,
            repo: repo,
            token: token
        )

        // Encode content to base64
        guard let data = envContent.data(using: .utf8) else {
            throw SecretsError.encryptionFailed
        }
        let envFileBase64 = data.base64EncodedString()

        // Encrypt and send
        let encryptedValue = try encryptSecret(envFileBase64, publicKey: publicKey.key)

        try await githubService.createOrUpdateSecret(
            owner: owner,
            repo: repo,
            name: "ENV_FILE_BASE64",
            encryptedValue: encryptedValue,
            keyId: publicKey.keyId,
            token: token
        )
    }

    func deleteDeploymentSecrets(
        owner: String,
        repo: String,
        integration: Integration
    ) async throws {
        // Get GitHub token
        guard let token = integration.credentials.token else {
            throw SecretsError.missingToken
        }

        // List of all secrets to delete
        let secretNames = [
            "SSH_HOST",
            "SSH_PORT",
            "SSH_USER",
            "SSH_PRIVATE_KEY",
            "ENV_FILE_BASE64",
            "USE_CLOUDFLARE_TUNNEL"
        ]

        // List of all variables to delete
        let variableNames = [
            "SYSTEM_ARCH",
            "STACK_ID"
        ]

        // Delete each secret (ignore 404 errors - already deleted)
        for name in secretNames {
            do {
                try await githubService.deleteSecret(
                    owner: owner,
                    repo: repo,
                    name: name,
                    token: token
                )
            } catch GitHubError.notFound {
                // Secret already deleted or never existed - ignore
                continue
            } catch {
                // Re-throw other errors
                throw error
            }
        }

        // Delete each variable (ignore 404 errors - already deleted)
        for name in variableNames {
            do {
                try await githubService.deleteVariable(
                    owner: owner,
                    repo: repo,
                    name: name,
                    token: token
                )
            } catch GitHubError.notFound {
                // Variable already deleted or never existed - ignore
                continue
            } catch {
                // Re-throw other errors
                throw error
            }
        }
    }

    // MARK: - Private

    private func encryptSecret(_ value: String, publicKey: String) throws -> String {
        let sodium = Sodium()

        // Decode base64 public key
        guard let keyData = Data(base64Encoded: publicKey),
              keyData.count == 32 else {
            throw SecretsError.invalidPublicKey
        }

        let keyBytes = [UInt8](keyData)

        // Encrypt with sealed box
        guard let encrypted = sodium.box.seal(
            message: Array(value.utf8),
            recipientPublicKey: keyBytes
        ) else {
            throw SecretsError.encryptionFailed
        }

        // Return base64 encoded
        return Data(encrypted).base64EncodedString()
    }

    private func getLocalHeadCommit(projectPath: String) throws -> String {
        let gitDir = URL(fileURLWithPath: projectPath).appendingPathComponent(".git")
        let headFile = gitDir.appendingPathComponent("HEAD")

        // Read HEAD file
        guard let headContent = try? String(contentsOf: headFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw SecretsError.cannotReadHeadCommit
        }

        // HEAD can be either a direct SHA or a ref (e.g., "ref: refs/heads/main")
        if headContent.hasPrefix("ref: ") {
            // It's a symbolic reference, resolve it
            let refPath = String(headContent.dropFirst(5))  // Remove "ref: "
            let refFile = gitDir.appendingPathComponent(refPath)

            guard let sha = try? String(contentsOf: refFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
                // Try packed-refs as fallback
                let packedRefsFile = gitDir.appendingPathComponent("packed-refs")
                if let packedRefs = try? String(contentsOf: packedRefsFile, encoding: .utf8) {
                    for line in packedRefs.components(separatedBy: .newlines) {
                        let parts = line.split(separator: " ", maxSplits: 1)
                        if parts.count == 2 && parts[1] == refPath {
                            return String(parts[0])
                        }
                    }
                }
                throw SecretsError.cannotReadHeadCommit
            }

            return sha
        } else {
            // HEAD contains the SHA directly (detached HEAD)
            return headContent
        }
    }
}
