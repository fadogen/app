import SwiftUI
import SwiftData

struct ProductionStatusView: View {
    let project: LocalProject?
    let deployedProject: DeployedProject?
    var onConfigureProduction: () -> Void

    // Data passed from parent to avoid @Query (causes infinite loops in navigation destinations)
    let allIntegrations: [Integration]

    @Environment(DNSManager.self) private var dnsManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.navigateToSection) private var navigateToSection

    private var deploymentStatus: ProjectDeploymentStatus {
        deployedProject?.deploymentStatus ?? .notDeployed
    }

    var body: some View {
        Section(sectionTitle) {
            switch deploymentStatus {
            case .deploying, .failed:
                // Deployment in progress or failed - show logs view
                if let deployedProject = deployedProject {
                    DeploymentLogsView(
                        project: project,
                        deployedProject: deployedProject,
                        onRetry: onConfigureProduction
                    )
                }

            case .notDeployed:
                // Check GitHub requirements before allowing deployment
                VStack(spacing: 12) {
                    if !isGitHubRepo {
                        // State 1: No GitHub repository
                        Label("GitHub Repository Required", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(.orange)

                        Text("Initialize a Git repository with GitHub remote to deploy this project")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                    } else if githubIntegration == nil {
                        // State 2: GitHub repo without integration
                        Label("GitHub Integration Required", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(.orange)

                        Text("Add a GitHub integration to enable automated deployment")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            navigateToSection(.integrations)
                        } label: {
                            Label("Go to Integrations", systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)

                    } else {
                        // State 3: All GitHub prerequisites OK
                        Label("No Server Linked", systemImage: "server.rack")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Text("Link this project to a server to deploy to production")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            onConfigureProduction()
                        } label: {
                            Label("Link to Server", systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

            case .deployed:
                // Configured state - show visual cards
                if let deployedProject = deployedProject {
                    deploymentStatusCards(deployedProject: deployedProject)
                }
            }
        }
        .task {
            // Auto-cleanup orphaned deployment state (server deleted externally)
            if let deployedProject = deployedProject, deployedProject.deploymentStatus == .deployed && deployedProject.server == nil {
                await cleanupOrphanedState(deployedProject: deployedProject)
            }
        }
    }

    @ViewBuilder
    private func deploymentStatusCards(deployedProject: DeployedProject) -> some View {
        // 1. Domain (most important - first)
        if let domain = deployedProject.productionDomain {
            Link(destination: URL(string: "https://\(domain)")!) {
                HStack {
                    Text("https://\(domain)")
                        .font(.body)
                        .foregroundStyle(.link)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }

        // 2. Server (clickable to navigate)
        if let server = deployedProject.server {
            NavigationLink(value: server) {
                HStack(spacing: 12) {
                    if let integration = server.integration {
                        Image(integration.type.metadata.assetName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "server.rack")
                            .frame(width: 20, height: 20)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name ?? "Server")
                            .font(.body)
                        if let host = server.host {
                            Text(host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }

        // 3. Backup provider
        HStack {
            Label("Backup", systemImage: "externaldrive.badge.timemachine")
                .font(.subheadline)
            Spacer()
            if let backup = deployedProject.backupIntegration {
                HStack(spacing: 6) {
                    Image(backup.type.metadata.assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    Text(backup.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Not configured")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Deployment Status Helpers

    private var sectionTitle: String {
        switch deploymentStatus {
        case .notDeployed:
            return "Link to Server"
        case .deploying:
            return "Setting up production..."
        case .deployed:
            return "Production Status"
        case .failed:
            return "Setup Failed"
        }
    }

    private var githubIntegration: Integration? {
        allIntegrations.first { $0.type == .github }
    }

    private var isGitHubRepo: Bool {
        // Check project first, then fall back to deployedProject
        if let project {
            return project.githubOwner != nil && project.githubRepo != nil
        }
        return deployedProject?.githubOwner != nil && deployedProject?.githubRepo != nil
    }

    // MARK: - Orphan Cleanup

    /// Automatically cleanup orphaned deployment state when server is deleted
    private func cleanupOrphanedState(deployedProject: DeployedProject) async {
        // Delete DNS records created by Fadogen
        if !deployedProject.createdDNSRecordIDs.isEmpty,
           let zoneID = deployedProject.dnsZoneID,
           let zoneName = deployedProject.dnsZoneName,
           let integration = deployedProject.dnsIntegration {

            let zone = DNSZone(name: zoneName, id: zoneID, integration: integration)

            // List all records in the zone
            if let allRecords = try? await dnsManager.listRecords(in: zone, type: nil, name: nil) {
                // Protected record types that should NEVER be deleted
                let protectedTypes = ["NS", "SOA"]

                // Delete only records created by Fadogen (tracked IDs)
                for record in allRecords where deployedProject.createdDNSRecordIDs.contains(record.id) {
                    // Additional safety check: never delete NS/SOA records
                    guard !protectedTypes.contains(record.type) else { continue }

                    try? await dnsManager.deleteRecord(record, in: zone)
                }
            }
        }

        // Delete GitHub Actions secrets if configured
        if let owner = deployedProject.githubOwner, let repo = deployedProject.githubRepo {
            let gitHubDescriptor = FetchDescriptor<Integration>(
                predicate: #Predicate { integration in
                    integration.typeRawValue == "github"
                }
            )

            if let githubIntegrations = try? modelContext.fetch(gitHubDescriptor),
               let githubIntegration = githubIntegrations.first {
                let githubSecretsService = GitHubSecretsService()
                try? await githubSecretsService.deleteDeploymentSecrets(
                    owner: owner,
                    repo: repo,
                    integration: githubIntegration
                )
            }
        }

        // Reset deployed project production configuration
        await MainActor.run {
            deployedProject.clearProductionConfiguration()
            try? modelContext.save()
        }
    }
}
