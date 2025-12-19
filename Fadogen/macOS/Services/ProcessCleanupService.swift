import Foundation
import SwiftData
import OSLog

@Observable
final class ProcessCleanupService {
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "process-cleanup")

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Files in /tmp are wiped on reboot, preventing unsafe kills
    func writePIDFile(identifier: String, pid: Int32) {
        do {
            // Ensure directory exists
            let pidDir = FadogenPaths.pidFilesDirectory
            try FileManager.default.createDirectory(at: pidDir, withIntermediateDirectories: true)

            // Write PID to file
            let pidFile = pidDir.appendingPathComponent("\(identifier).pid")
            try String(pid).write(to: pidFile, atomically: true, encoding: .utf8)

            logger.debug("Wrote PID \(pid) for \(identifier)")
        } catch {
            logger.error("Failed to write PID file for \(identifier): \(error.localizedDescription)")
        }
    }

    func removePIDFile(identifier: String) {
        let pidFile = FadogenPaths.pidFilesDirectory.appendingPathComponent("\(identifier).pid")

        do {
            if FileManager.default.fileExists(atPath: pidFile.path) {
                try FileManager.default.removeItem(at: pidFile)
                logger.debug("Removed PID file for \(identifier)")
            }
        } catch {
            logger.error("Failed to remove PID file for \(identifier): \(error.localizedDescription)")
        }
    }

    /// SIGTERM all orphans, wait 500ms, SIGKILL survivors
    func cleanupOrphanedProcesses() {
        let pidDir = FadogenPaths.pidFilesDirectory

        // Check if directory exists
        guard FileManager.default.fileExists(atPath: pidDir.path) else {
            logger.debug("No PID files directory found, skipping cleanup")
            return
        }

        do {
            let pidFiles = try FileManager.default.contentsOfDirectory(
                at: pidDir,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "pid" }

            guard !pidFiles.isEmpty else {
                logger.debug("No orphaned processes found")
                return
            }

            logger.info("Found \(pidFiles.count) PID file(s), checking for orphaned processes...")

            // Phase 1: Parse PID files and send SIGTERM to all running processes (parallel)
            var orphanedProcesses: [(identifier: String, pid: Int32, pidFile: URL)] = []

            for pidFile in pidFiles {
                let identifier = pidFile.deletingPathExtension().lastPathComponent

                do {
                    let pidString = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

                    guard let pid = Int32(pidString) else {
                        logger.warning("Invalid PID in file \(identifier).pid")
                        try FileManager.default.removeItem(at: pidFile)
                        continue
                    }

                    // Check if process is running
                    if isProcessRunning(pid: pid) {
                        logger.warning("Found orphaned process \(identifier) (PID: \(pid)), sending SIGTERM")
                        // Send SIGTERM immediately (don't wait)
                        kill(pid, SIGTERM)
                        orphanedProcesses.append((identifier, pid, pidFile))
                    } else {
                        // Process already dead, just remove PID file
                        try FileManager.default.removeItem(at: pidFile)
                    }

                } catch {
                    logger.error("Failed to process PID file \(identifier): \(error.localizedDescription)")
                }
            }

            // Phase 2: Wait once for all processes (500ms is enough for simple daemons)
            if !orphanedProcesses.isEmpty {
                Thread.sleep(forTimeInterval: 0.5)
            }

            // Phase 3: Check survivors and send SIGKILL if needed
            for (identifier, pid, pidFile) in orphanedProcesses {
                if isProcessRunning(pid: pid) {
                    // Process didn't respond to SIGTERM, force kill
                    logger.warning("Process \(identifier) (PID: \(pid)) didn't respond to SIGTERM, sending SIGKILL")
                    kill(pid, SIGKILL)
                }

                // Remove PID file
                do {
                    try FileManager.default.removeItem(at: pidFile)
                } catch {
                    logger.error("Failed to remove PID file for \(identifier): \(error.localizedDescription)")
                }
            }

            logger.info("Orphaned processes cleanup completed")

        } catch {
            logger.error("Failed to read PID files directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    /// kill(pid, 0) checks existence without sending a signal
    private func isProcessRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}
