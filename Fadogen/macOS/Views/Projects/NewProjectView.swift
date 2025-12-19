import SwiftUI
import SwiftData

/// Form view for creating a new Laravel project
struct NewProjectView: View {
    @Binding var navigationPath: NavigationPath

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services
    @Query private var watchedDirectories: [WatchedDirectory]

    /// Available PHP versions from metadata (excluding EOL versions)
    private var availablePHPVersions: [String] {
        services.php.availableVersions
            .filter { !$0.value.isEol }
            .keys
            .sorted(by: >)  // Newest first
    }

    /// Characters allowed in project names (RFC 1123 hostname compatible)
    private static let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")

    // MARK: - Form State

    @State private var config = ProjectConfiguration()
    @State private var selectedDirectory: WatchedDirectory?
    @State private var isGenerating = false
    @State private var showingError = false
    @State private var errorMessage = ""

    // Version check state
    @State private var showVersionCheck = false
    @State private var versionCheckResult = VersionCheckResult()

    // MARK: - Project Name Binding

    /// Custom binding that filters project name input in real-time
    private var projectNameBinding: Binding<String> {
        Binding(
            get: { config.projectName },
            set: { newValue in
                config.projectName = Self.sanitizeProjectNameInput(newValue)
            }
        )
    }

    /// Sanitizes project name input to only allow valid hostname characters
    ///
    /// Rules:
    /// - Only a-z, 0-9, and hyphen allowed
    /// - Spaces and underscores converted to hyphens (user-friendly)
    /// - Consecutive hyphens collapsed to single hyphen
    /// - Leading hyphens removed (trailing allowed while typing)
    private static func sanitizeProjectNameInput(_ input: String) -> String {
        // 1. Convert to lowercase
        var result = input.lowercased()

        // 2. Replace spaces and underscores with hyphens (user-friendly)
        result = result.replacingOccurrences(of: " ", with: "-")
        result = result.replacingOccurrences(of: "_", with: "-")

        // 3. Keep only allowed characters: a-z, 0-9, -
        result = String(result.unicodeScalars.filter { allowedCharacters.contains($0) })

        // 4. Collapse consecutive hyphens
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }

        // 5. Remove leading hyphens (but allow trailing while typing)
        while result.hasPrefix("-") {
            result.removeFirst()
        }

        return result
    }

    // MARK: - Body

    var body: some View {
        Form {
            generalSection
            frameworkOptionsSection
        }
        .onChange(of: selectedDirectory) { _, newValue in
            config.installDirectory = newValue?.url
        }
        .onChange(of: config.queueService) { _, newValue in
            // Auto-select Valkey when queue is enabled
            if newValue != .none && config.queueBackend == nil {
                config.queueBackend = .valkey
            } else if newValue == .none {
                config.queueBackend = nil
            }
        }
        .task {
            // Refresh PHP metadata if not loaded
            if services.php.availableVersions.isEmpty {
                await services.php.refresh()
            }
            // Validate default PHP version selection
            if !availablePHPVersions.contains(config.phpVersion),
               let first = availablePHPVersions.first {
                config.phpVersion = first
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Project")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    startGeneration()
                }
                .disabled(!isValid)
            }
        }
        .sheet(isPresented: $showVersionCheck) {
            VersionCheckView(
                isPresented: $showVersionCheck,
                versionCheckResult: $versionCheckResult,
                onContinue: proceedWithGeneration
            )
        }
        .sheet(isPresented: $isGenerating) {
            NewProjectProgressView(
                isPresented: $isGenerating,
                config: config,
                versionCheckResult: versionCheckResult,
                onResult: handleGenerationResult
            )
            .interactiveDismissDisabled(true)
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") {
                // Stay on form after error
            }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - General Section

    @ViewBuilder
    private var generalSection: some View {
        Section("General") {
            // Framework
            Picker("Framework", selection: $config.framework) {
                ForEach(Framework.allCases.filter(\.isAvailable), id: \.self) { framework in
                    Text(framework.displayName)
                        .tag(framework)
                }
            }

            // Directory
            Picker("Directory", selection: $selectedDirectory) {
                Text("Select a directory").tag(nil as WatchedDirectory?)
                ForEach(watchedDirectories) { directory in
                    Text(directory.name).tag(directory as WatchedDirectory?)
                }
            }

            // Project Name
            TextField("Project Name", text: projectNameBinding)

            // PHP Version (auto-installed if not present)
            Picker("PHP Version", selection: $config.phpVersion) {
                ForEach(availablePHPVersions, id: \.self) { version in
                    Text("PHP \(version)").tag(version)
                }
            }

            // Database
            Picker("Database", selection: $config.databaseType) {
                ForEach(DatabaseType.allCases, id: \.self) { database in
                    Text(database.displayName).tag(database)
                }
            }
        }
    }

    // MARK: - Framework Options Section

    @ViewBuilder
    private var frameworkOptionsSection: some View {
        if config.showsLaravelOptions {
            laravelStarterKitSection
            laravelOptionalFeaturesSection
        } else if config.showsSymfonyOptions {
            symfonyProjectTypeSection
        }
    }

    // MARK: - Laravel Starter Kit Section

    @ViewBuilder
    private var laravelStarterKitSection: some View {
        Section("Starter Kit") {
            // Starter Kit
            Picker("Kit", selection: $config.starterKit) {
                ForEach(LaravelStarterKit.allCases, id: \.self) { kit in
                    Text(kit.displayName).tag(kit)
                }
            }

            // Custom Repo (visible if .custom)
            if config.showsCustomRepo {
                TextField("Repository", text: $config.customStarterKitRepo)
                    .textFieldStyle(.roundedBorder)
            }

            // Authentication (visible if starter kit has auth)
            if config.showsAuthentication {
                Picker("Authentication", selection: $config.authentication) {
                    ForEach(StarterKitAuthentication.allCases, id: \.self) { auth in
                        Text(auth.displayName).tag(auth)
                    }
                }
            }

            // Volt (visible if .livewire AND NOT .workos)
            if config.showsVolt {
                Toggle("Volt", isOn: $config.volt)
            }

            // Testing Framework
            Picker("Testing", selection: $config.testingFramework) {
                ForEach(TestingFramework.allCases, id: \.self) { framework in
                    Text(framework.displayName).tag(framework)
                }
            }

            // Package Manager (exclude .none - internal use only)
            Picker("Package Manager", selection: $config.jsPackageManager) {
                ForEach(JSPackageManager.allCases.filter { $0 != .none }, id: \.self) { manager in
                    Text(manager.displayName).tag(manager)
                }
            }
        }
    }

    // MARK: - Laravel Optional Features Section

    @ViewBuilder
    private var laravelOptionalFeaturesSection: some View {
        Section("Optional Features") {
            // Queue Service
            Picker("Queue", selection: $config.queueService) {
                ForEach(QueueService.allCases, id: \.self) { service in
                    Text(service.displayName).tag(service)
                }
            }

            // Queue Backend (visible if queue enabled)
            if config.showsQueueBackend {
                Picker("Queue Backend", selection: $config.queueBackend) {
                    Text("Select...").tag(nil as QueueBackend?)
                    ForEach(config.availableQueueBackends, id: \.self) { backend in
                        Text(backend.displayName).tag(backend as QueueBackend?)
                    }
                }
            }

            // Task Scheduler
            Toggle("Task Scheduler", isOn: $config.taskScheduler)

            // Reverb
            Toggle("Reverb", isOn: $config.reverb)

            // Octane
            Toggle("Octane", isOn: $config.octane)
        }
    }

    // MARK: - Symfony Project Type Section

    @ViewBuilder
    private var symfonyProjectTypeSection: some View {
        Section("Project Type") {
            Picker("Type", selection: $config.symfonyProjectType) {
                ForEach(SymfonyProjectType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        guard !config.projectName.isEmpty else { return false }
        guard config.projectName.sanitizedHostname() != nil else { return false }
        guard config.installDirectory != nil else { return false }
        // Laravel: custom starter kit requires repo URL
        if config.framework == .laravel && config.starterKit == .custom {
            guard !config.customStarterKitRepo.isEmpty else { return false }
        }
        return true
    }

    // MARK: - Generation

    private func startGeneration() {
        // Check versions before starting
        do {
            versionCheckResult = try services.projectGenerator.checkVersions(config: config)

            if versionCheckResult.hasUpgradesNeeded {
                // Show version check dialog
                showVersionCheck = true
            } else {
                // No upgrades needed, proceed directly
                isGenerating = true
            }
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func proceedWithGeneration() {
        showVersionCheck = false
        isGenerating = true
    }

    private func handleGenerationResult(_ result: GenerationResult) {
        switch result {
        case .success(let project):
            // Navigate directly to the new project's detail view
            // Replace NewProjectView with ProjectDetailView in the navigation stack
            navigationPath.removeLast()
            navigationPath.append(ProjectDestination.local(project))

        case .failure(let error):
            errorMessage = error.localizedDescription
            showingError = true
            // Stay on form after failure

        case .cancelled:
            // Stay on form after cancellation
            break
        }
    }
}
