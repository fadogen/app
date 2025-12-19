import Foundation
import Subprocess
import System

/// Merges YAML template files with yq (each service = standalone YAML file)
struct ComposeYAMLBuilder {
    let config: ProjectConfiguration
    private let yqPath: URL

    private var projectName: String {
        config.projectName.sanitizedHostname() ?? "app"
    }

    private var templatesDirectory: URL {
        FadogenPaths.dockerTemplatesDirectory
    }

    init(config: ProjectConfiguration, yqPath: URL? = nil) {
        self.config = config
        self.yqPath = yqPath ?? FadogenPaths.yqPath
    }

    // MARK: - Templates

    /// Order matters: base.yaml is last so volumes/networks/secrets appear at the end
    func templateFiles() -> [URL] {
        switch config.framework {
        case .laravel:
            return laravelTemplateFiles()
        case .symfony:
            return symfonyTemplateFiles()
        }
    }

    private func laravelTemplateFiles() -> [URL] {
        var files: [URL] = []
        let useSQLite = config.databaseType == .sqlite

        // 1. App service (always first)
        files.append(templatesDirectory.appendingPathComponent("laravel-app.yaml"))
        if config.octane {
            // Octane: custom command + healthcheck + port 8000
            files.append(templatesDirectory.appendingPathComponent("laravel-app-octane.yaml"))
        } else {
            // FrankenPHP classic mode: port 8080 (default)
            files.append(templatesDirectory.appendingPathComponent("shared-app-port.yaml"))
        }
        if useSQLite {
            files.append(templatesDirectory.appendingPathComponent("laravel-sqlite.yaml"))
        }
        if config.ssr {
            files.append(templatesDirectory.appendingPathComponent("laravel-ssr-env.yaml"))
        }

        // 2. Queue service (Horizon or native)
        if config.queueService == .horizon {
            files.append(templatesDirectory.appendingPathComponent("laravel-horizon.yaml"))
            if useSQLite {
                files.append(templatesDirectory.appendingPathComponent("laravel-sqlite-horizon.yaml"))
            }
        } else if config.queueService == .native {
            files.append(templatesDirectory.appendingPathComponent("laravel-queue.yaml"))
            if useSQLite {
                files.append(templatesDirectory.appendingPathComponent("laravel-sqlite-queue.yaml"))
            }
        }

        // 3. Scheduler
        if config.taskScheduler {
            files.append(templatesDirectory.appendingPathComponent("laravel-scheduler.yaml"))
            if useSQLite {
                files.append(templatesDirectory.appendingPathComponent("laravel-sqlite-scheduler.yaml"))
            }
        }

        // 4. Reverb (WebSocket)
        if config.reverb {
            files.append(templatesDirectory.appendingPathComponent("laravel-reverb.yaml"))
            if useSQLite {
                files.append(templatesDirectory.appendingPathComponent("laravel-sqlite-reverb.yaml"))
            }
        }

        // 5. SSR service
        if config.ssr {
            if config.jsPackageManager == .bun {
                files.append(templatesDirectory.appendingPathComponent("laravel-ssr-bun.yaml"))
            } else {
                files.append(templatesDirectory.appendingPathComponent("laravel-ssr-node.yaml"))
            }
        }

        // 6. Key-value store (Valkey or Redis)
        if needsValkey {
            files.append(templatesDirectory.appendingPathComponent("shared-valkey.yaml"))
        } else if needsRedis {
            files.append(templatesDirectory.appendingPathComponent("shared-redis.yaml"))
        }

        // 7. Database service
        switch config.databaseType {
        case .mariadb:
            files.append(templatesDirectory.appendingPathComponent("shared-mariadb.yaml"))
        case .mysql:
            files.append(templatesDirectory.appendingPathComponent("shared-mysql.yaml"))
        case .postgresql:
            files.append(templatesDirectory.appendingPathComponent("shared-pgsql.yaml"))
        case .sqlite:
            break // No service needed, volume already added via laravel-sqlite.yaml
        }

        // 8. Backup service
        files.append(templatesDirectory.appendingPathComponent("shared-backup.yaml"))

        // 9. Base infrastructure (last so volumes/networks/secrets appear at end)
        files.append(templatesDirectory.appendingPathComponent("laravel-base.yaml"))

        return files
    }

    private func symfonyTemplateFiles() -> [URL] {
        var files: [URL] = []
        let useSQLite = config.databaseType == .sqlite

        // 1. App service
        files.append(templatesDirectory.appendingPathComponent("symfony-app.yaml"))
        files.append(templatesDirectory.appendingPathComponent("shared-app-port.yaml"))
        if useSQLite {
            files.append(templatesDirectory.appendingPathComponent("symfony-sqlite.yaml"))
        }

        // 2. Database service
        switch config.databaseType {
        case .mariadb:
            files.append(templatesDirectory.appendingPathComponent("shared-mariadb.yaml"))
        case .mysql:
            files.append(templatesDirectory.appendingPathComponent("shared-mysql.yaml"))
        case .postgresql:
            files.append(templatesDirectory.appendingPathComponent("shared-pgsql.yaml"))
        case .sqlite:
            break // No service needed, volume already added via symfony-sqlite.yaml
        }

        // 3. Backup service
        files.append(templatesDirectory.appendingPathComponent("shared-backup.yaml"))

        // 4. Base infrastructure (last so volumes/networks/secrets appear at end)
        files.append(templatesDirectory.appendingPathComponent("symfony-base.yaml"))

        return files
    }

    /// TLS certresolver labels for direct exposure (non-tunnel) mode
    func certresolverFiles() -> [URL] {
        var files: [URL] = []

        // App certresolver (always needed)
        files.append(templatesDirectory.appendingPathComponent("shared-certresolver.yaml"))

        // Reverb certresolver (only if Reverb is configured)
        if config.reverb {
            files.append(templatesDirectory.appendingPathComponent("shared-certresolver-reverb.yaml"))
        }

        return files
    }

    // MARK: - Generation

    func generate() async throws -> String {
        let files = templateFiles()

        // Concatenate all template files into a multi-document YAML stream
        // Each file starts with --- (document separator), enabling yq to
        // process them as separate documents and deep merge with ireduce
        var concatenatedYAML = ""
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                throw ComposeYAMLError.templateNotFound(file.lastPathComponent)
            }
            concatenatedYAML += content
            if !concatenatedYAML.hasSuffix("\n") {
                concatenatedYAML += "\n"
            }
        }

        // Use yq to merge YAML documents:
        // - eval-all processes all documents in the stream
        // - ireduce with *+ does deep merge (maps merged, arrays appended)
        let result = try await run(
            .path(FilePath(yqPath.path)),
            arguments: ["eval-all", ". as $item ireduce ({}; . *+ $item)"],
            input: .string(concatenatedYAML),
            output: .string(limit: 64 * 1024),
            error: .string(limit: 4 * 1024)
        )

        guard result.terminationStatus.isSuccess else {
            let stderr = result.standardError ?? "Unknown error"
            throw ComposeYAMLError.yqFailed(stderr)
        }

        guard var yaml = result.standardOutput else {
            throw ComposeYAMLError.emptyOutput
        }

        // Substitute placeholders
        yaml = yaml.replacingOccurrences(of: "{{PROJECT_NAME}}", with: projectName)
        yaml = substituteVersionPlaceholders(yaml)

        return yaml
    }

    private func substituteVersionPlaceholders(_ yaml: String) -> String {
        var result = yaml

        // Database versions (with fallback defaults for safety)
        if let version = config.postgresVersion {
            result = result.replacingOccurrences(of: "{{POSTGRES_VERSION}}", with: version)
        } else {
            result = result.replacingOccurrences(of: "{{POSTGRES_VERSION}}", with: "18")
        }

        if let version = config.mysqlVersion {
            result = result.replacingOccurrences(of: "{{MYSQL_VERSION}}", with: version)
        } else {
            result = result.replacingOccurrences(of: "{{MYSQL_VERSION}}", with: "9.0")
        }

        if let version = config.mariadbVersion {
            result = result.replacingOccurrences(of: "{{MARIADB_VERSION}}", with: version)
        } else {
            result = result.replacingOccurrences(of: "{{MARIADB_VERSION}}", with: "11")
        }

        // Cache versions
        if let version = config.valkeyVersion {
            result = result.replacingOccurrences(of: "{{VALKEY_VERSION}}", with: version)
        } else {
            result = result.replacingOccurrences(of: "{{VALKEY_VERSION}}", with: "9")
        }

        if let version = config.redisVersion {
            result = result.replacingOccurrences(of: "{{REDIS_VERSION}}", with: version)
        } else {
            result = result.replacingOccurrences(of: "{{REDIS_VERSION}}", with: "8")
        }

        return result
    }

    func generateCertresolver() async throws -> String {
        let files = certresolverFiles()

        // Concatenate overlay template files
        var concatenatedYAML = ""
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                throw ComposeYAMLError.templateNotFound(file.lastPathComponent)
            }
            concatenatedYAML += content
            if !concatenatedYAML.hasSuffix("\n") {
                concatenatedYAML += "\n"
            }
        }

        // Use yq to merge overlay documents
        let result = try await run(
            .path(FilePath(yqPath.path)),
            arguments: ["eval-all", ". as $item ireduce ({}; . *+ $item)"],
            input: .string(concatenatedYAML),
            output: .string(limit: 64 * 1024),
            error: .string(limit: 4 * 1024)
        )

        guard result.terminationStatus.isSuccess else {
            let stderr = result.standardError ?? "Unknown error"
            throw ComposeYAMLError.yqFailed(stderr)
        }

        guard var yaml = result.standardOutput else {
            throw ComposeYAMLError.emptyOutput
        }

        // Substitute placeholders
        yaml = yaml.replacingOccurrences(of: "{{PROJECT_NAME}}", with: projectName)

        return yaml
    }

    // MARK: - Private

    private var needsValkey: Bool {
        config.queueBackend == .valkey || config.cacheService == .valkey
    }

    private var needsRedis: Bool {
        config.queueBackend == .redis || config.cacheService == .redis
    }
}

// MARK: - Errors

enum ComposeYAMLError: Error, LocalizedError {
    case templateNotFound(String)
    case yqFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .templateNotFound(let name):
            return "Template file not found: \(name)"
        case .yqFailed(let stderr):
            return "yq merge failed: \(stderr)"
        case .emptyOutput:
            return "yq produced empty output"
        }
    }
}
