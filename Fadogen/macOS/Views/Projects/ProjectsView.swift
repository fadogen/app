import SwiftUI
import SwiftData

struct ProjectsView: View {
    @Binding var navigationPath: NavigationPath
    @Query(sort: [SortDescriptor(\LocalProject.name, comparator: .localizedStandard)]) private var projects: [LocalProject]
    @Query(sort: [SortDescriptor(\DeployedProject.name, comparator: .localizedStandard)]) private var deployedProjects: [DeployedProject]
    @Query private var servers: [Server]
    @Query(sort: \Integration.createdAt) private var allIntegrations: [Integration]
    @Query private var userPreferences: [UserPreferences]
    @Query(sort: \PHPVersion.major) private var phpVersions: [PHPVersion]
    @Query(sort: \NodeVersion.major) private var nodeVersions: [NodeVersion]
    @Query private var bunVersions: [BunVersion]
    @State private var showingManageSheet = false
    @State private var hoveredID: String?

    /// LocalProjects with valid paths (folder exists on disk)
    /// Filters out stale projects from renamed/moved/deleted folders
    private var validProjects: [LocalProject] {
        projects.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// DeployedProjects that have no linked LocalProject (remote-only)
    /// Uses validProjects to ensure stale links are treated as orphaned
    private var orphanedDeployedProjects: [DeployedProject] {
        let linkedIDs = Set(validProjects.compactMap { $0.linkedDeployedProjectID })
        return deployedProjects.filter { !linkedIDs.contains($0.id) }
    }

    /// Get linked DeployedProject for a project
    private func linkedDeployedProject(for project: LocalProject) -> DeployedProject? {
        guard let linkedID = project.linkedDeployedProjectID else { return nil }
        return deployedProjects.first { $0.id == linkedID }
    }

    var body: some View {
        Group {
            if validProjects.isEmpty && orphanedDeployedProjects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a directory to watch for projects")
                } actions: {
                    Button("Manage Directories") {
                        showingManageSheet = true
                    }
                }
            } else {
                List {
                    // Orphaned deployed projects section (remote-only) - shown first
                    if !orphanedDeployedProjects.isEmpty {
                        Section("Deployed (Remote Only)") {
                            ForEach(orphanedDeployedProjects) { deployedProject in
                                NavigationLink(value: ProjectDestination.remote(deployedProject)) {
                                    DeployedProjectRow(deployedProject: deployedProject)
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .hoverableRow(hoveredID: $hoveredID, versionID: deployedProject.id.uuidString)
                            }
                        }
                    }

                    // Local projects section (only valid paths)
                    if !validProjects.isEmpty {
                        Section("Local Projects") {
                            ForEach(validProjects) { project in
                                NavigationLink(value: ProjectDestination.local(project, linkedSite: linkedDeployedProject(for: project))) {
                                    ProjectRow(project: project, deployedProjects: deployedProjects)
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .hoverableRow(hoveredID: $hoveredID, versionID: project.id.uuidString)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showingManageSheet = true
                } label: {
                    Label("Manage Directories", systemImage: "folder")
                }
            }

            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            }

            ToolbarItem {
                Button {
                    navigationPath.append(ProjectDestination.newProject)
                } label: {
                    Label("New Project", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingManageSheet) {
            ManageDirectoriesSheet()
        }
        .navigationDestination(for: ProjectDestination.self) { destination in
            switch destination {
            case .newProject:
                NewProjectView(navigationPath: $navigationPath)
            case .projectDetail(let localProject, let deployedProject):
                ProjectDetailView(
                    localProject: localProject,
                    deployedProject: deployedProject,
                    servers: servers,
                    allIntegrations: allIntegrations,
                    deployedProjects: deployedProjects,
                    userPreferences: userPreferences,
                    phpVersions: phpVersions,
                    nodeVersions: nodeVersions,
                    bunVersions: bunVersions,
                    localProjects: projects
                )
            }
        }
        .navigationDestination(for: Server.self) { server in
            ServerDetailView(server: server)
        }
    }
}

struct ProjectRow: View {
    let project: LocalProject
    let deployedProjects: [DeployedProject]

    /// Get linked DeployedProject if exists
    private var linkedDeployedProject: DeployedProject? {
        guard let linkedID = project.linkedDeployedProjectID else { return nil }
        return deployedProjects.first { $0.id == linkedID }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(project.name)
                .font(.body)
                .fontWeight(.medium)

            Spacer()

            // Dynamic icon badges (right-aligned, trailing edge)
            HStack(spacing: 6) {
                // Framework icon
                if let framework = project.framework {
                    Image(framework.rawValue)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.primary)
                        .help("\(framework.rawValue.capitalized) framework")
                }

                // Deployment status icon (from linked DeployedProject)
                if let deployedProject = linkedDeployedProject, deployedProject.deploymentStatus == .deployed {
                    Image(systemName: "globe")
                        .imageScale(.small)
                        .foregroundStyle(.primary)
                        .help("Deployed to production")
                }

                // Local availability icon (different icon for standalone vs watched)
                if FileManager.default.fileExists(atPath: project.path) {
                    if project.watchedDirectory == nil {
                        Image(systemName: "link")
                            .imageScale(.small)
                            .foregroundStyle(.primary)
                            .help("Standalone project")
                    } else {
                        Image(systemName: "folder.fill")
                            .imageScale(.small)
                            .foregroundStyle(.primary)
                            .help("Available locally")
                    }
                }

                // Git/GitHub icon
                if project.gitRemoteURL != nil {
                    Image("github")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.primary)
                        .help("Git repository configured")
                }
            }

            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

struct DeployedProjectRow: View {
    let deployedProject: DeployedProject

    var body: some View {
        HStack(spacing: 12) {
            Text(deployedProject.name)
                .font(.body)
                .fontWeight(.medium)

            Spacer()

            // Dynamic icon badges
            HStack(spacing: 6) {
                // Deployment status icon
                if deployedProject.deploymentStatus == .deployed {
                    Image(systemName: "globe")
                        .imageScale(.small)
                        .foregroundStyle(.primary)
                        .help("Deployed to production")
                } else if deployedProject.deploymentStatus == .deploying {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Deployment in progress")
                } else if deployedProject.deploymentStatus == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                        .help("Deployment failed")
                }

                // Git/GitHub icon
                if deployedProject.gitRemoteURL != nil {
                    Image("github")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.primary)
                        .help("Git repository")
                }
            }

            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}
