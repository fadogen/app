import SwiftUI
import SwiftData
import Subprocess
import System

/// Repository name availability status
enum RepoAvailabilityStatus: Equatable {
    case unchecked
    case checking
    case available
    case taken
    case error(String)
}

/// Sheet for creating a new GitHub repository with live validation
struct GitHubRepoCreationSheet: View {
    @Bindable var project: LocalProject
    let integration: Integration

    @SwiftUI.Environment(\.modelContext) private var modelContext
    @SwiftUI.Environment(\.dismiss) private var dismiss

    // Form state
    @State private var repoName = ""
    @State private var isPrivate = true

    // Validation state
    @State private var availability: RepoAvailabilityStatus = .unchecked
    @State private var checkTask: Task<Void, Never>?

    // Creation state
    @State private var isCreating = false
    @State private var error: String?

    // GitHub user info (cached)
    @State private var username: String?
    @State private var isLoadingUser = false

    private let githubService = GitHubService()

    private var isGitAvailable: Bool {
        FileManager.default.fileExists(atPath: "/usr/bin/git")
    }

    private var canCreate: Bool {
        !repoName.isEmpty &&
        availability == .available &&
        !isCreating &&
        username != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                // Repository name section
                Section {
                    HStack {
                        TextField("repository-name", text: $repoName)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: repoName) { _, _ in
                                debouncedCheckAvailability()
                            }

                        availabilityIndicator
                    }

                    // URL preview
                    if let username = username {
                        Text("github.com/\(username)/\(repoName.isEmpty ? "..." : repoName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Repository Name")
                }

                // Visibility section
                Section {
                    Toggle("Private repository", isOn: $isPrivate)
                } header: {
                    Text("Visibility")
                } footer: {
                    Text(isPrivate ? "Only you can see this repository." : "Anyone on the internet can see this repository.")
                }

                // Git warning (if not available)
                if !isGitAvailable {
                    Section {
                        gitNotAvailableWarning
                    }
                }

                // Error section
                if let error = error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Create GitHub Repository")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        checkTask?.cancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        createRepository()
                    } label: {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(!canCreate || !isGitAvailable)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            loadGitHubUsername()
            // Default repo name from project name
            if repoName.isEmpty {
                repoName = project.sanitizedName
            }
        }
        .onDisappear {
            checkTask?.cancel()
        }
    }

    // MARK: - Availability Indicator

    @ViewBuilder
    private var availabilityIndicator: some View {
        switch availability {
        case .unchecked:
            EmptyView()
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .taken:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Already exists")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        case .error(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Git Warning

    private var gitNotAvailableWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Git not found")
                    .fontWeight(.medium)
                Text("Run 'xcode-select --install' in Terminal to install Xcode Command Line Tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - GitHub Username Loading

    private func loadGitHubUsername() {
        guard username == nil,
              let token = integration.credentials.token else { return }

        isLoadingUser = true

        Task {
            do {
                let user = try await githubService.validateToken(token: token)
                username = user.login
                isLoadingUser = false
                // Trigger initial check after username loads
                debouncedCheckAvailability()
            } catch {
                self.error = "Failed to load GitHub user: \(error.localizedDescription)"
                isLoadingUser = false
            }
        }
    }

    // MARK: - Availability Check (Debounced)

    private func debouncedCheckAvailability() {
        checkTask?.cancel()
        availability = .unchecked

        guard !repoName.isEmpty,
              let token = integration.credentials.token,
              let owner = username else { return }

        // Validate repo name format (GitHub rules)
        let validNamePattern = #"^[a-zA-Z0-9._-]+$"#
        guard repoName.range(of: validNamePattern, options: .regularExpression) != nil else {
            availability = .error("Invalid characters")
            return
        }

        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            await checkAvailability(owner: owner, token: token)
        }
    }

    private func checkAvailability(owner: String, token: String) async {
        availability = .checking

        do {
            let isAvailable = try await githubService.checkRepositoryAvailability(
                owner: owner,
                repoName: repoName,
                token: token
            )

            availability = isAvailable ? .available : .taken
        } catch {
            availability = .error("Check failed")
        }
    }

    // MARK: - Repository Creation

    private func createRepository() {
        guard let token = integration.credentials.token,
              let owner = username else { return }

        isCreating = true
        error = nil

        Task {
            do {
                // Create repository on GitHub
                let repo = try await githubService.createRepository(
                    name: repoName,
                    isPrivate: isPrivate,
                    token: token
                )

                // Build the SSH remote URL
                let remoteURL = "git@github.com:\(owner)/\(repo.name).git"

                // Initialize git if needed and set remote
                try await initializeGitIfNeeded(remoteURL: remoteURL)

                // Update project with new remote URL
                project.gitRemoteURL = remoteURL
                project.gitBranch = "main"
                try? modelContext.save()

                isCreating = false
                dismiss()

            } catch {
                self.error = "Failed to create repository: \(error.localizedDescription)"
                isCreating = false
            }
        }
    }

    private func initializeGitIfNeeded(remoteURL: String) async throws {
        let projectPath = project.path

        let gitBinary = FilePath("/usr/bin/git")
        let gitDir = URL(fileURLWithPath: projectPath).appendingPathComponent(".git")

        // Initialize git if not already initialized
        if !FileManager.default.fileExists(atPath: gitDir.path) {
            let initResult = try await Subprocess.run(
                .path(gitBinary),
                arguments: ["-C", projectPath, "init", "-b", "main"],
                output: .discarded,
                error: .bytes(limit: 4096)
            )

            guard initResult.terminationStatus.isSuccess else {
                let stderr = String(bytes: initResult.standardError, encoding: .utf8) ?? "unknown error"
                throw GitError.commandFailed(stderr)
            }
        } else {
            // Ensure branch is named "main" (handles older git with "master" default)
            _ = try? await Subprocess.run(
                .path(gitBinary),
                arguments: ["-C", projectPath, "branch", "-M", "main"],
                output: .discarded,
                error: .discarded
            )
        }

        // Try to add remote origin (works if no remote exists)
        let addRemoteResult = try await Subprocess.run(
            .path(gitBinary),
            arguments: ["-C", projectPath, "remote", "add", "origin", remoteURL],
            output: .discarded,
            error: .bytes(limit: 4096)
        )

        // If add failed (remote already exists), update it instead
        if !addRemoteResult.terminationStatus.isSuccess {
            let setUrlResult = try await Subprocess.run(
                .path(gitBinary),
                arguments: ["-C", projectPath, "remote", "set-url", "origin", remoteURL],
                output: .discarded,
                error: .bytes(limit: 4096)
            )

            guard setUrlResult.terminationStatus.isSuccess else {
                let stderr = String(bytes: setUrlResult.standardError, encoding: .utf8) ?? "unknown error"
                throw GitError.commandFailed(stderr)
            }
        }

        // Check if there are any commits
        let hasCommits = await checkHasCommits(gitBinary: gitBinary, projectPath: projectPath)

        // If no commits, create initial commit
        if !hasCommits {
            // Add all files
            let addResult = try await Subprocess.run(
                .path(gitBinary),
                arguments: ["-C", projectPath, "add", "."],
                output: .discarded,
                error: .bytes(limit: 4096)
            )

            guard addResult.terminationStatus.isSuccess else {
                let stderr = String(bytes: addResult.standardError, encoding: .utf8) ?? "unknown error"
                throw GitError.commandFailed(stderr)
            }

            // Create initial commit
            let commitResult = try await Subprocess.run(
                .path(gitBinary),
                arguments: ["-C", projectPath, "commit", "-m", "Initial commit"],
                output: .discarded,
                error: .bytes(limit: 4096)
            )

            guard commitResult.terminationStatus.isSuccess else {
                let stderr = String(bytes: commitResult.standardError, encoding: .utf8) ?? "unknown error"
                throw GitError.commandFailed(stderr)
            }
        }

        // Push to origin with upstream tracking
        let pushResult = try await Subprocess.run(
            .path(gitBinary),
            arguments: ["-C", projectPath, "push", "-u", "origin", "main"],
            output: .discarded,
            error: .bytes(limit: 4096)
        )

        guard pushResult.terminationStatus.isSuccess else {
            let stderr = String(bytes: pushResult.standardError, encoding: .utf8) ?? "unknown error"
            throw GitError.commandFailed(stderr)
        }
    }

    private func checkHasCommits(gitBinary: FilePath, projectPath: String) async -> Bool {
        do {
            let result = try await Subprocess.run(
                .path(gitBinary),
                arguments: ["-C", projectPath, "rev-parse", "HEAD"],
                output: .discarded,
                error: .discarded
            )
            return result.terminationStatus.isSuccess
        } catch {
            return false
        }
    }
}
