import Foundation

/// Centralized path configuration for Fadogen
/// All filesystem paths are computed from base directory
/// Marked nonisolated to allow access from SwiftData models (which are nonisolated)
/// Safe because FileManager operations used here are thread-safe
nonisolated enum FadogenPaths {

    /// Base directory: ~/Library/Application Support/Fadogen (Release) or Fadogen-Dev (Debug)
    static var baseDirectory: URL {
        #if DEBUG
        let folderName = "Fadogen-Dev"
        #else
        let folderName = "Fadogen"
        #endif
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName)
    }

    /// PID files directory: /tmp/app.fadogen/pids
    /// Stores process IDs for orphan cleanup (auto-wiped on macOS reboot)
    static var pidFilesDirectory: URL {
        URL(fileURLWithPath: "/tmp/app.fadogen/pids")
    }

    /// Shared binaries directory: /Users/Shared/Fadogen
    /// Used for services (databases, caches) that can be shared between users
    static var sharedBinariesDirectory: URL {
        URL(fileURLWithPath: "/Users/Shared/Fadogen")
    }

    /// Data directory: ~/Library/Application Support/Fadogen/data
    /// Used for service data directories (databases, caches)
    static var dataDirectory: URL {
        baseDirectory.appendingPathComponent("data")
    }

    /// Binary directory: ~/Library/Application Support/Fadogen/bin
    static var binDirectory: URL {
        baseDirectory.appendingPathComponent("bin")
    }

    /// Logs directory: ~/Library/Application Support/Fadogen/logs
    static var logsDirectory: URL {
        baseDirectory.appendingPathComponent("logs")
    }

    /// Sockets directory: ~/Library/Application Support/Fadogen/sockets
    static var socketsDirectory: URL {
        baseDirectory.appendingPathComponent("sockets")
    }

    /// Scripts directory: ~/Library/Application Support/Fadogen/scripts
    static var scriptsDirectory: URL {
        baseDirectory.appendingPathComponent("scripts")
    }

    /// SSH directory: ~/Library/Application Support/Fadogen/ssh
    /// Used for isolated SSH configuration (known_hosts)
    static var sshDirectory: URL {
        baseDirectory.appendingPathComponent("ssh")
    }

    /// Known hosts file: ~/Library/Application Support/Fadogen/ssh/known_hosts
    /// Isolated from user's ~/.ssh/known_hosts to prevent system modification
    static var knownHostsPath: URL {
        sshDirectory.appendingPathComponent("known_hosts")
    }

    /// Config base directory: ~/Library/Application Support/Fadogen/config/php
    static var configDirectory: URL {
        baseDirectory
            .appendingPathComponent("config")
            .appendingPathComponent("php")
    }

    /// Caddy config directory: ~/Library/Application Support/Fadogen/config/caddy
    static var caddyConfigDirectory: URL {
        baseDirectory
            .appendingPathComponent("config")
            .appendingPathComponent("caddy")
    }

    /// Caddy data directory: ~/Library/Application Support/Fadogen/data/caddy
    /// Used for certificates, cache, and other Caddy data
    static var caddyDataDirectory: URL {
        dataDirectory.appendingPathComponent("caddy")
    }

    /// Caddy projects directory: ~/Library/Application Support/Fadogen/config/caddy/projects
    static var caddyProjectsDirectory: URL {
        caddyConfigDirectory.appendingPathComponent("projects")
    }

    /// Caddy binary path (bundled in app)
    /// Local web server for serving projects
    /// - Returns: URL like .../Contents/Resources/caddy
    static var caddyPath: URL {
        bundleResourcesDirectory.appendingPathComponent("caddy")
    }

    /// Reverb binary directory: /Users/Shared/Fadogen/reverb
    /// Contains the Laravel Reverb WebSocket server installation
    static var reverbBinaryPath: URL {
        sharedBinariesDirectory.appendingPathComponent("reverb")
    }

    /// Typesense binary directory: /Users/Shared/Fadogen/typesense
    /// Contains the Typesense search server binary
    static var typesenseBinaryPath: URL {
        sharedBinariesDirectory.appendingPathComponent("typesense")
    }

    /// Typesense data directory: ~/Library/Application Support/Fadogen/data/typesense
    /// Used for Typesense database files
    static var typesenseDataDirectory: URL {
        dataDirectory.appendingPathComponent("typesense")
    }

    /// Garage S3 binary directory: /Users/Shared/Fadogen/garage
    /// Contains the Garage S3 storage server binary
    static var garageBinaryPath: URL {
        sharedBinariesDirectory.appendingPathComponent("garage")
    }

    /// Garage data directory: ~/Library/Application Support/Fadogen/data/garage
    /// Used for Garage metadata and data blocks
    static var garageDataDirectory: URL {
        dataDirectory.appendingPathComponent("garage")
    }

    /// Garage config directory: ~/Library/Application Support/Fadogen/config/garage
    /// Contains garage.toml configuration file
    static var garageConfigDirectory: URL {
        baseDirectory
            .appendingPathComponent("config")
            .appendingPathComponent("garage")
    }

    /// Garage config file path: ~/Library/Application Support/Fadogen/config/garage/garage.toml
    static var garageConfigPath: URL {
        garageConfigDirectory.appendingPathComponent("garage.toml")
    }

    /// Node.js versions directory: /Users/Shared/Fadogen/node
    /// Contains all installed Node.js versions
    static var nodeVersionsDirectory: URL {
        sharedBinariesDirectory.appendingPathComponent("node")
    }

    /// Binary path for specific PHP version
    /// - Parameter majorVersion: Version like "8.2", "8.3", "8.4"
    /// - Returns: URL like .../bin/php82
    static func binaryPath(for majorVersion: String) -> URL {
        let versionNumber = majorVersion.replacingOccurrences(of: ".", with: "")
        return binDirectory.appendingPathComponent("php\(versionNumber)")
    }

    /// PHP-FPM binary path for specific PHP version
    /// - Parameter majorVersion: Version like "8.2", "8.3", "8.4"
    /// - Returns: URL like .../bin/php82-fpm
    static func fpmBinaryPath(for majorVersion: String) -> URL {
        let versionNumber = majorVersion.replacingOccurrences(of: ".", with: "")
        return binDirectory.appendingPathComponent("php\(versionNumber)-fpm")
    }

    /// Config path for specific PHP version
    /// - Parameter majorVersion: Version like "8.2", "8.3", "8.4"
    /// - Returns: URL like .../config/php/82
    static func configPath(for majorVersion: String) -> URL {
        let versionNumber = majorVersion.replacingOccurrences(of: ".", with: "")
        return configDirectory.appendingPathComponent(versionNumber)
    }

    // MARK: - Service Paths (Databases & Caches)

    /// Binary path for specific service version
    /// - Parameters:
    ///   - service: Service type (mariadb, mysql, postgresql, redis, valkey)
    ///   - major: Major version like "10", "11", "8"
    /// - Returns: URL like /Users/Shared/Fadogen/mariadb/10/
    static func binaryPath(for service: ServiceType, major: String) -> URL {
        sharedBinariesDirectory
            .appendingPathComponent(service.rawValue)
            .appendingPathComponent(major)
    }

    /// Data path for specific service version
    /// - Parameters:
    ///   - service: Service type (mariadb, mysql, postgresql, redis, valkey)
    ///   - major: Major version like "10", "11", "8"
    /// - Returns: URL like ~/Library/.../Fadogen/data/mariadb/10/
    /// - Note: Single-installation services (e.g., Valkey) exclude major version to persist data across upgrades
    static func dataPath(for service: ServiceType, major: String) -> URL {
        if service.isSingleInstallation {
            return dataDirectory.appendingPathComponent(service.rawValue)
        }
        return dataDirectory
            .appendingPathComponent(service.rawValue)
            .appendingPathComponent(major)
    }

    /// Log path for specific service version
    /// - Parameters:
    ///   - service: Service type (mariadb, mysql, postgresql, redis, valkey)
    ///   - major: Major version like "10", "11", "8"
    /// - Returns: URL like ~/Library/.../Fadogen/logs/mariadb/10/
    /// - Note: Single-installation services (e.g., Valkey) exclude major version to persist logs across upgrades
    static func logPath(for service: ServiceType, major: String) -> URL {
        if service.isSingleInstallation {
            return logsDirectory.appendingPathComponent(service.rawValue)
        }
        return logsDirectory
            .appendingPathComponent(service.rawValue)
            .appendingPathComponent(major)
    }

    // MARK: - Node.js Paths

    /// Installation path for specific Node.js version
    /// - Parameter major: Major version like "22", "20", "18"
    /// - Returns: URL like /Users/Shared/Fadogen/node/22/
    static func nodeInstallPath(for major: String) -> URL {
        nodeVersionsDirectory.appendingPathComponent(major)
    }

    /// Binary path for specific Node.js version
    /// - Parameter major: Major version like "22", "20", "18"
    /// - Returns: URL like /Users/Shared/Fadogen/node/22/bin/node
    static func nodeBinaryPath(for major: String) -> URL {
        nodeInstallPath(for: major)
            .appendingPathComponent("bin")
            .appendingPathComponent("node")
    }

    /// npm binary path for specific Node.js version
    /// - Parameter major: Major version like "22", "20", "18"
    /// - Returns: URL like /Users/Shared/Fadogen/node/22/bin/npm
    static func npmBinaryPath(for major: String) -> URL {
        nodeInstallPath(for: major)
            .appendingPathComponent("bin")
            .appendingPathComponent("npm")
    }

    /// npx binary path for specific Node.js version
    /// - Parameter major: Major version like "22", "20", "18"
    /// - Returns: URL like /Users/Shared/Fadogen/node/22/bin/npx
    static func npxBinaryPath(for major: String) -> URL {
        nodeInstallPath(for: major)
            .appendingPathComponent("bin")
            .appendingPathComponent("npx")
    }

    // MARK: - Bundle Resources Paths

    /// Bundle resources directory (Contents/Resources/)
    /// Used for accessing bundled binaries and scripts
    static var bundleResourcesDirectory: URL {
        guard let url = Bundle.main.resourceURL else {
            fatalError("Bundle resources not found")
        }
        return url
    }

    /// Ansible Python binary path (bundled in app)
    /// - Returns: URL like .../Contents/Resources/python/bin/python3
    static var ansiblePythonPath: URL {
        bundleResourcesDirectory
            .appendingPathComponent("python")
            .appendingPathComponent("bin")
            .appendingPathComponent("python3")
    }

    /// Ansible configuration file (bundled in app)
    /// Contains settings to suppress warnings and configure interpreter discovery
    /// - Returns: URL like .../Contents/Resources/Ansible/ansible.cfg
    static var ansibleConfigPath: URL {
        bundleResourcesDirectory
            .appendingPathComponent("Ansible")
            .appendingPathComponent("ansible.cfg")
    }

    /// Ansible playbooks path (bundled in app)
    /// - Returns: URL like .../Contents/Resources/Ansible/playbooks/
    static var ansiblePlaybooksPath: URL {
        bundleResourcesDirectory
            .appendingPathComponent("Ansible")
            .appendingPathComponent("playbooks")
    }

    /// Ansible custom roles path (custom roles like cloudflared)
    /// - Returns: URL like .../Contents/Resources/Ansible/roles
    static var ansibleRolesPath: URL {
        bundleResourcesDirectory
            .appendingPathComponent("Ansible")
            .appendingPathComponent("roles")
    }

    /// Ansible external roles path (geerlingguy roles installed at build time)
    /// - Returns: URL like .../Resources/python/ansible_roles
    static var ansibleExternalRolesPath: URL {
        bundleResourcesDirectory
            .appendingPathComponent("python")
            .appendingPathComponent("ansible_roles")
    }

    /// sshpass binary path (bundled in app)
    /// Used by Ansible for password-based SSH authentication
    /// - Returns: URL like .../Contents/Resources/sshpass
    static var sshpassPath: URL {
        bundleResourcesDirectory.appendingPathComponent("sshpass")
    }

    /// cloudflared binary path (bundled in app)
    /// Used for SSH connections through Cloudflare Tunnels
    /// - Returns: URL like .../Contents/Resources/cloudflared
    static var cloudflaredPath: URL {
        bundleResourcesDirectory.appendingPathComponent("cloudflared")
    }

    /// yq binary path (bundled in app)
    /// Used for YAML manipulation (merging compose templates)
    /// - Returns: URL like .../Contents/Resources/yq
    static var yqPath: URL {
        bundleResourcesDirectory.appendingPathComponent("yq")
    }

    /// Mailpit binary path (bundled in app)
    /// Local SMTP server for email testing in development
    /// - Returns: URL like .../Contents/Resources/mailpit
    static var mailpitBinaryPath: URL {
        bundleResourcesDirectory.appendingPathComponent("mailpit")
    }

    /// Mailpit data directory: ~/Library/Application Support/Fadogen/data/mailpit
    /// Used for Mailpit SQLite database
    static var mailpitDataDirectory: URL {
        dataDirectory.appendingPathComponent("mailpit")
    }

    // MARK: - Docker Templates

    /// Docker templates directory (flattened to Resources root by Xcode)
    /// Source: Resources/Docker/{laravel,symfony,shared}/compose/
    /// Bundle: Resources/ with prefixes: laravel-*, symfony-*, shared-*
    static var dockerTemplatesDirectory: URL {
        bundleResourcesDirectory
    }
}
