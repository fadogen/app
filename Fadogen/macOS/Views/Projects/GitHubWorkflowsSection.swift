import SwiftUI

struct GitHubWorkflowsSection: View {
    let deployedProject: DeployedProject
    let githubIntegration: Integration

    @State private var workflows: [GitHubWorkflow] = []
    @State private var recentRuns: [GitHubWorkflowRun] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selectedWorkflow: GitHubWorkflow?
    @State private var isTriggering = false
    @State private var triggerSuccess = false
    @State private var pollingTask: Task<Void, Never>?

    private let githubService = GitHubService()

    private var owner: String? { deployedProject.githubOwner }
    private var repo: String? { deployedProject.githubRepo }
    private var token: String? { githubIntegration.credentials.token }

    /// Check if any run is currently in progress (needs faster polling)
    private var hasInProgressRun: Bool {
        recentRuns.contains { run in
            ["queued", "waiting", "pending", "in_progress"].contains(run.status)
        }
    }

    var body: some View {
        Section("GitHub Workflows") {
            if isLoading && workflows.isEmpty && recentRuns.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Loading workflows...")
                    Spacer()
                }
                .padding(.vertical, 12)
            } else if let error = error {
                VStack(spacing: 8) {
                    Label("Failed to load workflows", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await loadData() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                workflowContent
            }
        }
        .task {
            await loadData()
            scheduleNextPoll()
        }
        .onDisappear {
            pollingTask?.cancel()
        }
    }

    // MARK: - Polling

    /// Schedule next poll with adaptive interval (5s if in-progress, 30s otherwise)
    private func scheduleNextPoll() {
        pollingTask?.cancel()
        pollingTask = Task {
            try? await Task.sleep(for: .seconds(hasInProgressRun ? 5 : 30))
            guard !Task.isCancelled else { return }
            await loadData()
            scheduleNextPoll()
        }
    }

    @ViewBuilder
    private var workflowContent: some View {
        if !workflows.isEmpty {
            HStack {
                Picker("Workflow", selection: $selectedWorkflow) {
                    ForEach(workflows) { workflow in
                        Text(workflow.name).tag(Optional(workflow))
                    }
                }
                .labelsHidden()

                Button {
                    triggerSelectedWorkflow()
                } label: {
                    if isTriggering {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Run", systemImage: triggerSuccess ? "checkmark" : "play.fill")
                    }
                }
                .disabled(selectedWorkflow == nil || isTriggering)
                .buttonStyle(.borderedProminent)
                .symbolEffect(.bounce, value: triggerSuccess)
            }
            .padding(.vertical, 4)
        } else {
            Text("No workflows found")
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        }

        ForEach(recentRuns.prefix(10)) { run in
            WorkflowRunRow(run: run)
        }
    }

    // MARK: - Actions

    private func loadData() async {
        guard let owner = owner, let repo = repo, let token = token else {
            error = "GitHub configuration incomplete"
            isLoading = false
            return
        }

        do {
            async let workflowsTask = githubService.listWorkflows(owner: owner, repo: repo, token: token)
            async let runsTask = githubService.listWorkflowRuns(owner: owner, repo: repo, perPage: 10, token: token)

            let (fetchedWorkflows, fetchedRuns) = try await (workflowsTask, runsTask)

            await MainActor.run {
                workflows = fetchedWorkflows

                // Keep temp runs (negative IDs) only if < 60s old AND no real run with same SHA exists
                let now = Date()
                let keptTempRuns = recentRuns.filter { tempRun in
                    guard tempRun.id < 0 else { return false }
                    guard now.timeIntervalSince(tempRun.createdAt) < 60 else { return false }
                    guard let tempSha = tempRun.headSha else { return false }

                    let hasMatchingRun = fetchedRuns.contains {
                        $0.workflowId == tempRun.workflowId && $0.headSha == tempSha
                    }
                    return !hasMatchingRun
                }

                recentRuns = keptTempRuns + fetchedRuns

                if selectedWorkflow == nil, let first = fetchedWorkflows.first {
                    selectedWorkflow = first
                }

                error = nil
                isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func triggerSelectedWorkflow() {
        guard let workflow = selectedWorkflow,
              let owner = owner,
              let repo = repo,
              let token = token else { return }

        isTriggering = true
        triggerSuccess = false

        Task {
            defer { Task { @MainActor in isTriggering = false } }

            do {
                let ref = deployedProject.gitBranch ?? "main"
                let workflowFile = URL(fileURLWithPath: workflow.path).lastPathComponent

                // Get commit SHA BEFORE triggering - this will be used to identify our run
                let commitSHA = try await githubService.getCommitSHA(
                    owner: owner,
                    repo: repo,
                    ref: ref,
                    token: token
                )

                try await githubService.triggerWorkflowDispatch(
                    owner: owner,
                    repo: repo,
                    workflow: workflowFile,
                    ref: ref,
                    token: token
                )

                // Add temporary run with the commit SHA for reliable matching
                await MainActor.run {
                    recentRuns.insert(GitHubWorkflowRun(
                        id: -Int.random(in: 1...999999),
                        name: workflow.name,
                        displayTitle: workflow.name,
                        workflowId: workflow.id,
                        headSha: commitSHA,
                        status: "queued",
                        conclusion: nil,
                        createdAt: Date(),
                        htmlUrl: "https://github.com/\(owner)/\(repo)/actions"
                    ), at: 0)
                    triggerSuccess = true
                    scheduleNextPoll()
                }

                // Brief delay then refresh to catch real run from GitHub
                try? await Task.sleep(for: .seconds(3))
                await loadData()

                try? await Task.sleep(for: .seconds(1))
                await MainActor.run { triggerSuccess = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}

// MARK: - Workflow Run Row

private struct WorkflowRunRow: View {
    let run: GitHubWorkflowRun

    private var isTemporaryRun: Bool { run.id < 0 }

    var body: some View {
        if let url = URL(string: run.htmlUrl) {
            Link(destination: url) {
                HStack(spacing: 12) {
                    statusIndicator

                    Text(run.title)
                        .font(.subheadline)
                        .lineLimit(1)

                    Spacer()

                    if !isTemporaryRun {
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isTemporaryRun)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch (run.status, run.conclusion) {
        case ("completed", "success"):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case ("completed", "failure"):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case ("completed", "cancelled"):
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.secondary)
        case ("completed", _):
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.secondary)
        case ("queued", _), ("waiting", _), ("pending", _), ("in_progress", _):
            ProgressView()
                .controlSize(.small)
        default:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}
