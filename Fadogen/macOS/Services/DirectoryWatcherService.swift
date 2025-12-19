import Foundation
import SwiftData

@Observable
final class DirectoryWatcherService {
    private let modelContext: ModelContext
    private let caddyConfig: CaddyConfigService
    private var linkingService: ProjectLinkingService?

    // Active monitors: path -> DispatchSource
    private var activeMonitors: [String: DispatchSourceFileSystemObject] = [:]

    // Current state snapshots: path -> set of subdirectory names
    private var directorySnapshots: [String: Set<String>] = [:]

    init(modelContext: ModelContext, caddyConfig: CaddyConfigService) {
        self.modelContext = modelContext
        self.caddyConfig = caddyConfig
    }

    func setLinkingService(_ service: ProjectLinkingService) {
        self.linkingService = service
    }

    /// Synchronize monitors with SwiftData (single source of truth)
    /// - Parameter syncCaddy: Whether to synchronize Caddyfiles (default: false for startup)
    func reconcile(syncCaddy: Bool = false) async {
        // Fetch current WatchedDirectories from SwiftData
        let descriptor = FetchDescriptor<WatchedDirectory>()
        guard let directories = try? modelContext.fetch(descriptor) else {
            return
        }

        let currentPaths = Set(directories.map { $0.path })
        let activePaths = Set(activeMonitors.keys)

        // Stop monitors for removed directories
        let pathsToRemove = activePaths.subtracting(currentPaths)
        for path in pathsToRemove {
            stopMonitoring(path: path)
        }

        // Start monitors for new directories (only if directory exists)
        let pathsToAdd = currentPaths.subtracting(activePaths)
        for path in pathsToAdd {
            if FileManager.default.fileExists(atPath: path) {
                startMonitoring(path: path)
            }
        }

        // Synchronize projects for ALL watched directories (including existing ones)
        for directory in directories {
            syncProjects(for: directory)
        }

        // Auto-link newly created projects to existing DeployedProjects
        linkingService?.autoLinkOrphanedProjects()

        // Synchronize Caddyfiles after all projects are updated (only if requested)
        if syncCaddy {
            caddyConfig.reconcile()
        }
    }

    /// Start monitoring a directory
    private func startMonitoring(path: String) {
        // Open file descriptor
        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        // Create snapshot of current state
        directorySnapshots[path] = currentSubdirectories(at: path)

        // Create dispatch source for file system monitoring
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.handleDirectoryChange(path: path)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        activeMonitors[path] = source
    }

    /// Stop monitoring a directory
    private func stopMonitoring(path: String) {
        guard let source = activeMonitors[path] else { return }

        source.cancel()
        activeMonitors.removeValue(forKey: path)
        directorySnapshots.removeValue(forKey: path)
    }

    /// Synchronize projects for a watched directory
    private func syncProjects(for directory: WatchedDirectory) {
        // Skip if directory doesn't exist on filesystem
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }

        let currentSubdirs = currentSubdirectories(at: directory.path)
        let existingProjects = Set((directory.projects ?? []).map { $0.name })

        // Add missing projects
        let projectsToAdd = currentSubdirs.subtracting(existingProjects)
        for name in projectsToAdd {
            let projectPath = URL(fileURLWithPath: directory.path).appendingPathComponent(name).path
            createAndInsertProject(name: name, path: projectPath, directory: directory)
        }

        // Handle removed subdirectories
        // LocalProject deletion is safe (local-only, doesn't affect CloudKit)
        let projectsToRemove = (directory.projects ?? []).filter { !currentSubdirs.contains($0.name) }
        for project in projectsToRemove {
            modelContext.delete(project)
        }

        // Save deletions if any, then cleanup broken links in DeployedProjects
        if !projectsToRemove.isEmpty {
            try? modelContext.save()
            linkingService?.cleanupBrokenLinks()
        }
    }

    /// Handle directory changes (detect add/remove/rename)
    private func handleDirectoryChange(path: String) {
        guard let oldSnapshot = directorySnapshots[path] else { return }

        let newSnapshot = currentSubdirectories(at: path)

        // Find the WatchedDirectory
        let descriptor = FetchDescriptor<WatchedDirectory>(predicate: #Predicate { $0.path == path })
        guard let directory = try? modelContext.fetch(descriptor).first else {
            directorySnapshots[path] = newSnapshot
            return
        }

        // Detect additions
        let added = newSnapshot.subtracting(oldSnapshot)
        for name in added {
            let projectPath = URL(fileURLWithPath: path).appendingPathComponent(name).path
            createAndInsertProject(name: name, path: projectPath, directory: directory)

            // Schedule delayed Git re-detection (for git clone operations)
            scheduleGitRedetection(projectPath: projectPath, afterSeconds: 3)
        }

        // Detect removals (includes renames as remove + add)
        // LocalProject deletion is safe (local-only, doesn't affect CloudKit)
        let removed = oldSnapshot.subtracting(newSnapshot)
        for name in removed {
            if let project = (directory.projects ?? []).first(where: { $0.name == name }) {
                modelContext.delete(project)
                try? modelContext.save()
            }
        }

        // Cleanup broken links in DeployedProjects after projects are removed
        if !removed.isEmpty {
            linkingService?.cleanupBrokenLinks()
        }

        // Update snapshot
        directorySnapshots[path] = newSnapshot

        // After project changes: auto-link and update Caddy
        if !added.isEmpty {
            linkingService?.autoLinkOrphanedProjects()
        }
        if !added.isEmpty || !removed.isEmpty {
            caddyConfig.reconcile()
        }
    }

    /// Creates a LocalProject with a unique localURL
    /// Auto-appends suffix (-2, -3, etc.) if the URL is already taken
    private func createProjectWithUniqueURL(name: String, path: String) -> LocalProject? {
        guard let uniqueHostname = modelContext.findUniqueHostname(name) else {
            return nil
        }

        guard let project = LocalProject(name: name, path: path) else {
            return nil
        }
        project.localURL = "https://\(uniqueHostname).localhost"
        return project
    }

    /// Creates and inserts a project for a directory if it doesn't already exist
    /// If a standalone project exists at this path, adopts it into the WatchedDirectory
    /// - Parameters:
    ///   - name: Directory name
    ///   - path: Absolute path to directory
    ///   - directory: Parent WatchedDirectory
    private func createAndInsertProject(name: String, path: String, directory: WatchedDirectory) {
        // Check if project with this path already exists
        let pathToCheck = path
        let pathDescriptor = FetchDescriptor<LocalProject>(predicate: #Predicate { $0.path == pathToCheck })
        if let existingProject = try? modelContext.fetch(pathDescriptor).first {
            // Absorption: adopt standalone project into this WatchedDirectory
            if existingProject.watchedDirectory == nil {
                existingProject.watchedDirectory = directory
                try? modelContext.save()
            }
            return
        }

        // Create project with unique localURL
        guard let project = createProjectWithUniqueURL(name: name, path: path) else {
            return
        }

        project.watchedDirectory = directory

        // Auto-detect framework
        if let detected = try? project.detectFramework() {
            project.framework = detected
        }

        // Auto-detect Git repository
        if let repo = try? project.detectGitRepository() {
            project.gitRemoteURL = repo.remoteURL
            project.gitBranch = repo.branch
        }

        modelContext.insert(project)
        try? modelContext.save()
    }

    /// Schedule delayed Git re-detection for a project
    /// This handles git clone operations where .git/config isn't immediately available
    private func scheduleGitRedetection(projectPath: String, afterSeconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + afterSeconds) { [weak self] in
            self?.redetectGitForProject(at: projectPath)
        }
    }

    /// Re-detect Git repository for a project that may have been cloned
    private func redetectGitForProject(at path: String) {
        let pathToCheck = path
        let descriptor = FetchDescriptor<LocalProject>(predicate: #Predicate { $0.path == pathToCheck })

        guard let project = try? modelContext.fetch(descriptor).first else {
            return
        }

        // Check if branch needs re-detection (placeholder values during clone)
        let needsBranchRedetection = project.gitBranch?.hasPrefix(".") == true ||
                                      project.gitBranch == "invalid" ||
                                      project.gitBranch == ".invalid"

        // Check if framework needs re-detection
        let needsFrameworkRedetection = project.framework == nil

        // Skip if everything is fully detected
        let gitFullyDetected = project.gitRemoteURL != nil && !needsBranchRedetection
        guard !gitFullyDetected || needsFrameworkRedetection else {
            return
        }

        var needsSave = false

        // Re-detect Git
        if let repo = try? project.detectGitRepository() {
            project.gitRemoteURL = repo.remoteURL
            project.gitBranch = repo.branch
            needsSave = true
        }

        // Re-detect framework if not detected initially
        if project.framework == nil {
            if let detected = try? project.detectFramework() {
                project.framework = detected
                needsSave = true
            }
        }

        if needsSave {
            try? modelContext.save()

            // Try to auto-link with DeployedProject now that we have Git info
            if project.gitRemoteURL != nil {
                linkingService?.autoLinkOrphanedProjects()
            }
        }
    }

    /// Get current subdirectories (first level only, excludes hidden folders)
    private func currentSubdirectories(at path: String) -> Set<String> {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else {
            return []
        }

        // Filter to only include directories (not files), excluding hidden folders
        let directories = contents.filter { name in
            guard !name.hasPrefix(".") else { return false }

            var isDirectory: ObjCBool = false
            let fullPath = URL(fileURLWithPath: path).appendingPathComponent(name).path
            fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory)
            return isDirectory.boolValue
        }

        return Set(directories)
    }

    /// Cleanup all monitors on shutdown
    func shutdown() {
        for path in activeMonitors.keys {
            stopMonitoring(path: path)
        }
    }

    /// Delete all projects from a WatchedDirectory before deletion
    /// Projects are deleted (local-only, safe operation)
    func detachAllProjects(for directory: WatchedDirectory) {
        guard let projects = directory.projects, !projects.isEmpty else {
            return
        }

        for project in projects {
            modelContext.delete(project)
        }

        try? modelContext.save()
        // Cleanup broken links in DeployedProjects after projects are removed
        linkingService?.cleanupBrokenLinks()
    }

    /// Stop watching a specific WatchedDirectory (convenience method for UI)
    func stopWatching(_ directory: WatchedDirectory) {
        stopMonitoring(path: directory.path)
    }
}
