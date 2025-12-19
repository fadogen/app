import Foundation
import Subprocess
import System
import OSLog
import SwiftData

@Observable
final class ServiceProcessManager {

    private(set) var runningProcesses: [String: Task<Void, Never>] = [:]
    private(set) var startingServices: Set<String> = []
    private(set) var stoppingServices: Set<String> = []
    private(set) var logs: [String: [String]] = [:]
    private(set) var startupErrors: [String: String] = [:]

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "service-process")
    private let modelContext: ModelContext
    weak var processCleanup: ProcessCleanupService?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Status

    func isRunning(service: ServiceType, major: String) -> Bool {
        runningProcesses[identifier(service: service, major: major)] != nil
    }

    func isStarting(service: ServiceType, major: String) -> Bool {
        startingServices.contains(identifier(service: service, major: major))
    }

    func isStopping(service: ServiceType, major: String) -> Bool {
        stoppingServices.contains(identifier(service: service, major: major))
    }

    // MARK: - Start Service

    func start(service: ServiceType, major: String, port: Int) async throws {
        let id = identifier(service: service, major: major)

        guard runningProcesses[id] == nil else {
            logger.info("Service \(id) already running")
            return
        }

        guard !startingServices.contains(id) else {
            throw ServiceProcessError.operationInProgress
        }

        startingServices.insert(id)
        defer { startingServices.remove(id) }

        logger.info("Starting service: \(id)")

        logs[id] = []
        startupErrors[id] = nil

        let portCheck = await checkPortAvailability(port: port)
        if case .inUse(let process) = portCheck {
            let errorMsg = "Port \(port) already in use by \(process)"
            logger.error("\(errorMsg)")
            startupErrors[id] = errorMsg
            throw ServiceProcessError.portInUse(port, process)
        }

        let binaryPath = FadogenPaths.binaryPath(for: service, major: major)
        let dataPath = FadogenPaths.dataPath(for: service, major: major)
        let logPath = FadogenPaths.logPath(for: service, major: major)

        let (executable, arguments, environment) = try buildCommand(
            service: service,
            binaryPath: binaryPath,
            dataPath: dataPath,
            logPath: logPath,
            port: port
        )

        guard FileManager.default.fileExists(atPath: executable.string) else {
            let errorMsg = "Executable not found: \(executable.string)"
            logger.error("\(errorMsg)")
            startupErrors[id] = errorMsg
            throw ServiceProcessError.executableNotFound(executable.string)
        }

        let task = Task {
            var allStderrLines: [String] = []

            do {
                let result = try await run(
                    .path(executable),
                    arguments: .init(arguments),
                    environment: environment,
                    preferredBufferSize: 1
                ) { execution, standardOutput, _, standardError in
                    let pid = Int32(execution.processIdentifier.value)
                    self.processCleanup?.writePIDFile(identifier: id, pid: pid)

                    // Batch logs to avoid overwhelming SwiftUI
                    var buffer: [String] = []
                    let flushInterval: Duration = .milliseconds(100)
                    var lastFlush = ContinuousClock.now

                    for try await line in standardError.lines() {
                        logger.info("[\(id)] \(line)")
                        allStderrLines.append(line)

                        buffer.append(line)

                        let now = ContinuousClock.now
                        if buffer.count >= 10 || now - lastFlush >= flushInterval {
                            if var currentLogs = logs[id] {
                                currentLogs.append(contentsOf: buffer)
                                logs[id] = currentLogs
                            } else {
                                logs[id] = buffer
                            }
                            buffer.removeAll(keepingCapacity: true)
                            lastFlush = now
                        }
                    }

                    if !buffer.isEmpty {
                        if var currentLogs = logs[id] {
                            currentLogs.append(contentsOf: buffer)
                            logs[id] = currentLogs
                        } else {
                            logs[id] = buffer
                        }
                    }
                }

                if !result.terminationStatus.isSuccess && !Task.isCancelled {
                    let errorMsg = if let parsedError = parseErrorMessage(from: allStderrLines) {
                        parsedError
                    } else if !allStderrLines.isEmpty {
                        String(allStderrLines[0].prefix(100))
                    } else {
                        "Service exited with status: \(result.terminationStatus)"
                    }
                    logger.error("Service \(id) exited with failure: \(result.terminationStatus)")
                    startupErrors[id] = errorMsg
                }
            } catch {
                if !Task.isCancelled {
                    let errorMsg = if let parsedError = parseErrorMessage(from: allStderrLines) {
                        parsedError
                    } else if !allStderrLines.isEmpty {
                        String(allStderrLines[0].prefix(100))
                    } else {
                        error.localizedDescription
                    }
                    logger.error("Service \(id) error: \(errorMsg)")
                    startupErrors[id] = errorMsg
                }
            }

            runningProcesses[id] = nil
        }

        runningProcesses[id] = task
    }

    // MARK: - Stop Service

    func stop(service: ServiceType, major: String) async throws {
        let id = identifier(service: service, major: major)

        guard let task = runningProcesses[id] else {
            logger.info("Service \(id) not running")
            return
        }

        guard !stoppingServices.contains(id) else {
            throw ServiceProcessError.operationInProgress
        }

        stoppingServices.insert(id)
        defer { stoppingServices.remove(id) }

        logger.info("Stopping service: \(id)")

        task.cancel()
        runningProcesses[id] = nil
        processCleanup?.removePIDFile(identifier: id)

        logger.info("Service \(id) stopped")
    }

    // MARK: - Restart Service

    func restart(service: ServiceType, major: String, port: Int) async throws {
        if isRunning(service: service, major: major) {
            try await stop(service: service, major: major)
        }

        try await Task.sleep(for: .seconds(1))
        try await start(service: service, major: major, port: port)
    }

    // MARK: - Stop All

    func stopAll() async {
        logger.info("Stopping all running services...")

        for (id, task) in runningProcesses {
            logger.info("Stopping \(id)...")
            task.cancel()
            processCleanup?.removePIDFile(identifier: id)
        }

        runningProcesses.removeAll()
        logger.info("All services stopped")
    }

    // MARK: - Auto-Start

    func startAutoStartServices() async {
        logger.info("Starting auto-start services...")

        do {
            let descriptor = FetchDescriptor<ServiceVersion>(
                predicate: #Predicate { $0.autoStart == true }
            )
            let autoStartServices = try modelContext.fetch(descriptor)

            for serviceVersion in autoStartServices {
                let serviceType = serviceVersion.serviceType
                do {
                    logger.info("Auto-starting \(serviceType.rawValue) \(serviceVersion.major)")
                    try await start(
                        service: serviceType,
                        major: serviceVersion.major,
                        port: serviceVersion.port
                    )
                } catch {
                    logger.error("Failed to auto-start \(serviceType.rawValue) \(serviceVersion.major): \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("Failed to fetch auto-start services: \(error.localizedDescription)")
        }
    }

    // MARK: - Logs

    func getLogs(service: ServiceType, major: String) -> [String] {
        logs[identifier(service: service, major: major)] ?? []
    }

    func clearLogs(service: ServiceType, major: String) {
        logs[identifier(service: service, major: major)] = []
    }

    func clearStartupError(service: ServiceType, major: String) {
        startupErrors[identifier(service: service, major: major)] = nil
    }

    // MARK: - Private

    private func identifier(service: ServiceType, major: String) -> String {
        "\(service.rawValue)-\(major)"
    }

    private func checkPortAvailability(port: Int) async -> PortCheckResult {
        do {
            let result = try await run(
                .path(FilePath("/usr/sbin/lsof")),
                arguments: ["-i", ":\(port)", "-sTCP:LISTEN", "-t", "-n", "-P"],
                output: .string(limit: .max)
            )

            if result.terminationStatus.isSuccess,
               let output = result.standardOutput,
               !output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                let processName = await extractProcessName(pid: output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
                return .inUse(process: processName)
            }

            return .available
        } catch {
            // lsof exits with 1 if port is free
            return .available
        }
    }

    private func extractProcessName(pid: String) async -> String {
        do {
            let result = try await run(
                .path(FilePath("/bin/ps")),
                arguments: ["-p", pid, "-o", "comm="],
                output: .string(limit: .max)
            )

            if result.terminationStatus.isSuccess,
               let output = result.standardOutput,
               !output.isEmpty {
                let processName = output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                return processName.components(separatedBy: "/").last ?? processName
            }
        } catch {
            logger.warning("Failed to extract process name for PID \(pid)")
        }

        return "unknown process"
    }

    private func parseErrorMessage(from lines: [String]) -> String? {
        for line in lines {
            let lowercased = line.lowercased()

            if lowercased.contains("already in use") || lowercased.contains("address in use") {
                return "Address or port already in use"
            }

            if lowercased.contains("permission denied") {
                if let pathMatch = line.range(of: #"['"`]([^'"`]+)['"`]"#, options: .regularExpression) {
                    return "Permission denied: \(String(line[pathMatch]))"
                }
                return "Permission denied"
            }

            if lowercased.contains("no such file") || lowercased.contains("not found") {
                if let pathMatch = line.range(of: #"['"`]([^'"`]+)['"`]"#, options: .regularExpression) {
                    return "File not found: \(String(line[pathMatch]))"
                }
                return "File or directory not found"
            }

            if let range = line.range(of: #"(Cannot|Failed to|Unable to) [^.!]+[.!]?"#, options: .regularExpression) {
                return String(String(line[range]).prefix(100))
            }

            if lowercased.contains("fatal") {
                return String(line.prefix(100))
            }
        }

        return nil
    }

    private func buildCommand(
        service: ServiceType,
        binaryPath: URL,
        dataPath: URL,
        logPath: URL,
        port: Int
    ) throws -> (FilePath, [String], Environment) {
        switch service {
        case .mariadb:
            let executable = binaryPath.appendingPathComponent("bin/mariadbd")
            let socketPath = dataPath.appendingPathComponent("mysql.sock")

            return (
                FilePath(executable.path),
                [
                    "--datadir=\(dataPath.path)",
                    "--port=\(port)",
                    "--socket=\(socketPath.path)",
                    "--bind-address=127.0.0.1"
                ],
                .inherit
            )

        case .mysql:
            let executable = binaryPath.appendingPathComponent("bin/mysqld")
            let socketPath = dataPath.appendingPathComponent("mysql.sock")

            return (
                FilePath(executable.path),
                [
                    "--datadir=\(dataPath.path)",
                    "--port=\(port)",
                    "--socket=\(socketPath.path)",
                    "--bind-address=127.0.0.1"
                ],
                .inherit
            )

        case .postgresql:
            let executable = binaryPath.appendingPathComponent("bin/postgres")
            let localeKey = Environment.Key(rawValue: "LC_ALL")!

            return (
                FilePath(executable.path),
                [
                    "-D", dataPath.path,
                    "-p", "\(port)",
                    "-h", "127.0.0.1"
                ],
                .inherit.updating([localeKey: "C"])
            )

        case .redis:
            let executable = binaryPath.appendingPathComponent("bin/redis-server")

            return (
                FilePath(executable.path),
                [
                    "--port", "\(port)",
                    "--dir", dataPath.path,
                    "--bind", "127.0.0.1",
                    "--logfile", logPath.appendingPathComponent("redis.log").path
                ],
                .inherit
            )

        case .valkey:
            let executable = binaryPath.appendingPathComponent("bin/valkey-server")

            return (
                FilePath(executable.path),
                [
                    "--port", "\(port)",
                    "--dir", dataPath.path,
                    "--bind", "127.0.0.1",
                    "--logfile", logPath.appendingPathComponent("valkey.log").path
                ],
                .inherit
            )
        }
    }
}

// MARK: - Errors

enum ServiceProcessError: LocalizedError {
    case operationInProgress
    case executableNotFound(String)
    case portInUse(Int, String)

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another operation is in progress for this service"
        case .executableNotFound(let path):
            return "Executable not found at: \(path)"
        case .portInUse(let port, let process):
            return "Port \(port) already in use by \(process)"
        }
    }
}

// MARK: - Port Check Result

enum PortCheckResult {
    case available
    case inUse(process: String)
}
