import Foundation
import SwiftData

enum ServiceType: String, Codable, CaseIterable {
    case mariadb
    case mysql
    case postgresql
    case redis
    case valkey

    nonisolated var displayName: String {
        switch self {
        case .mariadb: return "MariaDB"
        case .mysql: return "MySQL"
        case .postgresql: return "PostgreSQL"
        case .redis: return "Redis"
        case .valkey: return "Valkey"
        }
    }

    nonisolated var isDatabase: Bool {
        switch self {
        case .mariadb, .mysql, .postgresql: return true
        case .redis, .valkey: return false
        }
    }

    nonisolated var isCache: Bool { !isDatabase }

    nonisolated var defaultPort: Int {
        switch self {
        case .mariadb, .mysql: return 3306
        case .postgresql: return 5432
        case .redis, .valkey: return 6379
        }
    }

    /// Data and logs persist across major upgrades (e.g., Valkey 7 → 8)
    nonisolated var isSingleInstallation: Bool {
        switch self {
        case .valkey: return true
        default: return false
        }
    }

    /// Relative to binary directory
    nonisolated var primaryExecutable: String {
        switch self {
        case .mariadb: return "bin/mariadbd"
        case .mysql: return "bin/mysqld"
        case .postgresql: return "bin/postgres"
        case .redis: return "bin/redis-server"
        case .valkey: return "bin/valkey-server"
        }
    }
}

@Model
final class ServiceVersion {

    var serviceType: ServiceType = ServiceType.mariadb
    var major: String = ""  // e.g., "10"
    var minor: String = ""  // e.g., "10.11.14"
    var port: Int = 0
    var autoStart: Bool = false

    /// e.g., "mariadb-10" - only one per service type + major branch
    var uniqueIdentifier: String = ""

    /// e.g., /Users/Shared/Fadogen/mariadb/10/
    var binaryPath: URL {
        FadogenPaths.binaryPath(for: serviceType, major: major)
    }

    /// e.g., ~/Library/Application Support/Fadogen/data/mariadb/10/
    var dataPath: URL {
        FadogenPaths.dataPath(for: serviceType, major: major)
    }

    /// e.g., ~/Library/Application Support/Fadogen/logs/mariadb/10/
    var logPath: URL {
        FadogenPaths.logPath(for: serviceType, major: major)
    }

    init(serviceType: ServiceType = .mariadb, major: String, minor: String, port: Int, autoStart: Bool = false) {
        self.serviceType = serviceType
        self.major = major
        self.minor = minor
        self.port = port
        self.autoStart = autoStart
        self.uniqueIdentifier = "\(serviceType.rawValue)-\(major)"
    }
}
