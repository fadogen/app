import Foundation
import SwiftData

/// Links LocalProject (local) with DeployedProject (CloudKit) via UUID references
@Observable
final class ProjectLinkingService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Auto-Linking

    /// Links unlinked projects by matching GitHub identifier ("owner/repo")
    func autoLinkOrphanedProjects() {
        // First, clean up broken links (DeployedProjects pointing to deleted LocalProjects)
        // This allows re-linking when projects are re-created
        cleanupBrokenLinks()

        let unlinkedProjects = fetchUnlinkedLocalProjects()
        // Only consider projects with valid paths (filter out stale projects from moved/deleted folders)
        let validUnlinkedProjects = unlinkedProjects.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let deployedProjects = fetchAllDeployedProjects()

        for project in validUnlinkedProjects {
            guard let projectIdentifier = project.githubIdentifier else { continue }

            // Find matching DeployedProject by GitHub identifier
            if let matchingProject = deployedProjects.first(where: { $0.githubIdentifier == projectIdentifier }) {
                // Verify the project is not already linked to another project
                guard matchingProject.linkedLocalProjectID == nil else { continue }

                link(project, to: matchingProject)
            }
        }
    }

    // MARK: - Linking

    func link(_ project: LocalProject, to deployedProject: DeployedProject) {
        project.linkedDeployedProjectID = deployedProject.id
        deployedProject.linkedLocalProjectID = project.id
        try? modelContext.save()
    }

    func unlink(_ project: LocalProject) {
        guard let deployedProjectID = project.linkedDeployedProjectID else { return }

        // Find and update the DeployedProject
        if let deployedProject = fetchDeployedProject(by: deployedProjectID) {
            deployedProject.linkedLocalProjectID = nil
        }

        project.linkedDeployedProjectID = nil
        try? modelContext.save()
    }

    func unlink(_ deployedProject: DeployedProject) {
        guard let projectID = deployedProject.linkedLocalProjectID else { return }

        // Find and update the LocalProject
        if let project = fetchLocalProject(by: projectID) {
            project.linkedDeployedProjectID = nil
        }

        deployedProject.linkedLocalProjectID = nil
        try? modelContext.save()
    }

    // MARK: - Resolution

    func resolveDeployedProject(for project: LocalProject) -> DeployedProject? {
        guard let deployedProjectID = project.linkedDeployedProjectID else { return nil }
        return fetchDeployedProject(by: deployedProjectID)
    }

    func resolveLocalProject(for deployedProject: DeployedProject) -> LocalProject? {
        guard let projectID = deployedProject.linkedLocalProjectID else { return nil }
        return fetchLocalProject(by: projectID)
    }

    // MARK: - Fetching

    func fetchUnlinkedLocalProjects() -> [LocalProject] {
        let descriptor = FetchDescriptor<LocalProject>(
            predicate: #Predicate { $0.linkedDeployedProjectID == nil }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func fetchUnlinkedDeployedProjects() -> [DeployedProject] {
        let descriptor = FetchDescriptor<DeployedProject>(
            predicate: #Predicate { $0.linkedLocalProjectID == nil }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchAllDeployedProjects() -> [DeployedProject] {
        (try? modelContext.fetch(FetchDescriptor<DeployedProject>())) ?? []
    }

    private func fetchDeployedProject(by id: UUID) -> DeployedProject? {
        let descriptor = FetchDescriptor<DeployedProject>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchLocalProject(by id: UUID) -> LocalProject? {
        let descriptor = FetchDescriptor<LocalProject>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Cleanup

    func cleanupBrokenLinks() {
        let allProjects = (try? modelContext.fetch(FetchDescriptor<LocalProject>())) ?? []
        for project in allProjects {
            // Clear link if DeployedProject doesn't exist OR if project's path is invalid
            if project.linkedDeployedProjectID != nil {
                let siteExists = fetchDeployedProject(by: project.linkedDeployedProjectID!) != nil
                let pathValid = FileManager.default.fileExists(atPath: project.path)
                if !siteExists || !pathValid {
                    project.linkedDeployedProjectID = nil
                }
            }
        }

        let allDeployedProjects = (try? modelContext.fetch(FetchDescriptor<DeployedProject>())) ?? []

        for deployedProject in allDeployedProjects {
            // Case 1: Project has a linked project ID but project no longer exists
            if let projectID = deployedProject.linkedLocalProjectID {
                let project = fetchLocalProject(by: projectID)
                let projectExists = project != nil && FileManager.default.fileExists(atPath: project!.path)

                if !projectExists {
                    deployedProject.linkedLocalProjectID = nil
                }
            }

            // Case 2: Project is completely orphaned (no server AND no local project link)
            if deployedProject.server == nil && deployedProject.linkedLocalProjectID == nil {
                modelContext.delete(deployedProject)
            }
        }

        try? modelContext.save()
    }

    /// Removes LocalProjects whose path no longer exists on disk
    func cleanupOrphanedProjects() {
        let allProjects = (try? modelContext.fetch(FetchDescriptor<LocalProject>())) ?? []

        for project in allProjects {
            let pathExists = FileManager.default.fileExists(atPath: project.path)

            // Delete only if path doesn't exist on disk (folder was deleted/moved)
            guard pathExists else {
                modelContext.delete(project)
                continue
            }
        }

        try? modelContext.save()
        cleanupBrokenLinks()
    }
}
