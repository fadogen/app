import Foundation
import Subprocess
import SwiftData
import System

/// Unified framework type for all project types (PHP and SPA)
/// Marked nonisolated to allow access from SwiftData models
nonisolated enum ProjectFramework: String, Codable, Sendable {
    // PHP frameworks
    case laravel
    case symfony

    // Meta-frameworks (SSR/SSG capable, require server)
    case nextjs
    case nuxt
    case sveltekit

    // Vite-based SPAs (static output)
    case react
    case vue
    case svelte

    /// Whether this is a PHP backend framework
    var isPHP: Bool { self == .laravel || self == .symfony }

    /// Whether this is a SPA/JavaScript framework
    var isSPA: Bool { !isPHP }

    /// Default dev server port for SPA frameworks
    var defaultDevPort: Int? {
        switch self {
        case .laravel, .symfony: return nil
        case .nextjs, .nuxt: return 3000
        case .sveltekit, .react, .vue, .svelte: return 5173
        }
    }

    /// Default build output folder (relative to project root)
    var defaultBuildPath: String? {
        switch self {
        case .laravel, .symfony: return nil
        case .nextjs: return "out"
        case .nuxt: return ".output/public"
        case .sveltekit: return "build"
        case .react, .vue, .svelte: return "dist"
        }
    }

    /// Whether this framework can serve static files without a server
    var supportsStaticExport: Bool { defaultBuildPath != nil }

    /// Display name for UI
    var displayName: String {
        switch self {
        case .laravel: return "Laravel"
        case .symfony: return "Symfony"
        case .nextjs: return "Next.js"
        case .nuxt: return "Nuxt"
        case .sveltekit: return "SvelteKit"
        case .react: return "React"
        case .vue: return "Vue"
        case .svelte: return "Svelte"
        }
    }

    /// Asset name for icon in Assets.xcassets
    var assetName: String {
        switch self {
        case .laravel: return "laravel"
        case .symfony: return "symfony"
        case .nextjs: return "nextdotjs"
        case .nuxt: return "nuxt"
        case .sveltekit: return "svelte"
        case .react: return "react"
        case .vue: return "vuedotjs"
        case .svelte: return "svelte"
        }
    }
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

    /// Cleartext sharing password for display (nil = no protection)
    var sharingPassword: String?

    /// Bcrypt hash of sharing password for Caddy basicauth (nil = no protection)
    var sharingPasswordHash: String?

    /// Dev server port for SPA projects (e.g., 5173 for Vite, 3000 for Next.js)
    /// When set, Caddy uses reverse_proxy instead of php_fastcgi
    var devServerPort: Int?

    var frameworkRawValue: String?

    var framework: ProjectFramework? {
        get { frameworkRawValue.flatMap { ProjectFramework(rawValue: $0) } }
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

    /// Whether this is a pure SPA project (no PHP backend)
    var isSPAProject: Bool {
        framework?.isSPA ?? false
    }

    /// Whether this is a PHP project (Laravel/Symfony)
    var isPHPProject: Bool {
        framework?.isPHP ?? false
    }

    /// Full path to static build output (derived from framework default)
    var fullStaticBuildPath: String? {
        guard let buildPath = framework?.defaultBuildPath else { return nil }
        return URL(fileURLWithPath: path)
            .appendingPathComponent(buildPath)
            .path
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

    /// Detect framework from composer.json (PHP) or package.json (SPA)
    /// Sets framework and devServerPort as appropriate
    /// Returns the detected framework, or nil if no framework detected
    @discardableResult
    func detectFramework() -> ProjectFramework? {
        let projectURL = URL(fileURLWithPath: path)
        let composerPath = projectURL.appendingPathComponent("composer.json")
        let packagePath = projectURL.appendingPathComponent("package.json")

        // Try PHP framework detection first (composer.json)
        if FileManager.default.fileExists(atPath: composerPath.path),
           let data = try? Data(contentsOf: composerPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let require = json["require"] as? [String: Any] {

            if require.keys.contains(where: { $0.hasPrefix("laravel/framework") }) {
                self.framework = .laravel
                return .laravel
            }

            if require.keys.contains(where: { $0.hasPrefix("symfony/framework-bundle") }) {
                self.framework = .symfony
                return .symfony
            }

            // Has composer.json but no recognized PHP framework
            // Don't check package.json (Laravel+Vite should NOT trigger SPA detection)
            return nil
        }

        // Try SPA framework detection (package.json, only if no composer.json)
        guard FileManager.default.fileExists(atPath: packagePath.path),
              let data = try? Data(contentsOf: packagePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let dependencies = (json["dependencies"] as? [String: Any]) ?? [:]
        let devDependencies = (json["devDependencies"] as? [String: Any]) ?? [:]
        let allDeps = Set(dependencies.keys).union(devDependencies.keys)

        // Detect SPA framework (order matters - more specific first)
        let detectedFramework: ProjectFramework?

        if allDeps.contains("next") {
            detectedFramework = .nextjs
        } else if allDeps.contains("nuxt") {
            detectedFramework = .nuxt
        } else if allDeps.contains("@sveltejs/kit") {
            detectedFramework = .sveltekit
        } else if allDeps.contains("react") || allDeps.contains("react-dom") {
            detectedFramework = .react
        } else if allDeps.contains("vue") {
            detectedFramework = .vue
        } else if allDeps.contains("svelte") && !allDeps.contains("@sveltejs/kit") {
            detectedFramework = .svelte
        } else {
            detectedFramework = nil
        }

        // Set framework and defaults if detected
        if let framework = detectedFramework {
            self.framework = framework
            self.devServerPort = framework.defaultDevPort
        }

        return detectedFramework
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
