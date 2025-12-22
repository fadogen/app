import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

private struct ProjectToastData: Equatable {
    let message: String
    let isError: Bool
}

private func triggerGitHubDeployment(
    deployedProject: DeployedProject,
    integration: Integration
) async -> String? {
    guard let owner = deployedProject.githubOwner,
          let repo = deployedProject.githubRepo,
          let token = integration.credentials.token else { return nil }

    do {
        try await GitHubService().triggerWorkflowDispatch(
            owner: owner,
            repo: repo,
            workflow: "deploy.yml",
            ref: deployedProject.gitBranch ?? "main",
            token: token
        )
        return nil
    } catch {
        return error.localizedDescription
    }
}

private struct ProjectToastOverlay: ViewModifier {
    @Binding var toast: ProjectToastData?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    ToastView(message: toast.message, isError: toast.isError)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            Task {
                                try? await Task.sleep(for: .seconds(5))
                                withAnimation { self.toast = nil }
                            }
                        }
                        .padding(.top, 8)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: toast)
    }
}

extension View {
    fileprivate func projectToastOverlay(_ toast: Binding<ProjectToastData?>) -> some View {
        modifier(ProjectToastOverlay(toast: toast))
    }
}

// MARK: - ProjectDetailView

struct ProjectDetailView: View {
    // At least one must be provided (initial values)
    var localProject: LocalProject?
    var deployedProject: DeployedProject?

    // Data passed from parent view to avoid @Query (causes infinite loops in navigation destinations)
    let servers: [Server]
    let allIntegrations: [Integration]
    let deployedProjects: [DeployedProject]
    let userPreferences: [UserPreferences]
    let phpVersions: [PHPVersion]
    let nodeVersions: [NodeVersion]
    let bunVersions: [BunVersion]
    let localProjects: [LocalProject]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var appServices
    @Environment(ProjectLinkingService.self) private var linkingService

    @State private var currentLocalProject: LocalProject?

    @State private var selectedTab: ProjectTab = .development
    @State private var showingLocationPicker = false
    @State private var showingFolderPicker = false
    @State private var showingPathChangePicker = false
    @State private var showingAddIntegration: IntegrationType?
    @State private var showingGitHubPopover = false
    @State private var showingDeployConfirmation = false
    @State private var showingDeleteSheet = false
    @State private var showProductionConfig = false
    @State private var showEnvEditor = false
    @State private var toast: ProjectToastData?

    // MARK: - Derived

    private var effectiveLocalProject: LocalProject? {
        guard let project = currentLocalProject ?? localProject else { return nil }
        // Validate project still exists on disk (handles rename/move/delete)
        guard FileManager.default.fileExists(atPath: project.path) else { return nil }
        return project
    }

    private var effectiveDeployedProject: DeployedProject? {
        if let deployedProject = deployedProject {
            return deployedProject
        }
        guard let project = effectiveLocalProject, let linkedID = project.linkedDeployedProjectID else {
            return nil
        }
        return deployedProjects.first { $0.id == linkedID }
    }

    private var projectName: String {
        effectiveLocalProject?.name ?? deployedProject?.name ?? "Unknown"
    }

    private var githubIdentifier: String? {
        effectiveLocalProject?.githubIdentifier ?? deployedProject?.githubIdentifier
    }

    private var gitHubURL: URL? {
        effectiveLocalProject?.gitHubURL ?? deployedProject?.gitHubURL
    }

    private var githubIntegration: Integration? {
        allIntegrations.first { $0.type == .github }
    }

    private var hasLocalPath: Bool {
        guard let project = effectiveLocalProject else { return false }
        return FileManager.default.fileExists(atPath: project.path)
    }

    enum ProjectTab: String, CaseIterable {
        case development
        case production

        var localizedName: String {
            switch self {
            case .development: String(localized: "Development")
            case .production: String(localized: "Production")
            }
        }
    }

    // MARK: - Body

    var body: some View {
        Form {
            switch selectedTab {
            case .development:
                developmentContent
            case .production:
                ProductionStatusView(
                    project: effectiveLocalProject,
                    deployedProject: effectiveDeployedProject,
                    onConfigureProduction: {
                        showProductionConfig = true
                    },
                    allIntegrations: allIntegrations
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle(projectName)
        .projectToastOverlay($toast)
        .navigationDestination(isPresented: $showProductionConfig) {
            productionConfigDestination
        }
        .navigationDestination(isPresented: $showEnvEditor) {
            if let deployedProject = effectiveDeployedProject {
                EnvEditorView(deployedProject: deployedProject, project: effectiveLocalProject, githubIntegration: githubIntegration)
            }
        }
        .toolbar {
            toolbarContent
        }
        .fileImporter(
            isPresented: $showingLocationPicker,
            allowedContentTypes: [.folder]
        ) { result in
            handleLocationPickerResult(result)
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderLinkingResult(result)
        }
        .fileImporter(
            isPresented: $showingPathChangePicker,
            allowedContentTypes: [.folder]
        ) { result in
            handlePathChangeResult(result)
        }
        .sheet(item: $showingAddIntegration) { type in
            IntegrationSheet(adding: type)
        }
        .sheet(isPresented: $showingGitHubPopover) {
            if let project = effectiveLocalProject, let integration = githubIntegration {
                GitHubRepoCreationSheet(
                    project: project,
                    integration: integration
                )
            }
        }
        .sheet(isPresented: $showingDeleteSheet) {
            deletionSheet
        }
        .alert("Deploy to Production", isPresented: $showingDeployConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Deploy") {
                if let integration = githubIntegration, let deployedProject = effectiveDeployedProject {
                    triggerDeploy(deployedProject: deployedProject, integration: integration)
                }
            }
        } message: {
            if let deployedProject = effectiveDeployedProject, let repo = deployedProject.githubRepo {
                let branch = deployedProject.gitBranch ?? "main"
                Text("This will trigger a GitHub Actions deployment for \(repo) on branch \(branch).")
            }
        }
        .task {
            await initializeView()
        }
        .onChange(of: effectiveDeployedProject?.deploymentStatus) { _, newStatus in
            if let status = newStatus, status == .deploying || status == .failed {
                selectedTab = .production
            }
        }
    }

    // MARK: - Development Tab Content

    @ViewBuilder
    private var developmentContent: some View {
        if let project = effectiveLocalProject {
            DevelopmentConfigurationView(
                project: project,
                onOpenInFinder: openInFinder,
                onChangePath: { showingPathChangePicker = true },
                phpVersions: phpVersions,
                nodeVersions: nodeVersions,
                bunVersions: bunVersions
            )
        } else {
            notAvailableLocallyView
        }
    }

    @ViewBuilder
    private var notAvailableLocallyView: some View {
        Section("Local Development") {
            VStack(spacing: 12) {
                Label("Not available locally", systemImage: "folder.badge.questionmark")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("Link this deployment to a local folder to configure development settings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showingFolderPicker = true
                } label: {
                    Label("Link to Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Production Config Destination

    @ViewBuilder
    private var productionConfigDestination: some View {
        if let project = effectiveLocalProject {
            ProductionConfigurationView(
                project: project,
                deployedProject: effectiveDeployedProject,
                servers: servers,
                allIntegrations: allIntegrations,
                deployedProjects: deployedProjects,
                userPreferences: userPreferences
            )
        } else if let deployedProject = deployedProject {
            ProductionConfigurationView(
                deployedProject: deployedProject,
                servers: servers,
                allIntegrations: allIntegrations,
                deployedProjects: deployedProjects,
                userPreferences: userPreferences
            )
        }
    }

    // MARK: - Deletion Sheet

    @ViewBuilder
    private var deletionSheet: some View {
        if let project = effectiveLocalProject {
            ProjectDeletionSheet(project: project, deployedProject: effectiveDeployedProject) {
                dismiss()
            }
        } else if let deployedProject = deployedProject {
            ProjectDeletionSheet(deployedProject: deployedProject) {
                dismiss()
            }
        } else {
            // Fallback: stale state - just dismiss
            EmptyView()
                .onAppear {
                    showingDeleteSheet = false
                    dismiss()
                }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Segmented picker (always visible)
        ToolbarItem(placement: .principal) {
            Picker(selection: $selectedTab) {
                ForEach(ProjectTab.allCases, id: \.self) { tab in
                    Text(tab.localizedName).tag(tab)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible, placement: .automatic)
        }

        // Delete button (always visible)
        ToolbarItem(placement: .automatic) {
            Button(role: .destructive) {
                showingDeleteSheet = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .automatic)
        }

        // GitHub button
        if let project = effectiveLocalProject, hasLocalPath || project.gitHubURL != nil {
            ToolbarItem(placement: .automatic) {
                GitHubToolbarButton(
                    project: project,
                    githubIntegration: githubIntegration,
                    showingAddIntegration: $showingAddIntegration,
                    showingGitHubPopover: $showingGitHubPopover
                )
            }
        } else if effectiveLocalProject == nil, let url = gitHubURL {
            // Remote-only: simple GitHub link
            ToolbarItem(placement: .automatic) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label {
                        Text("Open on GitHub")
                    } icon: {
                        Image("github")
                            .renderingMode(.template)
                    }
                }
                .help("Open repository on GitHub")
            }
        }

        // Deploy button (if deployed + GitHub configured)
        if let deployedProject = effectiveDeployedProject,
           deployedProject.deploymentStatus == .deployed,
           deployedProject.githubOwner != nil,
           deployedProject.githubRepo != nil,
           githubIntegration != nil {
            ToolbarItem(placement: .automatic) {
                Button {
                    showingDeployConfirmation = true
                } label: {
                    Label("Deploy", systemImage: "arrow.up.circle.fill")
                }
                .help("Trigger GitHub Actions deployment")
            }
        }

        // Environment editor button (Production tab only, when env content exists)
        if selectedTab == .production, let deployedProject = effectiveDeployedProject, deployedProject.envProductionContent != nil {
            ToolbarItem(placement: .automatic) {
                Button {
                    showEnvEditor = true
                } label: {
                    Label("Production Environment", systemImage: "doc.badge.gearshape.fill")
                }
                .help("Edit production environment variables")
            }
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .automatic)
        }

        // Contextual action button
        ToolbarItem(placement: .automatic) {
            contextualActionButton
        }
    }

    @ViewBuilder
    private var contextualActionButton: some View {
        switch selectedTab {
        case .development:
            if effectiveLocalProject != nil {
                Button {
                    openInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
            } else {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("Link Folder", systemImage: "folder.badge.plus")
                }
            }
        case .production:
            if let deployedProject = effectiveDeployedProject, deployedProject.server != nil && deployedProject.deploymentStatus == .deployed {
                Button {
                    showProductionConfig = true
                } label: {
                    Label("Configure Production", systemImage: "pencil")
                }
            } else if effectiveDeployedProject == nil || effectiveDeployedProject?.server == nil {
                // Show configure button for initial setup (only if GitHub prerequisites met)
                if githubIdentifier != nil && githubIntegration != nil {
                    Button {
                        showProductionConfig = true
                    } label: {
                        Label("Configure Production", systemImage: "gearshape.fill")
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func openInFinder() {
        guard let project = effectiveLocalProject else { return }

        if FileManager.default.fileExists(atPath: project.path) {
            NSWorkspace.shared.selectFile(project.path, inFileViewerRootedAtPath: "")
        } else {
            // Path doesn't exist, offer to relocate
            showingLocationPicker = true
        }
    }

    private func triggerDeploy(deployedProject: DeployedProject, integration: Integration) {
        Task {
            if let error = await triggerGitHubDeployment(deployedProject: deployedProject, integration: integration) {
                withAnimation { toast = ProjectToastData(message: error, isError: true) }
            } else {
                withAnimation { toast = ProjectToastData(message: "Deployment triggered successfully", isError: false) }
            }
        }
    }

    private func initializeView() async {
        // Guard: if both are nil, this is stale navigation state - dismiss
        guard localProject != nil || deployedProject != nil else {
            dismiss()
            return
        }

        // Set initial tab based on current deployment status
        if let deployedProject = effectiveDeployedProject {
            if deployedProject.deploymentStatus == .deploying || deployedProject.deploymentStatus == .failed {
                selectedTab = .production
            }
        }

        // For remote-only, default to production tab
        if effectiveLocalProject == nil {
            selectedTab = .production
        }

        // Check if linked GitHub repository still exists (for local projects)
        await checkGitHubRepositoryExists()
    }

    /// Check if linked GitHub repository still exists
    /// Reset gitRemoteURL and gitBranch if repo was deleted (404)
    private func checkGitHubRepositoryExists() async {
        guard let project = effectiveLocalProject,
              let owner = project.githubOwner,
              let repo = project.githubRepo,
              let token = githubIntegration?.credentials.token else {
            return
        }

        // Use try? for fail-safe: don't reset on network errors
        if let isAvailable = try? await GitHubService().checkRepositoryAvailability(
            owner: owner,
            repoName: repo,
            token: token
        ), isAvailable {
            project.gitRemoteURL = nil
            project.gitBranch = nil
            try? modelContext.save()
        }
    }

    // MARK: - File Importer Handlers

    /// Handle location picker for relocating existing project
    private func handleLocationPickerResult(_ result: Result<URL, Error>) {
        guard let project = effectiveLocalProject else { return }

        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            // Restore .env.production from backup if available
            if let deployedProject = effectiveDeployedProject, let envContent = deployedProject.envProductionContent {
                let envProductionURL = url.appendingPathComponent(".env.production")
                if !FileManager.default.fileExists(atPath: envProductionURL.path) {
                    try? envContent.write(to: envProductionURL, atomically: true, encoding: .utf8)
                }
            }

            // Re-detect Git repository when path changes
            if let repo = try? project.detectGitRepository() {
                project.gitRemoteURL = repo.remoteURL
                project.gitBranch = repo.branch
            }

            try? modelContext.save()
            appServices.caddyConfig.reconcile(project: project)

        case .failure(let error):
            withAnimation {
                toast = ProjectToastData(message: error.localizedDescription, isError: true)
            }
        }
    }

    /// Handle folder picker for linking remote project to local folder
    private func handleFolderLinkingResult(_ result: Result<[URL], Error>) {
        guard let deployedProject = deployedProject ?? effectiveDeployedProject else { return }

        switch result {
        case .success(let urls):
            guard let folderURL = urls.first else { return }
            let path = folderURL.path

            // Check if a LocalProject already exists at this path
            if let existingProject = localProjects.first(where: { $0.path == path }) {
                linkingService.link(existingProject, to: deployedProject)
                // Update current project to refresh the view
                currentLocalProject = existingProject
                // Refresh Caddy for the linked project
                appServices.caddyConfig.reconcile(project: existingProject)
                withAnimation {
                    toast = ProjectToastData(message: "Linked to existing project '\(existingProject.name)'", isError: false)
                }
            } else {
                // Create a new LocalProject and link it
                let projectName = folderURL.lastPathComponent

                guard let newProject = LocalProject(name: projectName, path: path) else {
                    withAnimation {
                        toast = ProjectToastData(message: "Invalid project name: '\(projectName)'", isError: true)
                    }
                    return
                }

                // Ensure unique localURL (may append suffix if taken)
                if let uniqueHostname = modelContext.findUniqueHostname(projectName) {
                    newProject.localURL = "https://\(uniqueHostname).localhost"
                }

                // Try to detect Git repository info
                if let repo = try? newProject.detectGitRepository() {
                    newProject.gitRemoteURL = repo.remoteURL
                    newProject.gitBranch = repo.branch
                }

                modelContext.insert(newProject)
                linkingService.link(newProject, to: deployedProject)
                // Update current project to refresh the view
                currentLocalProject = newProject
                // Refresh Caddy for the new project
                appServices.caddyConfig.reconcile(project: newProject)

                withAnimation {
                    toast = ProjectToastData(message: "Created and linked project '\(projectName)'", isError: false)
                }
            }

        case .failure(let error):
            withAnimation {
                toast = ProjectToastData(message: error.localizedDescription, isError: true)
            }
        }
    }

    /// Handle path change for existing project
    private func handlePathChangeResult(_ result: Result<URL, Error>) {
        guard let project = currentLocalProject ?? localProject else { return }

        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            let newPath = url.path
            let newName = url.lastPathComponent

            // Capture old state before modifications
            let oldPath = project.path
            let wasInWatchedDir = project.watchedDirectory != nil

            // Update project path and name
            project.path = newPath
            project.name = newName

            // Update watchedDirectory relationship based on new path
            // If new path is within a WatchedDirectory, associate with it; otherwise standalone
            let watchedDirs = (try? modelContext.fetch(FetchDescriptor<WatchedDirectory>())) ?? []
            let matchingDir = watchedDirs.first { dir in
                // Check if newPath is a direct child of the watched directory
                let parentPath = URL(fileURLWithPath: newPath).deletingLastPathComponent().path
                return parentPath == dir.path
            }
            project.watchedDirectory = matchingDir
            let isNowStandalone = matchingDir == nil

            // Update localURL based on new name (with uniqueness check)
            if let uniqueHostname = modelContext.findUniqueHostname(newName, excludingProjectID: project.id) {
                project.localURL = "https://\(uniqueHostname).localhost"
            }

            // Re-detect Git repository
            if let repo = try? project.detectGitRepository() {
                project.gitRemoteURL = repo.remoteURL
                project.gitBranch = repo.branch
            } else {
                project.gitRemoteURL = nil
                project.gitBranch = nil
            }

            // Re-detect framework
            project.detectFramework()

            try? modelContext.save()
            appServices.caddyConfig.reconcile(project: project)

            // Warn if old folder still exists in watched directory (will become separate project)
            let oldFolderStillExists = FileManager.default.fileExists(atPath: oldPath)
            let willCreateDuplicate = wasInWatchedDir && isNowStandalone && oldFolderStillExists && oldPath != newPath

            let message = willCreateDuplicate
                ? "Path updated. Note: '\(URL(fileURLWithPath: oldPath).lastPathComponent)' still exists and will appear as a separate project."
                : "Path updated to '\(newName)'"

            withAnimation {
                toast = ProjectToastData(message: message, isError: false)
            }

        case .failure(let error):
            withAnimation {
                toast = ProjectToastData(message: error.localizedDescription, isError: true)
            }
        }
    }
}

// MARK: - Toast View

private struct ToastView: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(message)
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}

