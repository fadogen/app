import Foundation
import OSLog
import Subprocess
import System

/// Filesystem operations for service binaries (nonisolated: FileManager is thread-safe)
nonisolated enum ServicesFileSystemService {

    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "services-fs")

    // MARK: - Binaries

    static func deleteBinaries(service: ServiceType, major: String) throws {
        let binaryDir = FadogenPaths.binaryPath(for: service, major: major)

        try FileSystemUtilities.deleteDirectory(
            at: binaryDir,
            logger: logger,
            itemName: "\(service.rawValue) \(major) binaries"
        )
    }

    // MARK: - Data Directory

    static func deleteDataDirectory(service: ServiceType, major: String) throws {
        let dataDir = FadogenPaths.dataPath(for: service, major: major)

        try FileSystemUtilities.deleteDirectory(
            at: dataDir,
            logger: logger,
            itemName: "\(service.rawValue) \(major) data directory"
        )
    }

    static func createDataDirectory(service: ServiceType, major: String) throws {
        let dataDir = FadogenPaths.dataPath(for: service, major: major)

        try FileSystemUtilities.createDirectory(
            at: dataDir,
            logger: logger,
            itemName: "\(service.rawValue) \(major) data directory"
        )
    }

    // MARK: - Log Directory

    static func createLogDirectory(service: ServiceType, major: String) throws {
        let logDir = FadogenPaths.logPath(for: service, major: major)

        try FileSystemUtilities.createDirectory(
            at: logDir,
            logger: logger,
            itemName: "\(service.rawValue) \(major) log directory"
        )
    }

    // MARK: - Initialization

    /// Runs initdb / mariadb-install-db / mysqld --initialize-insecure
    static func initializeDataDirectory(service: ServiceType, major: String) async throws {
        let binaryPath = FadogenPaths.binaryPath(for: service, major: major)
        let dataPath = FadogenPaths.dataPath(for: service, major: major)

        logger.info("Initializing data directory for \(service.rawValue) \(major)")

        switch service {
        case .mariadb:
            // MariaDB: use mariadb-install-db script
            let script = binaryPath.appendingPathComponent("scripts/mariadb-install-db")

            let result = try await run(
                .path(FilePath(script.path)),
                arguments: [
                    "--basedir=\(binaryPath.path)",
                    "--datadir=\(dataPath.path)",
                    "--auth-root-authentication-method=normal"
                ],
                output: .discarded
            )

            guard result.terminationStatus.isSuccess else {
                logger.error("MariaDB initialization failed: \(result.terminationStatus)")
                throw ServicesFileSystemError.initializationFailed(String(localized: "MariaDB initialization failed"))
            }

        case .mysql:
            // MySQL: use mysqld --initialize-insecure
            let mysqld = binaryPath.appendingPathComponent("bin/mysqld")

            let result = try await run(
                .path(FilePath(mysqld.path)),
                arguments: [
                    "--initialize-insecure",
                    "--datadir=\(dataPath.path)"
                ],
                output: .discarded
            )

            guard result.terminationStatus.isSuccess else {
                logger.error("MySQL initialization failed: \(result.terminationStatus)")
                throw ServicesFileSystemError.initializationFailed(String(localized: "MySQL initialization failed"))
            }

        case .postgresql:
            // PostgreSQL: use initdb
            let initdb = binaryPath.appendingPathComponent("bin/initdb")
            let sharedir = binaryPath.appendingPathComponent("share/postgresql")

            let result = try await run(
                .path(FilePath(initdb.path)),
                arguments: [
                    "-D", dataPath.path,
                    "-L", sharedir.path,     // Specify location of input files
                    "-U", "root",             // Create superuser named "root" (consistent with MySQL/MariaDB)
                    "--locale=C",             // Use C locale
                    "--encoding=UTF8",        // Still use UTF8 encoding
                    "-T", "UTC",              // Force timezone to UTC to avoid hardcoded paths
                    "--auth-local=trust",     // Allow local connections without password
                    "--auth-host=trust"       // Allow TCP/IP connections without password
                ],
                output: .string(limit: 100_000),
                error: .string(limit: 100_000)
            )

            guard result.terminationStatus.isSuccess else {
                // Log stdout and stderr for debugging
                if let stdout = result.standardOutput, !stdout.isEmpty {
                    logger.error("PostgreSQL initdb stdout: \(stdout)")
                }
                if let stderr = result.standardError, !stderr.isEmpty {
                    logger.error("PostgreSQL initdb stderr: \(stderr)")
                }

                logger.error("PostgreSQL initialization failed: \(result.terminationStatus)")
                throw ServicesFileSystemError.initializationFailed(String(localized: "PostgreSQL initialization failed"))
            }

        case .redis, .valkey:
            // Redis and Valkey don't require initialization
            logger.info("No initialization needed for \(service.rawValue)")
            return
        }

        logger.info("Successfully initialized data directory for \(service.rawValue) \(major)")
    }
}

// MARK: - Errors

enum ServicesFileSystemError: LocalizedError {
    case directoryNotFound(String)
    case deletionFailed(String)
    case creationFailed(String)
    case initializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .deletionFailed(let reason):
            return "Failed to delete: \(reason)"
        case .creationFailed(let reason):
            return "Failed to create directory: \(reason)"
        case .initializationFailed(let reason):
            return "Failed to initialize data directory: \(reason)"
        }
    }
}
