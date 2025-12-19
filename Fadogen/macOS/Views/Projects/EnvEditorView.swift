import SwiftUI
import SwiftData

/// Dedicated view for editing production environment variables (.env.production)
/// Syncs changes to: SwiftData, local file (if path exists), and GitHub Secrets (if deployed)
struct EnvEditorView: View {
    @Bindable var deployedProject: DeployedProject
    let project: LocalProject?  // Optional: local project for file access
    let githubIntegration: Integration?  // Passed from parent to avoid @Query (causes infinite loops)

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var content: String = ""
    @State private var originalContent: String = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showingSaveError = false

    private var hasChanges: Bool {
        content != originalContent
    }

    private var canSyncToGitHub: Bool {
        deployedProject.deploymentStatus == .deployed &&
        deployedProject.githubOwner != nil &&
        deployedProject.githubRepo != nil &&
        githubIntegration != nil &&
        deployedProject.server != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Info banner when GitHub sync is unavailable
            if !canSyncToGitHub && deployedProject.deploymentStatus == .deployed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Changes will be saved locally only. GitHub sync unavailable.")
                        .font(.callout)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1))
            }

            // Monospace TextEditor for .env content
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
        }
        .navigationTitle("Production Environment")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isSaving)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(!hasChanges || isSaving)
            }
        }
        .overlay {
            if isSaving {
                ProgressView("Saving...")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .task {
            loadContent()
        }
        .alert("Save Failed", isPresented: $showingSaveError) {
            Button("OK") {
                saveError = nil
            }
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }

    // MARK: - Load Content

    private func loadContent() {
        // Priority: local file > SwiftData backup
        if let path = project?.path {
            let envURL = URL(fileURLWithPath: path)
                .appendingPathComponent(".env.production")
            if let localContent = try? String(contentsOf: envURL, encoding: .utf8) {
                content = localContent
                originalContent = localContent
                return
            }
        }

        // Fallback to saved content in DeployedProject
        if let saved = deployedProject.envProductionContent {
            content = saved
            originalContent = saved
        }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        do {
            // 1. Save to SwiftData (DeployedProject backup)
            deployedProject.envProductionContent = content

            // 2. Save to local file if project path exists
            if let path = project?.path {
                let envURL = URL(fileURLWithPath: path)
                    .appendingPathComponent(".env.production")
                try content.write(to: envURL, atomically: true, encoding: .utf8)
            }

            // 3. Sync to GitHub if possible
            if canSyncToGitHub,
               let integration = githubIntegration {
                try await GitHubSecretsService().updateEnvSecret(
                    deployedProject: deployedProject,
                    integration: integration,
                    envContent: content
                )
            }

            try modelContext.save()
            originalContent = content
            dismiss()

        } catch {
            saveError = error.localizedDescription
            showingSaveError = true
        }
    }
}
