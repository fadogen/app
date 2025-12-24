import Foundation

// MARK: - Framework Selection

enum Framework: String, CaseIterable {
    case laravel
    case symfony

    var displayName: String {
        switch self {
        case .laravel: return "Laravel"
        case .symfony: return "Symfony"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .laravel: return true
        case .symfony: return true
        }
    }
}

// MARK: - Laravel Starter Kit

enum LaravelStarterKit: String, CaseIterable {
    case none
    case react
    case vue
    case livewire
    case custom

    var displayName: String {
        switch self {
        case .none: return "None"
        case .react: return "React"
        case .vue: return "Vue"
        case .livewire: return "Livewire"
        case .custom: return "Custom"
        }
    }

    var supportsSSR: Bool {
        self == .react || self == .vue
    }

    var hasAuthentication: Bool {
        self == .react || self == .vue || self == .livewire
    }

    var supportsVolt: Bool {
        self == .livewire
    }
}

// MARK: - Symfony Project Type

enum SymfonyProjectType: String, CaseIterable {
    case webapp
    case api
    case microservice

    var displayName: String {
        switch self {
        case .webapp: return "Web Application"
        case .api: return "API"
        case .microservice: return "Microservice"
        }
    }

    var description: String {
        switch self {
        case .webapp: return "Full stack with Twig, Doctrine, and forms"
        case .api: return "REST/GraphQL API with API Platform"
        case .microservice: return "Minimal skeleton for microservices"
        }
    }

    var includesDoctrine: Bool {
        self != .microservice
    }

    var needsApiPlatform: Bool {
        self == .api
    }
}

// MARK: - Testing Framework

enum TestingFramework: String, CaseIterable {
    case pest
    case phpunit

    var displayName: String {
        switch self {
        case .pest: return "Pest"
        case .phpunit: return "PHPUnit"
        }
    }
}

// MARK: - JavaScript Package Manager

enum JSPackageManager: String, CaseIterable {
    case none
    case bun
    case npm

    var displayName: String {
        switch self {
        case .none: return "None"
        case .bun: return "bun"
        case .npm: return "npm"
        }
    }
}

// MARK: - Queue Service

enum QueueService: String, CaseIterable {
    case none
    case horizon
    case native

    var displayName: String {
        switch self {
        case .none: return "None"
        case .horizon: return "Horizon"
        case .native: return "Native"
        }
    }
}

// MARK: - Cache Service

enum CacheService: String, CaseIterable {
    case redis
    case valkey

    var displayName: String {
        switch self {
        case .redis: return "Redis"
        case .valkey: return "Valkey"
        }
    }

    var defaultPort: Int { 6379 }
}

// MARK: - Database Type

enum DatabaseType: String, CaseIterable {
    case sqlite
    case mysql
    case mariadb
    case postgresql

    var displayName: String {
        switch self {
        case .sqlite: return "SQLite"
        case .mysql: return "MySQL"
        case .mariadb: return "MariaDB"
        case .postgresql: return "PostgreSQL"
        }
    }

    var envConnectionName: String {
        switch self {
        case .sqlite: return "sqlite"
        case .mysql: return "mysql"
        case .mariadb: return "mariadb"
        case .postgresql: return "pgsql"
        }
    }

    var defaultPort: Int {
        switch self {
        case .sqlite: return 0
        case .mysql, .mariadb: return 3306
        case .postgresql: return 5432
        }
    }
}

// MARK: - Starter Kit Authentication

enum StarterKitAuthentication: String, CaseIterable {
    case native
    case workos

    var displayName: String {
        switch self {
        case .native: return "Native"
        case .workos: return "WorkOS"
        }
    }
}

// MARK: - Queue Backend

enum QueueBackend: String, CaseIterable, Equatable {
    case valkey
    case redis
    case database

    var displayName: String {
        switch self {
        case .valkey: return "Valkey"
        case .redis: return "Redis"
        case .database: return "Database"
        }
    }
}

// MARK: - Project Configuration

struct ProjectConfiguration {
    var framework: Framework = .laravel
    var installDirectory: URL?
    var projectName: String = ""
    var phpVersion: String = "8.4"
    var databaseType: DatabaseType = .sqlite

    // Starter Kit
    var starterKit: LaravelStarterKit = .none
    var customStarterKitRepo: String = ""
    var authentication: StarterKitAuthentication = .native
    var volt: Bool = false

    /// SSR is mandatory for React and Vue starter kits
    var ssr: Bool { starterKit.supportsSSR }

    // Development Tools
    var testingFramework: TestingFramework = .pest
    var jsPackageManager: JSPackageManager = .bun

    // Laravel Optional Features
    var queueService: QueueService = .none
    var queueBackend: QueueBackend?
    var cacheService: CacheService?
    var taskScheduler: Bool = false
    var reverb: Bool = false
    var octane: Bool = false
    var scout: Bool = false

    // Symfony-specific
    var symfonyProjectType: SymfonyProjectType = .webapp

    // Local Service Ports (populated by the view from ServiceVersion queries)
    var databasePort: Int?
    var cachePort: Int?

    // Service Versions for Docker compose (populated from installed ServiceVersion)
    var postgresVersion: String?
    var mysqlVersion: String?
    var mariadbVersion: String?
    var valkeyVersion: String?
    var redisVersion: String?
    var typesenseVersion: String?

    // Runtime Versions for Dockerfile (populated from installed/bundled versions)
    var nodeVersion: String?  // e.g., "24" for node:24-bookworm-slim
    var bunVersion: String?   // e.g., "1.3" for oven/bun:1.3-debian

    // MARK: - Visibility Properties

    var showsLaravelOptions: Bool { framework == .laravel }
    var showsSymfonyOptions: Bool { framework == .symfony }
    var showsStarterKit: Bool { framework == .laravel }
    var showsCustomRepo: Bool { framework == .laravel && starterKit == .custom }
    var showsAuthentication: Bool { framework == .laravel && starterKit.hasAuthentication }
    var showsVolt: Bool { framework == .laravel && starterKit.supportsVolt && authentication != .workos }
    var showsQueueBackend: Bool { framework == .laravel && queueService != .none }

    var availableQueueBackends: [QueueBackend] {
        switch queueService {
        case .none: return []
        case .horizon: return [.valkey, .redis]
        case .native: return [.valkey, .redis, .database]
        }
    }

    // MARK: - Normalization

    func normalized() -> ProjectConfiguration {
        var config = self

        // Symfony: reset all Laravel-specific options
        if framework == .symfony {
            config.starterKit = .none
            config.customStarterKitRepo = ""
            config.authentication = .native
            config.volt = false
            config.testingFramework = .phpunit
            config.jsPackageManager = .none  // Symfony doesn't require JavaScript
            config.queueService = .none
            config.queueBackend = nil
            config.cacheService = nil
            config.taskScheduler = false
            config.reverb = false
            config.octane = false
            config.scout = false
            return config
        }

        // Laravel: cleanup orphaned values
        if !showsStarterKit {
            config.starterKit = .none
        }
        if !showsAuthentication {
            config.authentication = StarterKitAuthentication.native
        }
        if !showsVolt {
            config.volt = false
        }
        if !showsCustomRepo {
            config.customStarterKitRepo = ""
        }

        // QueueService cleanup - set default if needed
        if !showsQueueBackend {
            config.queueBackend = nil
        } else if config.queueBackend == nil {
            config.queueBackend = QueueBackend.valkey
        } else if let backend = config.queueBackend,
                  !availableQueueBackends.contains(backend) {
            config.queueBackend = QueueBackend.valkey
        }

        return config
    }
}

// MARK: - Generator State

enum ProjectGeneratorState: Equatable {
    case idle
    case generating
    case completed
    case failed
    case cancelled
}

// MARK: - Prerequisite Errors

enum PrerequisiteError: LocalizedError {
    case phpInstallationFailed(String, Error)
    case phpNotAvailable(String)
    case serviceInstallationFailed(ServiceType, Error)
    case serviceStartFailed(ServiceType, Error)
    case reverbInstallationFailed(Error)
    case reverbStartFailed(Error)
    case typesenseInstallationFailed(Error)
    case typesenseStartFailed(Error)
    case bunInstallationFailed(Error)
    case metadataNotAvailable

    var errorDescription: String? {
        switch self {
        case .phpInstallationFailed(let version, let error):
            return "Failed to install PHP \(version): \(error.localizedDescription)"
        case .phpNotAvailable(let version):
            return "PHP \(version) is not available for download"
        case .serviceInstallationFailed(let service, let error):
            return "Failed to install \(service.displayName): \(error.localizedDescription)"
        case .serviceStartFailed(let service, let error):
            return "Failed to start \(service.displayName): \(error.localizedDescription)"
        case .reverbInstallationFailed(let error):
            return "Failed to install Reverb: \(error.localizedDescription)"
        case .reverbStartFailed(let error):
            return "Failed to start Reverb: \(error.localizedDescription)"
        case .typesenseInstallationFailed(let error):
            return "Failed to install Typesense: \(error.localizedDescription)"
        case .typesenseStartFailed(let error):
            return "Failed to start Typesense: \(error.localizedDescription)"
        case .bunInstallationFailed(let error):
            return "Failed to install Bun: \(error.localizedDescription)"
        case .metadataNotAvailable:
            return "Service metadata not available. Check your internet connection."
        }
    }
}

// MARK: - Service Mapping

extension DatabaseType {
    /// Returns nil for SQLite (no external service needed)
    func toServiceType() -> ServiceType? {
        switch self {
        case .sqlite: return nil
        case .mysql: return .mysql
        case .mariadb: return .mariadb
        case .postgresql: return .postgresql
        }
    }
}

extension CacheService {
    func toServiceType() -> ServiceType {
        switch self {
        case .redis: return .redis
        case .valkey: return .valkey
        }
    }
}

extension QueueBackend {
    /// Returns nil for database backend (no external service needed)
    func toServiceType() -> ServiceType? {
        switch self {
        case .redis: return .redis
        case .valkey: return .valkey
        case .database: return nil
        }
    }
}
