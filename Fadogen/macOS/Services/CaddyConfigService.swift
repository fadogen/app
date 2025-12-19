import Foundation
import SwiftData
import Subprocess
import System

@Observable
final class CaddyConfigService {
    private let modelContext: ModelContext
    private let caddy: CaddyService

    init(modelContext: ModelContext, caddy: CaddyService) {
        self.modelContext = modelContext
        self.caddy = caddy
    }

    func reconcile(project: LocalProject) {
        // Only generate Caddyfile if project directory exists
        guard FileManager.default.fileExists(atPath: project.path) else {
            return
        }

        let projectsDir = FadogenPaths.caddyProjectsDirectory

        // Ensure projects directory exists
        guard (try? FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)) != nil else {
            return
        }

        if updateProjectCaddyfile(project, in: projectsDir) {
            if caddy.state == .running {
                caddy.reload()
            }
        }
    }

    /// Reconcile SwiftData LocalProjects with Caddyfiles
    /// Compares expected content with existing files and regenerates only if different
    func reconcile() {
        // 1. Fetch all LocalProjects from SwiftData
        let descriptor = FetchDescriptor<LocalProject>()
        guard let projects = try? modelContext.fetch(descriptor) else {
            return
        }

        // FILTER: Only generate Caddyfiles for locally available projects
        let localProjects = projects.filter { FileManager.default.fileExists(atPath: $0.path) }

        let fileManager = FileManager.default
        let projectsDir = FadogenPaths.caddyProjectsDirectory

        var hasChanges = false

        // Ensure projects directory exists
        guard (try? fileManager.createDirectory(at: projectsDir, withIntermediateDirectories: true)) != nil else {
            return
        }

        // 2. Update/create Caddyfiles ONLY for locally available projects
        for project in localProjects {
            if updateProjectCaddyfile(project, in: projectsDir) {
                hasChanges = true
            }
        }

        // 3. Get existing Caddyfile names and remove orphaned ones
        let existingFiles = (try? fileManager.contentsOfDirectory(atPath: projectsDir.path))?.filter { $0.hasSuffix(".caddy") } ?? []
        let expectedFiles = Set(localProjects.map { "\($0.sanitizedName).caddy" })
        let orphaned = Set(existingFiles).subtracting(expectedFiles)

        for filename in orphaned {
            let filePath = projectsDir.appendingPathComponent(filename)
            if (try? fileManager.removeItem(at: filePath)) != nil {
                hasChanges = true
            }
        }

        // 4. Reload Caddy if changes detected and Caddy is running
        if hasChanges {
            // Only reload if Caddy is already running (not during startup)
            if caddy.state == .running {
                caddy.reload()
            }
        }
    }

    /// Reload Caddy configuration
    func reloadCaddy() {
        caddy.reload()
    }

    /// Update a single project's Caddyfile if needed
    /// - Parameters:
    ///   - project: The project to update
    ///   - projectsDir: The directory containing project Caddyfiles
    /// - Returns: True if the file was updated, false otherwise
    private func updateProjectCaddyfile(_ project: LocalProject, in projectsDir: URL) -> Bool {
        let filename = "\(project.sanitizedName).caddy"
        let filePath = projectsDir.appendingPathComponent(filename)
        let expectedContent = caddyfileContent(for: project)

        // Check if update is needed
        let needsUpdate: Bool
        if let existingContent = try? String(contentsOf: filePath, encoding: .utf8) {
            needsUpdate = (existingContent != expectedContent)
        } else {
            needsUpdate = true  // File doesn't exist
        }

        if needsUpdate {
            guard (try? expectedContent.write(to: filePath, atomically: true, encoding: .utf8)) != nil else {
                return false
            }
            formatCaddyfile(at: filePath)
            return true
        }

        return false
    }

    /// Generate main Caddyfile with import directive, Reverb and Mailpit proxies if configured
    func generateMainCaddyfile() throws {
        let fileManager = FileManager.default
        let configDir = FadogenPaths.caddyConfigDirectory
        let projectsDir = FadogenPaths.caddyProjectsDirectory

        // Create directories
        try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        // Check if Reverb is installed and get port
        let reverbConfig = getReverbConfiguration()

        // Check if Mailpit is configured
        let mailpitConfig = getMailpitConfiguration()

        // Generate main Caddyfile
        let caddyfilePath = configDir.appendingPathComponent("Caddyfile")
        var content = ""

        // Add Reverb proxy configuration if installed
        if let port = reverbConfig {
            content += """
# Reverb Laravel WebSocket proxy
http://reverb.localhost {
    redir https://reverb.localhost{uri} permanent
}

https://reverb.localhost {
    tls internal
    reverse_proxy http://127.0.0.1:\(port)
}


"""
        }

        // Add Mailpit proxy configuration if configured
        if let config = mailpitConfig {
            content += """
# Mailpit email testing UI
http://mail.localhost {
    redir https://mail.localhost{uri} permanent
}

https://mail.localhost {
    tls internal
    reverse_proxy http://127.0.0.1:\(config.uiPort)
}


"""
        }

        // Add project imports
        content += """
# Import all project configurations
import projects/*
"""

        try content.write(to: caddyfilePath, atomically: true, encoding: .utf8)

        // Format with Caddy to ensure consistency and remove warnings
        formatCaddyfile(at: caddyfilePath)
    }

    /// Format a Caddyfile using caddy fmt
    private func formatCaddyfile(at path: URL) {
        guard let caddyBinary = Bundle.main.resourcePath else { return }
        let caddyPath = "\(caddyBinary)/caddy"

        Task {
            try? await run(
                .path(.init(caddyPath)),
                arguments: ["fmt", "--overwrite", path.path],
                output: .discarded,
                error: .discarded
            )
        }
    }

    /// Get Reverb configuration if installed
    /// - Returns: Port number if Reverb is installed, nil otherwise
    private func getReverbConfiguration() -> Int? {
        let descriptor = FetchDescriptor<ReverbVersion>(
            predicate: #Predicate { $0.uniqueIdentifier == "reverb" }
        )

        guard let reverb = try? modelContext.fetch(descriptor).first else {
            return nil
        }

        return reverb.port
    }

    /// Get Mailpit configuration if configured
    /// - Returns: MailpitConfig if configured, nil otherwise
    private func getMailpitConfiguration() -> MailpitConfig? {
        let descriptor = FetchDescriptor<MailpitConfig>(
            predicate: #Predicate { $0.uniqueIdentifier == "mailpit" }
        )

        return try? modelContext.fetch(descriptor).first
    }

    /// Generate Caddyfile content for a project
    /// - Parameter project: The project to generate content for
    /// - Returns: Caddyfile content as string
    private func caddyfileContent(for project: LocalProject) -> String {
        // Safety check: path must exist (should be guaranteed by caller filtering)
        guard FileManager.default.fileExists(atPath: project.path) else {
            return ""
        }

        let socketPath = phpSocketPath(for: project)

        return """
# HTTP → HTTPS redirect (port 80)
http://\(project.sanitizedName).localhost {
    redir https://\(project.sanitizedName).localhost{uri}
}

# HTTPS (port 443)
https://\(project.sanitizedName).localhost {
    tls internal
    root * "\(project.path)"
    encode
    php_fastcgi "unix/\(socketPath)" {
        try_files /public{path} /public/index.php {path} /index.php
    }
    file_server
}
"""
    }

    /// Determine PHP socket path for a project
    /// Uses project's custom PHP version or default version
    private func phpSocketPath(for project: LocalProject) -> String {
        let version: String

        if let phpVersion = project.phpVersion {
            version = phpVersion.major
        } else {
            // Find default PHP version
            let descriptor = FetchDescriptor<PHPVersion>(
                predicate: #Predicate { $0.isDefault == true }
            )

            if let defaultVersion = try? modelContext.fetch(descriptor).first {
                version = defaultVersion.major
            } else {
                // Fallback to 8.3 if no default found
                version = "8.3"
            }
        }

        let shortVersion = version.replacingOccurrences(of: ".", with: "")
        return FadogenPaths.socketsDirectory
            .appendingPathComponent("php-fpm-\(shortVersion).sock")
            .path
    }
}
