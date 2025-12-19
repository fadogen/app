import AppKit
import SwiftData
import SwiftUI

struct DeploymentLogsView: View {
    let project: LocalProject?
    @Bindable var deployedProject: DeployedProject
    let onRetry: () -> Void

    @Environment(ProjectDeploymentService.self) private var deploymentService
    @Environment(\.modelContext) private var modelContext

    @State private var copied = false
    @State private var isUpdatingGitConfig = false

    private var isDeploying: Bool {
        deployedProject.deploymentStatus == .deploying
    }

    private var isFailed: Bool {
        deployedProject.deploymentStatus == .failed
    }

    @ViewBuilder
    private var statusArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Server info section (only during deployment)
                if isDeploying {
                    serverInfoSection
                }

                if isDeploying {
                    deploymentSteps
                } else if isFailed {
                    Text(deployedProject.deploymentError ?? "Unknown error")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var serverInfoSection: some View {
        if let server = deployedProject.server, let host = server.host {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(host)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    Button {
                        copyToClipboard(host)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .symbolEffect(.bounce, value: copied)
                    .buttonStyle(.borderless)
                    .foregroundStyle(copied ? .green : .secondary)

                    Spacer()
                }

                Divider()
            }
        }
    }

    @ViewBuilder
    private var deploymentSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepRow(
                title: "Creating DNS record",
                status: stepStatus(for: .creatingDNSRecord)
            )

            // Only show Traefik SSL step if server does NOT use Cloudflare Tunnel
            if deployedProject.server?.cloudflareTunnel == nil {
                stepRow(
                    title: "Configuring Traefik SSL",
                    status: stepStatus(for: .configuringTraefik)
                )
            }

            if deployedProject.githubOwner != nil && deployedProject.githubRepo != nil {
                stepRow(
                    title: "Configuring GitHub Actions secrets",
                    status: stepStatus(for: .configuringGitHub)
                )
            }
        }
        .font(.system(.body, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepStatus(for step: ProductionConfigurationStep) -> StepStatus {
        let current = deploymentService.currentStep

        // If this is the current step, it's in progress
        if current == step {
            return .inProgress
        }

        // If current step is after this step, it's completed
        switch (step, current) {
        case (.creatingDNSRecord, .configuringTraefik),
             (.creatingDNSRecord, .configuringGitHub),
             (.creatingDNSRecord, .completed):
            return .completed

        case (.configuringTraefik, .configuringGitHub),
             (.configuringTraefik, .completed):
            return .completed

        case (.configuringGitHub, .completed):
            return .completed

        default:
            return .pending
        }
    }

    private func stepRow(title: String, status: StepStatus) -> some View {
        HStack(spacing: 8) {
            switch status {
            case .pending:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            case .inProgress:
                ProgressView()
                    .controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Text(title)
                .foregroundStyle(status == .pending ? .secondary : .primary)
        }
    }

    // MARK: - Private

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    var body: some View {
        @Bindable var deploymentServiceBindable = deploymentService

        statusArea
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .toolbar {
                if isFailed {
                    // Edit configuration button
                    ToolbarItem(placement: .automatic) {
                        Button {
                            onRetry()
                        } label: {
                            Label("Edit Configuration", systemImage: "pencil")
                        }
                        .help("Edit production configuration")
                    }

                    // Retry deployment button
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            retryDeployment()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Retry deployment from failed step")
                    }
                }
            }
            .sheet(item: $deploymentServiceBindable.pendingRepositoryRename) { resolution in
                RepositoryRenamedSheet(
                    resolution: resolution,
                    isUpdating: isUpdatingGitConfig,
                    // Only offer "Update Config" option if local project exists
                    onUpdateConfig: project != nil ? { handleRepositoryResolution(resolution: resolution, updateGitConfig: true) } : nil,
                    onSkip: { handleRepositoryResolution(resolution: resolution, updateGitConfig: false) }
                )
            }
    }

    // MARK: - Actions

    private func retryDeployment() {
        Task {
            await deploymentService.resumeDeployment(for: deployedProject)
        }
    }

    /// Handle repository rename resolution
    /// - Parameters:
    ///   - resolution: The repository resolution info
    ///   - updateGitConfig: If true, also update the local .git/config
    private func handleRepositoryResolution(resolution: RepositoryResolution, updateGitConfig: Bool) {
        guard let server = deployedProject.server else { return }

        if updateGitConfig {
            isUpdatingGitConfig = true
        }

        Task {
            do {
                try await deploymentService.continueDeploymentWithResolvedRepo(
                    project: project,
                    deployedProject: deployedProject,
                    server: server,
                    resolution: resolution,
                    updateGitConfig: updateGitConfig
                )
            } catch {
                deployedProject.deploymentStatus = .failed
                deployedProject.deploymentError = error.localizedDescription
                try? modelContext.save()
            }

            if updateGitConfig {
                isUpdatingGitConfig = false
            }
        }
    }
}

private enum StepStatus {
    case pending
    case inProgress
    case completed
}
