import SwiftUI
import SwiftData
import AppKit

/// Scope of project deletion
enum ProjectDeletionScope: String, CaseIterable, Identifiable {
    case localOnly = "local"
    case remoteOnly = "remote"
    case both = "both"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localOnly: "Delete Locally"
        case .remoteOnly: "Remove from Production"
        case .both: "Delete Everything"
        }
    }

    var icon: String {
        switch self {
        case .localOnly: "folder.badge.minus"
        case .remoteOnly: "icloud.slash"
        case .both: "trash"
        }
    }
}

/// Sheet for project deletion with scope selection and confirmation
/// Supports two modes:
/// 1. LocalProject + optional DeployedProject (full options)
/// 2. DeployedProject only (remote-only deletion)
struct ProjectDeletionSheet: View {
    let project: LocalProject?
    let deployedProject: DeployedProject?
    var onSiteDeleted: (() -> Void)?

    /// Convenience initializer for LocalProject with optional DeployedProject
    init(project: LocalProject, deployedProject: DeployedProject?, onSiteDeleted: (() -> Void)? = nil) {
        self.project = project
        self.deployedProject = deployedProject
        self.onSiteDeleted = onSiteDeleted
    }

    /// Convenience initializer for remote-only DeployedProject
    init(deployedProject: DeployedProject, onSiteDeleted: (() -> Void)? = nil) {
        self.project = nil
        self.deployedProject = deployedProject
        self.onSiteDeleted = onSiteDeleted
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DNSManager.self) private var dnsManager

    @Query(sort: \Integration.createdAt) private var allIntegrations: [Integration]

    @State private var selectedScope: ProjectDeletionScope?
    @State private var showingConfirmation = false
    @State private var deletionInProgress = false
    @State private var deletionPhase: String?
    @State private var deletionError: Error?
    @State private var showingErrorAlert = false

    // Cached project properties (captured on appear to avoid SwiftData detachment issues)
    @State private var cachedProjectID: UUID?
    @State private var cachedCanDeleteRemotely = false
    @State private var cachedHasDNSRecords = false
    @State private var cachedHasGitHub = false
    @State private var cachedDNSRecordIDs: [String] = []
    @State private var cachedDNSZoneID: String?
    @State private var cachedDNSZoneName: String?
    @State private var cachedDNSIntegration: Integration?
    @State private var cachedGitHubOwner: String?
    @State private var cachedGitHubRepo: String?
    @State private var cachedIsDeploying = false
    @State private var cachedTunnelID: String?
    @State private var cachedTunnelIntegration: Integration?
    @State private var cachedProductionDomain: String?

    // MARK: - Computed Properties

    /// Display name (from project or deployed project)
    private var projectName: String {
        project?.name ?? deployedProject?.name ?? "Unknown"
    }

    /// Local folder path (nil for remote-only)
    private var projectPath: String? {
        project?.path
    }

    private var canDeleteLocally: Bool {
        guard let path = projectPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private var canDeleteRemotely: Bool {
        cachedCanDeleteRemotely
    }

    private var githubIntegration: Integration? {
        allIntegrations.first { $0.type == .github }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
            if deletionInProgress {
                deletionProgressView
            } else {
                scopeSelectionView
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 420)
        .fixedSize(horizontal: true, vertical: true)
        .confirmationDialog(
            "Confirm Deletion",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                performDeletion()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .alert("Deletion Failed", isPresented: $showingErrorAlert, presenting: deletionError) { _ in
            Button("Retry") {
                performDeletion()
            }
            Button("Cancel", role: .cancel) {
                deletionError = nil
            }
        } message: { error in
            Text(error.localizedDescription)
        }
        .onAppear {
            // Cache all project properties upfront to avoid SwiftData detachment issues during deletion
            guard let deployedProject = deployedProject else { return }
            cachedProjectID = deployedProject.id
            cachedCanDeleteRemotely = deployedProject.server != nil || !deployedProject.createdDNSRecordIDs.isEmpty || deployedProject.deploymentStatus == .deployed
            cachedHasDNSRecords = !deployedProject.createdDNSRecordIDs.isEmpty
            cachedHasGitHub = deployedProject.githubOwner != nil
            cachedDNSRecordIDs = deployedProject.createdDNSRecordIDs
            cachedDNSZoneID = deployedProject.dnsZoneID
            cachedDNSZoneName = deployedProject.dnsZoneName
            cachedDNSIntegration = deployedProject.dnsIntegration
            cachedGitHubOwner = deployedProject.githubOwner
            cachedGitHubRepo = deployedProject.githubRepo
            cachedIsDeploying = deployedProject.deploymentStatus == .deploying
            cachedProductionDomain = deployedProject.productionDomain
            if let server = deployedProject.server,
               let tunnel = server.cloudflareTunnel {
                cachedTunnelID = tunnel.tunnelID
                cachedTunnelIntegration = tunnel.integration
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "trash.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Delete \"\(projectName)\"")
                .font(.headline)

            if cachedIsDeploying {
                Label("Deployment in progress", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Scope Selection

    private var scopeSelectionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What would you like to delete?")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                // Local option (only shown when project exists)
                if project != nil {
                    scopeOption(
                        scope: .localOnly,
                        enabled: canDeleteLocally,
                        description: localDescription,
                        disabledReason: "No local folder available"
                    )
                }

                // Remote option
                scopeOption(
                    scope: .remoteOnly,
                    enabled: canDeleteRemotely,
                    description: remoteDescription,
                    disabledReason: "Project is not deployed"
                )

                // Both option (only when both project and remote exist)
                if canDeleteLocally && canDeleteRemotely {
                    scopeOption(
                        scope: .both,
                        enabled: true,
                        description: "Delete local folder and remove from production",
                        disabledReason: nil
                    )
                }
            }
        }
        .padding(20)
    }

    private func scopeOption(
        scope: ProjectDeletionScope,
        enabled: Bool,
        description: String,
        disabledReason: String?
    ) -> some View {
        Button {
            selectedScope = scope
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedScope == scope ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selectedScope == scope ? .blue : .secondary)

                Image(systemName: scope.icon)
                    .font(.title3)
                    .foregroundStyle(enabled ? .primary : .tertiary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(scope.title)
                        .font(.body)
                        .foregroundStyle(enabled ? .primary : .tertiary)

                    Text(enabled ? description : disabledReason ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedScope == scope ? Color.blue.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selectedScope == scope ? Color.blue : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Descriptions

    private var localDescription: String {
        guard let path = projectPath else { return "No local folder" }
        return "Delete folder at \(path)"
    }

    private var remoteDescription: String {
        guard cachedCanDeleteRemotely else { return "Not deployed" }

        var parts: [String] = []
        if cachedHasDNSRecords {
            parts.append("DNS records")
        }
        if cachedHasGitHub {
            parts.append("GitHub secrets")
        }
        parts.append("deployment config")
        return "Remove \(parts.joined(separator: ", "))"
    }

    // MARK: - Confirmation Message

    private var confirmationMessage: String {
        guard let scope = selectedScope else { return "" }

        var lines: [String] = []

        switch scope {
        case .localOnly:
            if let path = projectPath {
                lines.append("The folder at \(path) will be permanently deleted.")
            }

        case .remoteOnly:
            if cachedHasDNSRecords {
                lines.append("DNS records will be deleted.")
            }
            if cachedHasGitHub {
                lines.append("GitHub Actions secrets will be deleted.")
            }
            lines.append("Deployment configuration will be reset.")
            lines.append("")
            lines.append("Note: Docker containers on the server will NOT be deleted. You will need to remove them manually if needed.")

        case .both:
            if let path = projectPath {
                lines.append("The folder at \(path) will be permanently deleted.")
            }
            if cachedHasDNSRecords {
                lines.append("DNS records will be deleted.")
            }
            if cachedHasGitHub {
                lines.append("GitHub Actions secrets will be deleted.")
            }
            lines.append("")
            lines.append("Note: Docker containers on the server will NOT be deleted.")
        }

        lines.append("")
        lines.append("This action cannot be undone.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Deletion Progress

    private var deletionProgressView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .progressViewStyle(.circular)

            Text(deletionPhase ?? "Preparing deletion...")
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.escape)

            Spacer()

            Button("Continue") {
                showingConfirmation = true
            }
            .keyboardShortcut(.return)
            .disabled(selectedScope == nil)
        }
        .padding(16)
    }

    // MARK: - Deletion Logic

    private func performDeletion() {
        guard let scope = selectedScope else { return }

        deletionInProgress = true

        // Use cached project ID to avoid SwiftData detachment issues
        let siteID = cachedProjectID

        Task {
            do {
                switch scope {
                case .localOnly:
                    try await deleteLocally()

                case .remoteOnly:
                    try await deleteRemotely()

                case .both:
                    // Delete remote first (needs project properties), then local folder
                    try await deleteRemotely()
                    try await deleteLocally()
                }

                // Delete models from SwiftData as appropriate
                await MainActor.run {
                    // Re-fetch DeployedProject by ID to get a valid context reference
                    let projectToDelete: DeployedProject? = {
                        guard let id = siteID else { return nil }
                        let descriptor = FetchDescriptor<DeployedProject>(
                            predicate: #Predicate { $0.id == id }
                        )
                        return try? modelContext.fetch(descriptor).first
                    }()

                    switch scope {
                    case .localOnly:
                        // Delete LocalProject (requires project to exist)
                        if let project {
                            modelContext.delete(project)
                        }
                        try? modelContext.save()
                        dismiss()
                        onSiteDeleted?()

                    case .remoteOnly:
                        // Clear link on LocalProject if exists
                        project?.linkedDeployedProjectID = nil
                        // Delete DeployedProject
                        if let deployedProject = projectToDelete {
                            modelContext.delete(deployedProject)
                        }
                        try? modelContext.save()
                        dismiss()
                        onSiteDeleted?()

                    case .both:
                        // Delete LocalProject if exists
                        if let project {
                            modelContext.delete(project)
                        }
                        // Delete DeployedProject
                        if let deployedProject = projectToDelete {
                            modelContext.delete(deployedProject)
                        }
                        try? modelContext.save()
                        dismiss()
                        onSiteDeleted?()
                    }
                }
            } catch {
                await MainActor.run {
                    deletionInProgress = false
                    deletionError = error
                    showingErrorAlert = true
                }
            }
        }
    }

    private func deleteLocally() async throws {
        guard let path = projectPath else { return }

        await MainActor.run {
            deletionPhase = "Deleting local folder..."
        }

        try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
    }

    private func deleteRemotely() async throws {
        // Use cached values to avoid SwiftData detachment issues
        let dnsRecordIDs = cachedDNSRecordIDs
        let zoneID = cachedDNSZoneID
        let zoneName = cachedDNSZoneName
        let dnsIntegration = cachedDNSIntegration
        let owner = cachedGitHubOwner
        let repo = cachedGitHubRepo
        let ghIntegration = githubIntegration

        // Phase 1: Delete DNS records
        if !dnsRecordIDs.isEmpty,
           let zoneID,
           let zoneName,
           let integration = dnsIntegration {

            await MainActor.run {
                deletionPhase = "Deleting DNS records..."
            }

            let zone = DNSZone(name: zoneName, id: zoneID, integration: integration)

            // List all records in the zone
            if let allRecords = try? await dnsManager.listRecords(in: zone, type: nil, name: nil) {
                // Protected record types that should NEVER be deleted
                let protectedTypes = ["NS", "SOA"]

                // Delete only records created by Fadogen (tracked IDs)
                for record in allRecords where dnsRecordIDs.contains(record.id) {
                    // Additional safety check: never delete NS/SOA records
                    guard !protectedTypes.contains(record.type) else { continue }

                    try? await dnsManager.deleteRecord(record, in: zone)
                }
            }
        }

        // Phase 1.5: Remove Cloudflare Tunnel HTTP route
        if let productionDomain = cachedProductionDomain,
           let tunnelID = cachedTunnelID {

            await MainActor.run {
                deletionPhase = "Removing tunnel route..."
            }

            // Get integration from tunnel, or fallback to fetching Cloudflare integration
            let integration: Integration? = cachedTunnelIntegration ?? allIntegrations.first { $0.type == .cloudflare }

            if let integration,
               let email = integration.credentials.email,
               let apiKey = integration.credentials.globalAPIKey {

                let cloudflareService = CloudflareService()
                if let accountID = try? await cloudflareService.getAccountID(integration: integration) {
                    try? await cloudflareService.removeHTTPRouteFromTunnel(
                        tunnelID: tunnelID,
                        hostname: productionDomain,
                        accountID: accountID,
                        email: email,
                        apiKey: apiKey
                    )
                }
            }
        }

        // Phase 2: Delete GitHub Actions secrets
        if let owner,
           let repo,
           let integration = ghIntegration {

            await MainActor.run {
                deletionPhase = "Deleting GitHub secrets..."
            }

            let githubSecretsService = GitHubSecretsService()
            try? await githubSecretsService.deleteDeploymentSecrets(
                owner: owner,
                repo: repo,
                integration: integration
            )
        }

        // Phase 3: Clear production configuration (re-fetch project by ID)
        await MainActor.run {
            deletionPhase = "Clearing configuration..."
            if let deployedProjectID = cachedProjectID {
                let descriptor = FetchDescriptor<DeployedProject>(
                    predicate: #Predicate { $0.id == deployedProjectID }
                )
                if let deployedProject = try? modelContext.fetch(descriptor).first {
                    deployedProject.clearProductionConfiguration()
                }
            }
        }
    }
}
