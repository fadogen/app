import SwiftUI
import SwiftData

/// Result of the project generation process
enum GenerationResult {
    case success(LocalProject)
    case failure(Error)
    case cancelled
}

/// View displayed during project generation, blocking user interaction
struct NewProjectProgressView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Binding var isPresented: Bool

    let config: ProjectConfiguration
    let versionCheckResult: VersionCheckResult
    let onResult: (GenerationResult) -> Void

    @State private var generationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 24) {
            Text("Creating Project")
                .font(.title2)
                .fontWeight(.semibold)

            Text(services.projectGenerator.currentStep)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            ProgressView(value: services.projectGenerator.progress)
                .progressViewStyle(.linear)
                .frame(width: 300)

            Button("Cancel") {
                cancelGeneration()
            }
            .buttonStyle(.bordered)
        }
        .padding(40)
        .frame(width: 400, height: 200)
        .task {
            await startGeneration()
        }
        .onDisappear {
            // Ensure task is cancelled if view disappears unexpectedly
            generationTask?.cancel()
        }
    }

    // MARK: - Private

    private func startGeneration() async {
        generationTask = Task {
            do {
                let projectURL = try await services.projectGenerator.generate(
                    config: config,
                    versionCheckResult: versionCheckResult
                )

                // Wait for DirectoryWatcher to detect and create the LocalProject
                if let project = await waitForProjectDetection(projectURL: projectURL) {
                    onResult(.success(project))
                } else {
                    // Project not found after waiting - shouldn't happen normally
                    onResult(.failure(ProjectGeneratorError.siteNotDetected))
                }
            } catch is CancellationError {
                onResult(.cancelled)
            } catch ProjectGeneratorError.cancelled {
                onResult(.cancelled)
            } catch {
                onResult(.failure(error))
            }

            isPresented = false
        }
    }

    private func cancelGeneration() {
        generationTask?.cancel()
        services.projectGenerator.cancel()
    }

    /// Waits for the DirectoryWatcherService to detect the new project and create a LocalProject
    /// - Parameter projectURL: The URL of the created project
    /// - Returns: The detected LocalProject, or nil if not found within timeout
    private func waitForProjectDetection(projectURL: URL) async -> LocalProject? {
        let maxAttempts = 30 // 3 seconds max (30 * 100ms)

        for _ in 0..<maxAttempts {
            // Check if project exists with this path
            let pathToCheck = projectURL.path
            let descriptor = FetchDescriptor<LocalProject>(
                predicate: #Predicate { $0.path == pathToCheck }
            )

            if let project = try? modelContext.fetch(descriptor).first {
                return project
            }

            // Wait 100ms before next check
            try? await Task.sleep(for: .milliseconds(100))

            // Check for cancellation
            if Task.isCancelled { return nil }
        }

        return nil
    }
}
