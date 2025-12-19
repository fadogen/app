import Foundation
import OSLog

nonisolated enum PHPConfigService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "php-config")

    static func ensureDirectories() throws {
        let dirs = [
            FadogenPaths.logsDirectory,
            FadogenPaths.socketsDirectory,
            FadogenPaths.configDirectory
        ]

        for dir in dirs {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        logger.debug("Ensured required directories exist")
    }

    static func ensureCACert() throws {
        let destPath = FadogenPaths.configDirectory
            .appendingPathComponent("cacert.pem")

        // Skip if already exists
        guard !FileManager.default.fileExists(atPath: destPath.path) else {
            logger.debug("CA certificate already exists, skipping")
            return
        }

        // Find bundled certificate (named cacert-mozilla.pem in Resources)
        guard let bundledCACert = Bundle.main.path(
            forResource: "cacert-mozilla",
            ofType: "pem"
        ) else {
            throw PHPConfigError.caCertNotFound
        }

        // Copy and rename: cacert-mozilla.pem → cacert.pem
        try FileManager.default.copyItem(
            atPath: bundledCACert,
            toPath: destPath.path
        )

        logger.info("Copied CA certificate to \(destPath.path)")
    }

    // Adds Caddy's root CA to cacert.pem for .localhost HTTPS
    static func ensureCaddyCACert() throws -> Bool {
        let caddyRootPath = FadogenPaths.caddyDataDirectory
            .appendingPathComponent("pki/authorities/local/root.crt")
        let cacertPath = FadogenPaths.configDirectory
            .appendingPathComponent("cacert.pem")

        // 1. Verify Caddy root CA exists
        guard FileManager.default.fileExists(atPath: caddyRootPath.path) else {
            logger.warning("Caddy root CA not found at \(caddyRootPath.path)")
            return false
        }

        // 2. Ensure cacert.pem exists (create if missing)
        if !FileManager.default.fileExists(atPath: cacertPath.path) {
            logger.info("cacert.pem not found, creating it...")
            try ensureCACert()
        }

        // 3. Read cacert.pem and remove any existing Caddy CA
        var cacertContent = try String(contentsOf: cacertPath, encoding: .utf8)

        // Remove old Caddy CA section (from comment to end of file)
        if let range = cacertContent.range(of: "\n# Caddy Local Authority - Added for localhost HTTPS\n") {
            cacertContent = String(cacertContent[..<range.lowerBound])
        }

        // 4. Read current Caddy root CA
        let caddyRoot = try String(contentsOf: caddyRootPath, encoding: .utf8)

        // 5. Append root CA to cacert.pem
        // Note: Only root CA is needed - intermediate is sent by server during TLS handshake
        let updatedContent = """
        \(cacertContent)

        # Caddy Local Authority - Added for localhost HTTPS
        \(caddyRoot)
        """

        try updatedContent.write(to: cacertPath, atomically: true, encoding: .utf8)
        logger.info("Updated Caddy CA in cacert.pem")

        return true
    }

    static func generatePHPIni(major: String) throws {
        let configDir = FadogenPaths.configPath(for: major)
        let iniFile = configDir.appendingPathComponent("php.ini")

        // Skip if already exists
        guard !FileManager.default.fileExists(atPath: iniFile.path) else {
            logger.debug("php.ini for \(major) already exists, skipping")
            return
        }

        let caCertPath = FadogenPaths.configDirectory
            .appendingPathComponent("cacert.pem").path
        let xdebugPath = configDir.appendingPathComponent("xdebug.so").path

        var template = """
        ; === SSL Certificates (SHARED) ===
        curl.cainfo=\(caCertPath)
        openssl.cafile=\(caCertPath)

        ; === Stability ===
        pcre.jit=0

        ; === Performance ===
        output_buffering=4096

        ; === Development ===
        display_errors=On
        error_reporting=E_ALL

        ; === Timezone ===
        date.timezone=UTC

        ; === Limits ===
        upload_max_filesize=64M
        post_max_size=64M
        memory_limit=256M
        """

        // Add Xdebug configuration if extension exists
        if FileManager.default.fileExists(atPath: xdebugPath) {
            template += """


            ; === Xdebug (Debug & Development) ===
            zend_extension=\(xdebugPath)
            xdebug.mode=debug,develop
            xdebug.start_with_request=trigger
            """
        }

        try template.write(to: iniFile, atomically: true, encoding: .utf8)
        logger.info("Generated php.ini for PHP \(major)")
    }

    static func generateFPMConfig(major: String) throws {
        let configDir = FadogenPaths.configPath(for: major)
        let fpmFile = configDir.appendingPathComponent("php-fpm.conf")

        // Skip if already exists
        guard !FileManager.default.fileExists(atPath: fpmFile.path) else {
            logger.debug("php-fpm.conf for \(major) already exists, skipping")
            return
        }

        let versionNumber = major.replacingOccurrences(of: ".", with: "")

        let template = """
        [global]
        daemonize = no
        error_log = /dev/stderr
        log_level = notice

        [fadogen_\(versionNumber)]
        listen = \(FadogenPaths.socketsDirectory.path)/php-fpm-\(versionNumber).sock
        listen.mode = 0600

        pm = dynamic
        pm.max_children = 5
        pm.start_servers = 2
        pm.min_spare_servers = 1
        pm.max_spare_servers = 3
        pm.max_requests = 500

        catch_workers_output = yes
        request_terminate_timeout = 30s
        """

        try template.write(to: fpmFile, atomically: true, encoding: .utf8)
        logger.info("Generated php-fpm.conf for PHP \(major)")
    }
}

// MARK: - Errors

enum PHPConfigError: LocalizedError {
    case caCertNotFound

    var errorDescription: String? {
        switch self {
        case .caCertNotFound:
            return "Bundled CA certificate (cacert-mozilla.pem) not found in application resources"
        }
    }
}
