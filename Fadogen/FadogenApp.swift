import SwiftUI
import SwiftData
import CoreData
import Sparkle

@main
struct FadogenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let modelContainer: ModelContainer
    let services: AppServices
    let provisioningService: ProvisioningService
    let dnsManager: DNSManager
    let deploymentService: ProjectDeploymentService
    let projectLinkingService: ProjectLinkingService
    let integrationService: IntegrationService

    /// Sparkle updater controller for automatic updates
    private let updaterController: SPUStandardUpdaterController

    /// Sparkle updater delegate for beta channel support
    private let updaterDelegate = UpdaterDelegate()

    init() {
        // Initialize Sparkle updater first
        // startingUpdater: true = automatically checks for updates on launch
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )

        do {
            // Use centralized path configuration (handles Debug/Release separation)
            let baseURL = FadogenPaths.baseDirectory

            // Ensure base directory exists
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

            // MARK: - Local Store Configuration (not synced to CloudKit)
            // Contains machine-specific data: local projects, watched directories, installed versions

            let localSchema = Schema([
                LocalProject.self,
                WatchedDirectory.self,
                PHPVersion.self,
                NodeVersion.self,
                BunVersion.self,
                ComposerVersion.self,
                ServiceVersion.self,
                ReverbVersion.self,
                MailpitConfig.self,
                LocalTunnelConfig.self,
                LocalTunnelRoute.self
            ])

            let localConfig = ModelConfiguration(
                "local",
                schema: localSchema,
                url: baseURL.appending(path: "local.store"),
                cloudKitDatabase: .none
            )

            // MARK: - CloudKit Store Configuration (synced across devices)
            // Contains deployment data: deployed projects, servers, integrations, credentials

            let cloudSchema = Schema([
                DeployedProject.self,
                Server.self,
                Integration.self,
                CloudflareTunnel.self,
                UserPreferences.self
            ])

            let cloudConfig = ModelConfiguration(
                "cloud",
                schema: cloudSchema,
                url: baseURL.appending(path: "cloud.store"),
                cloudKitDatabase: .automatic
            )

            // MARK: - Combined ModelContainer

            let fullSchema = Schema([
                // Local models
                LocalProject.self,
                WatchedDirectory.self,
                PHPVersion.self,
                NodeVersion.self,
                BunVersion.self,
                ComposerVersion.self,
                ServiceVersion.self,
                ReverbVersion.self,
                MailpitConfig.self,
                LocalTunnelConfig.self,
                LocalTunnelRoute.self,
                // Cloud models
                DeployedProject.self,
                Server.self,
                Integration.self,
                CloudflareTunnel.self,
                UserPreferences.self
            ])

            modelContainer = try ModelContainer(
                for: fullSchema,
                configurations: [localConfig, cloudConfig]
            )

            // Create separate contexts for each store
            // Note: SwiftData automatically routes models to the correct store
            // based on ModelConfiguration schema

            services = AppServices(modelContext: modelContainer.mainContext)
            dnsManager = DNSManager(modelContext: modelContainer.mainContext)
            provisioningService = ProvisioningService(
                modelContext: modelContainer.mainContext,
                dnsManager: dnsManager
            )
            deploymentService = ProjectDeploymentService(
                modelContext: modelContainer.mainContext,
                provisioningService: provisioningService,
                dnsManager: dnsManager
            )
            projectLinkingService = ProjectLinkingService(modelContext: modelContainer.mainContext)
            integrationService = IntegrationService(modelContext: modelContainer.mainContext)

            // Wire up linking service for dynamic project auto-linking
            services.directoryWatcher.setLinkingService(projectLinkingService)

        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(services)
                .environment(provisioningService)
                .environment(dnsManager)
                .environment(deploymentService)
                .environment(projectLinkingService)
                .modelContainer(modelContainer)
                .task {
                    // Phase 0: Cleanup orphaned data (BEFORE any other initialization)
                    projectLinkingService.cleanupOrphanedProjects()

                    // Deduplicate Integrations (CloudKit merge conflicts)
                    integrationService.deduplicateIntegrations()

                    // Auto-start services (non-blocking)
                    await services.initialize()

                    // Auto-link local projects to deployed projects (silent)
                    projectLinkingService.autoLinkOrphanedProjects()

                    // Resume incomplete deployments (crash recovery)
                    await deploymentService.resumeIncompleteDeployments()
                }
                .onAppear {
                    // Inject services reference into AppDelegate
                    appDelegate.services = services
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}
