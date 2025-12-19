import Foundation
import Subprocess
import SwiftData
import System

enum FrameworkType: String, Codable {
    case laravel = "laravel"
    case symfony = "symfony"
}

/// Local development project (not synced to CloudKit)
@Model
final class LocalProject {

    var id: UUID = UUID()
    var path: String = ""
    var name: String = ""

    /// Auto-generated as `https://{sanitizedName}.localhost`
    var localURL: String = ""

    var phpVersion: PHPVersion?
    var nodeVersion: NodeVersion?

    /// "npm" or "bun"
    var jsPackageManager: String?

    var frameworkRawValue: String?

    var framework: FrameworkType? {
        get { frameworkRawValue.flatMap { FrameworkType(rawValue: $0) } }
        set { frameworkRawValue = newValue?.rawValue }
    }

    var watchedDirectory: WatchedDirectory?
    var gitRemoteURL: String?
    var gitBranch: String?

    /// Cross-store reference to CloudKit DeployedProject
    var linkedDeployedProjectID: UUID?

    /// "https://my-project.localhost" → "my-project"
    var sanitizedName: String {
        localURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: ".localhost", with: "")
    }

    var githubIdentifier: String? {
        gitRemoteURL?.githubIdentifier()
    }

    var gitHubURL: URL? {
        gitRemoteURL?.gitHubURL
    }

    var githubOwner: String? {
        gitRemoteURL?.githubOwner
    }

    var githubRepo: String? {
        gitRemoteURL?.githubRepo
    }

    /// Returns nil if name cannot be sanitized to valid RFC 1123 hostname
    init?(name: String, path: String, phpVersion: PHPVersion? = nil, nodeVersion: NodeVersion? = nil) {
        // Sanitize name to valid RFC 1123 hostname
        guard let sanitizedName = name.sanitizedHostname() else {
            return nil
        }

        self.id = UUID()
        self.name = name
        self.path = path
        self.localURL = "https://\(sanitizedName).localhost"
        self.phpVersion = phpVersion
        self.nodeVersion = nodeVersion
    }

    // MARK: - Fadogen Configuration

    func syncPHPVersion() throws {
        let projectDirectory = URL(fileURLWithPath: path)
        try FadogenShellService.syncPHPVersion(phpVersion?.major, in: projectDirectory)
    }

    func syncNodeVersion() throws {
        let projectDirectory = URL(fileURLWithPath: path)
        try FadogenShellService.syncNodeVersion(nodeVersion?.major, in: projectDirectory)
    }

    func syncPackageManager() throws {
        let projectDirectory = URL(fileURLWithPath: path)
        try FadogenShellService.syncPackageManager(jsPackageManager, in: projectDirectory)
    }

    func syncFadogenConfig() throws {
        try syncPHPVersion()
        try syncNodeVersion()
        try syncPackageManager()
    }

    // MARK: - Detection

    func detectGitRepository() throws -> GitRepository? {
        let gitConfigPath = URL(fileURLWithPath: path)
            .appendingPathComponent(".git/config")

        guard FileManager.default.fileExists(atPath: gitConfigPath.path) else {
            return nil
        }

        let config = try String(contentsOf: gitConfigPath, encoding: .utf8)

        // Parse [remote "origin"] url = ...
        let pattern = #"url\s*=\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: config, range: NSRange(config.startIndex..., in: config)),
              let range = Range(match.range(at: 1), in: config) else {
            return nil
        }

        let remoteURL = String(config[range]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse branch from .git/HEAD
        let headPath = URL(fileURLWithPath: path).appendingPathComponent(".git/HEAD")
        var branch: String? = nil
        if let head = try? String(contentsOf: headPath, encoding: .utf8) {
            // ref: refs/heads/main → "main"
            let branchPattern = #"ref:\s*refs/heads/(.+)"#
            if let branchRegex = try? NSRegularExpression(pattern: branchPattern),
               let branchMatch = branchRegex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
               let branchRange = Range(branchMatch.range(at: 1), in: head) {
                let rawBranch = String(head[branchRange])
                branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return GitRepository(remoteURL: remoteURL, branch: branch ?? "main")
    }

    func detectFramework() throws -> FrameworkType? {
        let composerPath = URL(fileURLWithPath: path)
            .appendingPathComponent("composer.json")

        guard FileManager.default.fileExists(atPath: composerPath.path) else {
            return nil
        }

        let data = try Data(contentsOf: composerPath)

        // Parse JSON to check for framework packages
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let require = json["require"] as? [String: Any] else {
            return nil
        }

        // Check for Laravel
        if require.keys.contains(where: { $0.hasPrefix("laravel/framework") }) {
            return .laravel
        }

        // Check for Symfony
        if require.keys.contains(where: { $0.hasPrefix("symfony/framework-bundle") }) {
            return .symfony
        }

        return nil
    }

    // MARK: - Git Operations

    func updateGitRemoteOrigin(to newURL: String) async throws {
        let result = try await Subprocess.run(
            .path("/usr/bin/git"),
            arguments: ["-C", path, "remote", "set-url", "origin", newURL],
            output: .discarded,
            error: .bytes(limit: 4096)
        )

        guard result.terminationStatus.isSuccess else {
            let stderr = String(bytes: result.standardError, encoding: .utf8) ?? "unknown error"
            throw GitError.commandFailed(stderr)
        }
    }
}

/// Git operation errors
enum GitError: Error, LocalizedError {
    case noProjectPath
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProjectPath:
            return "Project has no local path"
        case .commandFailed(let message):
            return "Git command failed: \(message)"
        }
    }
}

/// Git repository information
struct GitRepository {
    let remoteURL: String
    let branch: String
}
