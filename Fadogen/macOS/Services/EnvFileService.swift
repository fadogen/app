import Foundation
import Subprocess
import System

final class EnvFileService {

    // MARK: - Errors

    enum EnvFileError: Error, LocalizedError {
        case fileNotFound
        case invalidSiteURL
        case encodingFailed
        case keyGenerationFailed(String)
        case secretGenerationFailed(String)
        case vendorNotInstalled
        case distFileNotFound

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return "Environment file not found"
            case .invalidSiteURL:
                return "Invalid project URL"
            case .encodingFailed:
                return "Failed to encode environment file"
            case .keyGenerationFailed(let details):
                return "Failed to generate APP_KEY: \(details)"
            case .secretGenerationFailed(let details):
                return "Failed to generate APP_SECRET: \(details)"
            case .vendorNotInstalled:
                return "Composer dependencies not installed. Run 'composer install' in the project directory first."
            case .distFileNotFound:
                return ".env.production.dist file not found"
            }
        }
    }

    // MARK: - Public

    func createProductionEnvFile(at projectURL: URL, domain: String, phpBinaryPath: URL) async throws -> URL {
        // Ensure file exists (creates from .dist or template if needed)
        let envProductionURL = try ensureEnvProductionExists(at: projectURL)

        // Update domain
        try updateEnvFile(at: envProductionURL, updates: [
            "APP_HOST": "\(domain)",
            "APP_URL": "\"https://${APP_HOST}\""
        ])

        // Generate missing secrets (including APP_KEY via artisan)
        try await generateMissingSecrets(at: envProductionURL, projectURL: projectURL, phpBinaryPath: phpBinaryPath)

        return envProductionURL
    }

    func createSymfonyProductionEnvContent(
        at projectURL: URL,
        domain: String,
        additionalSections: [String] = []
    ) async throws -> String {
        let envDistURL = projectURL.appendingPathComponent(".env.production.dist")

        // Symfony MUST have .env.production.dist (created during project generation)
        guard FileManager.default.fileExists(atPath: envDistURL.path) else {
            throw EnvFileError.distFileNotFound
        }

        // Read template content
        var content = try String(contentsOf: envDistURL, encoding: .utf8)

        // Update domain
        content = updateEnvContent(content, updates: [
            "APP_HOST": domain
        ])

        // Generate missing secrets in memory
        content = try await generateSymfonyMissingSecrets(content: content, projectURL: projectURL)

        // Append additional sections (backup config, DNS provider, etc.)
        for section in additionalSections where !section.isEmpty {
            content += "\n" + section
        }

        return content
    }

    func updateEnvFile(at url: URL, updates: [String: String]) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EnvFileError.fileNotFound
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        // Track which keys have been updated
        var updatedKeys = Set<String>()

        let updatedLines = lines.map { line -> String in
            // Skip empty lines and comments
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                return line
            }

            // Parse KEY=VALUE
            guard let equalsIndex = line.firstIndex(of: "=") else {
                return line
            }

            let key = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespaces)

            // Replace if key matches
            if let newValue = updates[key] {
                updatedKeys.insert(key)
                return "\(key)=\(newValue)"
            }

            return line
        }

        // Find which keys are missing and need to be added
        let missingKeys = Set(updates.keys).subtracting(updatedKeys)

        // Add missing keys at appropriate locations
        var finalLines = updatedLines
        if !missingKeys.isEmpty {
            // Special handling for APP_HOST: must be inserted before APP_URL
            if missingKeys.contains("APP_HOST"), let appHostValue = updates["APP_HOST"] {
                if let appURLIndex = finalLines.firstIndex(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("APP_URL=")
                }) {
                    // Insert APP_HOST just before APP_URL
                    finalLines.insert("APP_HOST=\(appHostValue)", at: appURLIndex)
                } else if let debugIndex = finalLines.firstIndex(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("APP_DEBUG=")
                }) {
                    // Fallback: insert after APP_DEBUG
                    let insertIndex = finalLines.index(after: debugIndex)
                    finalLines.insert("APP_HOST=\(appHostValue)", at: insertIndex)
                }
            }

            // Handle remaining missing keys (excluding APP_HOST which was already handled)
            let remainingMissingKeys = missingKeys.subtracting(["APP_HOST"])
            if !remainingMissingKeys.isEmpty {
                // Find APP_HOST or APP_DEBUG as insertion point
                let insertionIndex: Array<String>.Index?
                if let appHostIndex = finalLines.firstIndex(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("APP_HOST=")
                }) {
                    insertionIndex = finalLines.index(after: appHostIndex)
                } else if let debugIndex = finalLines.firstIndex(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("APP_DEBUG=")
                }) {
                    insertionIndex = finalLines.index(after: debugIndex)
                } else {
                    insertionIndex = nil
                }

                if let index = insertionIndex {
                    // Insert remaining keys at the insertion point
                    for key in remainingMissingKeys.sorted() {
                        if let value = updates[key] {
                            finalLines.insert("\(key)=\(value)", at: index)
                        }
                    }
                }
            }
        }

        try finalLines.joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    func readEnvFileContent(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EnvFileError.fileNotFound
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func readEnvFileBase64(at url: URL) throws -> String {
        try encodeContentBase64(try readEnvFileContent(at: url))
    }

    func encodeContentBase64(_ content: String) throws -> String {
        guard let data = content.data(using: .utf8) else {
            throw EnvFileError.encodingFailed
        }
        return data.base64EncodedString()
    }

    // MARK: - Backup

    struct BackupConfig {
        let comment: String
        let vars: [(key: String, value: String)]
    }

    func cloudflareBackupConfig(integration: Integration, accountId: String, projectSlug: String) -> BackupConfig {
        BackupConfig(
            comment: "# Backup Configuration (Cloudflare R2)",
            vars: [
                ("BACKUP_S3_BUCKET", "fadogen-backups"),
                ("BACKUP_S3_PATH", projectSlug),
                ("BACKUP_AWS_ACCESS_KEY_ID", integration.credentials.r2AccessKeyId ?? ""),
                ("BACKUP_AWS_SECRET_ACCESS_KEY", integration.credentials.r2SecretAccessKey ?? ""),
                ("BACKUP_AWS_ENDPOINT", "\(accountId).r2.cloudflarestorage.com"),
                ("BACKUP_RETENTION_DAYS", "7")
            ]
        )
    }

    func scalewayBackupConfig(integration: Integration, projectSlug: String) -> BackupConfig {
        let region = integration.credentials.scalewayRegion ?? "fr-par"
        return BackupConfig(
            comment: "# Backup Configuration (Scaleway Object Storage)",
            vars: [
                ("BACKUP_S3_BUCKET", "fadogen-backups"),
                ("BACKUP_S3_PATH", projectSlug),
                ("BACKUP_AWS_ACCESS_KEY_ID", integration.credentials.accessKey ?? ""),
                ("BACKUP_AWS_SECRET_ACCESS_KEY", integration.credentials.secretKey ?? ""),
                ("BACKUP_AWS_ENDPOINT", "s3.\(region).scw.cloud"),
                ("BACKUP_AWS_DEFAULT_REGION", region),
                ("BACKUP_RETENTION_DAYS", "7")
            ]
        )
    }

    func dropboxBackupConfig(integration: Integration, projectSlug: String) -> BackupConfig {
        BackupConfig(
            comment: "# Backup Configuration (Dropbox)",
            vars: [
                ("BACKUP_DROPBOX_APP_KEY", integration.credentials.dropboxAppKey ?? ""),
                ("BACKUP_DROPBOX_APP_SECRET", integration.credentials.dropboxAppSecret ?? ""),
                ("BACKUP_DROPBOX_REFRESH_TOKEN", integration.credentials.dropboxRefreshToken ?? ""),
                ("BACKUP_DROPBOX_REMOTE_PATH", "/fadogen-backups/\(projectSlug)")
            ]
        )
    }

    func backupConfigToSection(_ config: BackupConfig) -> String {
        var lines = [config.comment]
        for (key, value) in config.vars {
            lines.append("\(key)=\(value)")
        }
        return lines.joined(separator: "\n")
    }

    func writeBackupConfig(_ config: BackupConfig, to projectURL: URL) throws {
        try writeBackupVariables(
            to: projectURL,
            backupVars: config.vars,
            sectionComment: config.comment
        )
    }

    func addCloudflareBackupVariables(
        to projectURL: URL,
        integration: Integration,
        accountId: String,
        projectSlug: String
    ) throws {
        let config = cloudflareBackupConfig(integration: integration, accountId: accountId, projectSlug: projectSlug)
        try writeBackupConfig(config, to: projectURL)
    }

    func addScalewayBackupVariables(
        to projectURL: URL,
        integration: Integration,
        projectSlug: String
    ) throws {
        let config = scalewayBackupConfig(integration: integration, projectSlug: projectSlug)
        try writeBackupConfig(config, to: projectURL)
    }

    func removeAllBackupVariables(from projectURL: URL) throws {
        let envProductionURL = projectURL.appendingPathComponent(".env.production")

        guard FileManager.default.fileExists(atPath: envProductionURL.path) else {
            return // Nothing to remove
        }

        let content = try String(contentsOf: envProductionURL, encoding: .utf8)
        var lines = content.components(separatedBy: .newlines)

        // Remove all backup variables and section comments
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Remove backup section comments
            if trimmed.hasPrefix("# Backup Configuration") { return true }

            // Remove any BACKUP_* variable
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equalsIndex])
                return key.hasPrefix("BACKUP_")
            }
            return false
        }

        // Clean trailing empty lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }

        try lines.joined(separator: "\n")
            .write(to: envProductionURL, atomically: true, encoding: .utf8)
    }

    // MARK: - DNS Provider

    func generateDNSProviderSection(provider: String) -> String {
        """
        # Traefik Configuration
        DNS_PROVIDER=\(provider)
        """
    }

    func addDNSProviderVariable(to projectURL: URL, provider: String) throws {
        let envProductionURL = try ensureEnvProductionExists(at: projectURL)

        let content = try String(contentsOf: envProductionURL, encoding: .utf8)
        var lines = content.components(separatedBy: .newlines)

        // Remove existing DNS_PROVIDER and section comment
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# Traefik Configuration" { return true }
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equalsIndex])
                return key == "DNS_PROVIDER"
            }
            return false
        }

        // Clean trailing empty lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }

        // Append Traefik section at end
        lines.append("")
        lines.append("# Traefik Configuration")
        lines.append("DNS_PROVIDER=\(provider)")

        try lines.joined(separator: "\n")
            .write(to: envProductionURL, atomically: true, encoding: .utf8)
    }

    func addDropboxBackupVariables(
        to projectURL: URL,
        integration: Integration,
        projectSlug: String
    ) throws {
        let config = dropboxBackupConfig(integration: integration, projectSlug: projectSlug)
        try writeBackupConfig(config, to: projectURL)
    }

    private func writeBackupVariables(
        to projectURL: URL,
        backupVars: [(key: String, value: String)],
        sectionComment: String
    ) throws {
        let envProductionURL = try ensureEnvProductionExists(at: projectURL)

        let content = try String(contentsOf: envProductionURL, encoding: .utf8)
        var lines = content.components(separatedBy: .newlines)

        // Remove ALL existing backup variables and comments (handles provider changes)
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Remove backup section comments
            if trimmed.hasPrefix("# Backup Configuration") { return true }

            // Remove any BACKUP_* variable
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equalsIndex])
                return key.hasPrefix("BACKUP_")
            }
            return false
        }

        // Clean trailing empty lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }

        // Append backup section: 1 empty line + comment + variables (each on its own line)
        lines.append("")
        lines.append(sectionComment)
        for (key, value) in backupVars {
            lines.append("\(key)=\(value)")
        }

        try lines.joined(separator: "\n")
            .write(to: envProductionURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Secret Generation

    private func generateMissingSecrets(at url: URL, projectURL: URL, phpBinaryPath: URL) async throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        var updates: [String: String] = [:]

        let projectName = projectURL.lastPathComponent

        // APP_KEY: Generate via artisan if empty
        if needsGeneration(key: "APP_KEY", in: content) {
            try await generateAppKey(at: projectURL, phpBinaryPath: phpBinaryPath)
        }

        // Database credentials
        if needsGeneration(key: "DB_DATABASE", in: content) {
            updates["DB_DATABASE"] = SecretGenerator.generateDatabaseName(from: projectName)
        }
        if needsGeneration(key: "DB_USERNAME", in: content) {
            updates["DB_USERNAME"] = SecretGenerator.generateDatabaseUsername(from: projectName)
        }
        if needsGeneration(key: "DB_PASSWORD", in: content) {
            updates["DB_PASSWORD"] = SecretGenerator.generatePassword()
        }

        // Redis password (treat "null" as needing generation)
        if needsGeneration(key: "REDIS_PASSWORD", in: content, emptyValues: ["", "null"]) {
            updates["REDIS_PASSWORD"] = SecretGenerator.generatePassword()
        }

        // Reverb credentials (only if keys exist in file)
        // Treat dev placeholders as needing generation
        if needsGeneration(key: "REVERB_APP_ID", in: content, emptyValues: ["", "1001", "142177"]) {
            updates["REVERB_APP_ID"] = SecretGenerator.generateReverbAppID()
        }
        if needsGeneration(key: "REVERB_APP_KEY", in: content, emptyValues: ["", "laravel-fadogen", "bqoorx2zgvcwmwhk2xor"]) {
            updates["REVERB_APP_KEY"] = SecretGenerator.generateReverbAppKey()
        }
        if needsGeneration(key: "REVERB_APP_SECRET", in: content, emptyValues: ["", "secret", "gr9muyi9qnm4pbm3bblx"]) {
            updates["REVERB_APP_SECRET"] = SecretGenerator.generateReverbAppSecret()
        }

        // Apply updates if any
        if !updates.isEmpty {
            try updateEnvFile(at: url, updates: updates)
        }
    }

    private func generateAppKey(at projectURL: URL, phpBinaryPath: URL) async throws {
        // Check vendor directory exists (composer install required)
        let vendorPath = projectURL.appendingPathComponent("vendor").path
        guard FileManager.default.fileExists(atPath: vendorPath) else {
            throw EnvFileError.vendorNotInstalled
        }

        let artisanPath = projectURL.appendingPathComponent("artisan").path

        let result = try await run(
            .path(FilePath(phpBinaryPath.path)),
            arguments: [artisanPath, "key:generate", "--env=production", "--no-interaction"],
            workingDirectory: FilePath(projectURL.path),
            output: .string(limit: 4 * 1024),
            error: .string(limit: 4 * 1024)
        )

        guard result.terminationStatus.isSuccess else {
            let stderr = result.standardError ?? "Unknown error"
            throw EnvFileError.keyGenerationFailed(stderr)
        }
    }

    private func needsGeneration(key: String, in content: String, emptyValues: [String] = [""]) -> Bool {
        // Find the key in content
        let pattern = "(?m)^\(NSRegularExpression.escapedPattern(for: key))=(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let valueRange = Range(match.range(at: 1), in: content) else {
            return false // Key not found in file
        }

        let value = String(content[valueRange]).trimmingCharacters(in: .whitespaces)
        return emptyValues.contains(value)
    }

    // MARK: - Symfony

    private func generateSymfonyMissingSecrets(content: String, projectURL: URL) async throws -> String {
        var result = content
        var updates: [String: String] = [:]
        let projectName = projectURL.lastPathComponent

        // APP_SECRET: Generate with openssl if empty
        if needsGeneration(key: "APP_SECRET", in: content) {
            updates["APP_SECRET"] = try await generateSymfonyAppSecret()
        }

        // Database credentials (same as Laravel)
        if needsGeneration(key: "DB_DATABASE", in: content) {
            updates["DB_DATABASE"] = SecretGenerator.generateDatabaseName(from: projectName)
        }
        if needsGeneration(key: "DB_USERNAME", in: content) {
            updates["DB_USERNAME"] = SecretGenerator.generateDatabaseUsername(from: projectName)
        }
        if needsGeneration(key: "DB_PASSWORD", in: content) {
            updates["DB_PASSWORD"] = SecretGenerator.generatePassword()
        }

        // Apply updates in memory
        if !updates.isEmpty {
            result = updateEnvContent(result, updates: updates)
        }

        return result
    }

    private func generateSymfonyAppSecret() async throws -> String {
        let result = try await run(
            .path(FilePath("/usr/bin/openssl")),
            arguments: ["rand", "-hex", "32"],
            output: .string(limit: 1024),
            error: .string(limit: 1024)
        )

        guard result.terminationStatus.isSuccess,
              let secret = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            let stderr = result.standardError ?? "Unknown error"
            throw EnvFileError.secretGenerationFailed(stderr)
        }

        return secret
    }

    private func updateEnvContent(_ content: String, updates: [String: String]) -> String {
        let lines = content.components(separatedBy: .newlines)

        // Track which keys have been updated
        var updatedKeys = Set<String>()

        var updatedLines = lines.map { line -> String in
            // Skip empty lines and comments
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                return line
            }

            // Parse KEY=VALUE
            guard let equalsIndex = line.firstIndex(of: "=") else {
                return line
            }

            let key = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespaces)

            // Replace if key matches
            if let newValue = updates[key] {
                updatedKeys.insert(key)
                return "\(key)=\(newValue)"
            }

            return line
        }

        // Find which keys are missing and need to be added
        let missingKeys = Set(updates.keys).subtracting(updatedKeys)

        // Add missing keys at appropriate locations
        if !missingKeys.isEmpty {
            // Find APP_ENV or first line as insertion point
            let insertionIndex: Array<String>.Index
            if let appEnvIndex = updatedLines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("APP_ENV=")
            }) {
                insertionIndex = updatedLines.index(after: appEnvIndex)
            } else {
                insertionIndex = updatedLines.startIndex
            }

            // Insert remaining keys at the insertion point
            for key in missingKeys.sorted().reversed() {
                if let value = updates[key] {
                    updatedLines.insert("\(key)=\(value)", at: insertionIndex)
                }
            }
        }

        return updatedLines.joined(separator: "\n")
    }

    // MARK: - Private

    @discardableResult
    private func ensureEnvProductionExists(at projectURL: URL) throws -> URL {
        let envProductionURL = projectURL.appendingPathComponent(".env.production")
        let envDistURL = projectURL.appendingPathComponent(".env.production.dist")

        guard !FileManager.default.fileExists(atPath: envProductionURL.path) else {
            return envProductionURL
        }

        // Create from .dist if available, otherwise use fallback template
        if FileManager.default.fileExists(atPath: envDistURL.path) {
            try FileManager.default.copyItem(at: envDistURL, to: envProductionURL)
        } else {
            let template = productionTemplate(domain: "")
            try template.write(to: envProductionURL, atomically: true, encoding: .utf8)
        }

        return envProductionURL
    }

    private func productionTemplate(domain: String) -> String {
        """
        APP_NAME=Laravel
        APP_ENV=production
        APP_KEY=
        APP_DEBUG=false
        APP_HOST=\(domain)
        APP_URL="https://${APP_HOST}"

        APP_LOCALE=en
        APP_FALLBACK_LOCALE=en
        APP_FAKER_LOCALE=en_US

        APP_MAINTENANCE_DRIVER=file
        # APP_MAINTENANCE_STORE=database

        # PHP_CLI_SERVER_WORKERS=4

        BCRYPT_ROUNDS=12

        LOG_CHANNEL=daily
        LOG_STACK=single
        LOG_DEPRECATIONS_CHANNEL=null
        LOG_LEVEL=debug

        DB_CONNECTION=pgsql
        DB_HOST=127.0.0.1
        DB_PORT=5432
        DB_DATABASE=
        DB_USERNAME=
        DB_PASSWORD=

        SESSION_DRIVER=redis
        SESSION_LIFETIME=120
        SESSION_ENCRYPT=false
        SESSION_PATH=/
        SESSION_DOMAIN=null

        BROADCAST_CONNECTION=log
        FILESYSTEM_DISK=local
        QUEUE_CONNECTION=redis

        CACHE_STORE=redis
        # CACHE_PREFIX=

        MEMCACHED_HOST=127.0.0.1

        REDIS_CLIENT=phpredis
        REDIS_HOST=127.0.0.1
        REDIS_PASSWORD=null
        REDIS_PORT=6379

        MAIL_MAILER=log
        MAIL_SCHEME=null
        MAIL_HOST=127.0.0.1
        MAIL_PORT=2525
        MAIL_USERNAME=null
        MAIL_PASSWORD=null
        MAIL_FROM_ADDRESS="hello@example.com"
        MAIL_FROM_NAME="${APP_NAME}"

        AWS_ACCESS_KEY_ID=
        AWS_SECRET_ACCESS_KEY=
        AWS_DEFAULT_REGION=us-east-1
        AWS_BUCKET=
        AWS_USE_PATH_STYLE_ENDPOINT=false

        VITE_APP_NAME="${APP_NAME}"

        REVERB_APP_ID=142177
        REVERB_APP_KEY=bqoorx2zgvcwmwhk2xor
        REVERB_APP_SECRET=gr9muyi9qnm4pbm3bblx
        REVERB_HOST="${APP_HOST}"
        REVERB_PORT=8080
        REVERB_SCHEME=http

        VITE_REVERB_APP_KEY="${REVERB_APP_KEY}"
        VITE_REVERB_HOST="${REVERB_HOST}"
        VITE_REVERB_PORT="${REVERB_PORT}"
        VITE_REVERB_SCHEME="${REVERB_SCHEME}"
        """
    }
}
