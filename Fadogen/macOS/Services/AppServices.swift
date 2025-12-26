import Foundation
import os
import SwiftData

private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "app-services")

@Observable
final class AppServices {
    let caddy = CaddyService()
    let caddyConfig: CaddyConfigService
    let caddyCertificate = CaddyCertificateService()
    let php: PHPManager
    let phpFPM: PHPFPMService
    let phpExtensionWatcher: PHPExtensionWatcher
    let composer: ComposerManager
    let node: NodeManager
    let bun: BunManager
    let services: ServicesManager
    let serviceProcesses: ServiceProcessManager
    let reverb: ReverbManager
    let reverbProcess: ReverbProcessManager
    let typesense: TypesenseManager
    let typesenseProcess: TypesenseProcessManager
    let garage: GarageManager
    let garageProcess: GarageProcessManager
    let garageInitializer: GarageInitializer
    let mailpit: MailpitService
    let cloudflaredTunnel: CloudflaredTunnelService
    let quickTunnel: QuickTunnelService
    let directoryWatcher: DirectoryWatcherService
    let processCleanup: ProcessCleanupService
    let projectGenerator = ProjectGeneratorService()
    let ideService = IDEService()
    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.processCleanup = ProcessCleanupService(modelContext: modelContext)
        self.phpFPM = PHPFPMService(modelContext: modelContext)
        self.phpExtensionWatcher = PHPExtensionWatcher(modelContext: modelContext)
        self.caddyConfig = CaddyConfigService(modelContext: modelContext, caddy: caddy)
        self.php = PHPManager(modelContext: modelContext, phpFPM: phpFPM, caddyConfig: caddyConfig)
        self.composer = ComposerManager(modelContext: modelContext)
        self.node = NodeManager(modelContext: modelContext)
        self.bun = BunManager(modelContext: modelContext)
        self.serviceProcesses = ServiceProcessManager(modelContext: modelContext)
        self.services = ServicesManager(modelContext: modelContext, serviceProcesses: serviceProcesses)
        self.reverbProcess = ReverbProcessManager(modelContext: modelContext)
        self.reverb = ReverbManager(modelContext: modelContext, reverbProcess: reverbProcess, caddyConfig: caddyConfig)
        self.typesenseProcess = TypesenseProcessManager(modelContext: modelContext)
        self.typesense = TypesenseManager(modelContext: modelContext, typesenseProcess: typesenseProcess, caddyConfig: caddyConfig)
        self.garageProcess = GarageProcessManager(modelContext: modelContext)
        self.garageInitializer = GarageInitializer(modelContext: modelContext)
        self.garage = GarageManager(modelContext: modelContext, garageProcess: garageProcess, garageInitializer: garageInitializer, caddyConfig: caddyConfig)
        self.mailpit = MailpitService(modelContext: modelContext)
        self.cloudflaredTunnel = CloudflaredTunnelService(modelContext: modelContext, caddyConfig: caddyConfig)
        self.quickTunnel = QuickTunnelService(modelContext: modelContext)
        self.directoryWatcher = DirectoryWatcherService(modelContext: modelContext, caddyConfig: caddyConfig)

        // Inject dependencies into project generator for prerequisite management
        projectGenerator.phpManager = php
        projectGenerator.servicesManager = services
        projectGenerator.serviceProcesses = serviceProcesses
        projectGenerator.reverbManager = reverb
        projectGenerator.reverbProcess = reverbProcess
        projectGenerator.typesenseManager = typesense
        projectGenerator.typesenseProcess = typesenseProcess
        projectGenerator.garageManager = garage
        projectGenerator.garageProcess = garageProcess
        projectGenerator.bunManager = bun
        projectGenerator.nodeManager = node
        projectGenerator.modelContext = modelContext
    }

    func initialize() async {
        // Phase 0: Cleanup orphaned processes from previous crashes
        processCleanup.cleanupOrphanedProcesses()

        await initializeManagers()
        await startWebServerAndDatabases()
        await startPHPRuntime()
        await startApplications()
    }

    // MARK: - Phase 1: Initialize managers

    private func initializeManagers() async {
        // Generate main Caddyfile skeleton
        do {
            try caddyConfig.generateMainCaddyfile()
        } catch {
            logger.error("Failed to generate main Caddyfile: \(error.localizedDescription)")
        }

        // Initialize managers with dependencies respected
        // PHP must complete first (Composer depends on PHP binary)
        async let servicesInit: Void = services.initialize()    // Load service metadata (independent)
        async let reverbInit: Void = reverb.initialize()        // Load Reverb config (independent)
        async let typesenseInit: Void = typesense.initialize()  // Load Typesense config (independent)
        async let garageInit: Void = garage.initialize()        // Load Garage config (independent)
        async let watcherInit: Void = directoryWatcher.reconcile(syncCaddy: false)  // Scan sites (independent)

        // PHP initialization (creates bin/ directory and installs PHP)
        await php.initialize()

        // Composer depends on PHP symlink, must be sequential
        await composer.initialize()

        // Node.js initialization (independent of PHP)
        async let nodeInit: Void = node.initialize()

        // Bun initialization (independent)
        async let bunInit: Void = bun.initialize()

        // Setup Fadogen shell integration (must be AFTER php.initialize() creates bin/)
        // This replaces PVM and NVM setup, now unified in fadogen.sh
        do {
            try FadogenShellService.setup()
        } catch {
            logger.warning("Failed to setup Fadogen shell integration: \(error.localizedDescription)")
        }

        // Wait for other independent initializations
        await servicesInit
        await reverbInit
        await typesenseInit
        await garageInit
        await watcherInit
        await nodeInit
        await bunInit

        // Cleanup orphaned tunnel routes (projects deleted while app was closed)
        await cloudflaredTunnel.cleanupOrphanedRoutes()

        // Configure service dependencies
        caddy.phpFPM = phpFPM
        caddy.reverbProcess = reverbProcess
        caddy.processCleanup = processCleanup
        caddy.certificateService = caddyCertificate
        phpFPM.processCleanup = processCleanup
        phpExtensionWatcher.setPHPFPM(phpFPM)
        serviceProcesses.processCleanup = processCleanup
        reverbProcess.processCleanup = processCleanup
        typesenseProcess.processCleanup = processCleanup
        garageProcess.processCleanup = processCleanup
        garageProcess.garageInitializer = garageInitializer
        mailpit.processCleanup = processCleanup
        mailpit.caddyConfig = caddyConfig
        cloudflaredTunnel.processCleanup = processCleanup
        cloudflaredTunnel.quickTunnelService = quickTunnel
        quickTunnel.processCleanup = processCleanup
        quickTunnel.caddyConfig = caddyConfig
        caddyConfig.quickTunnelService = quickTunnel
        directoryWatcher.setTunnelService(cloudflaredTunnel)
    }

    // MARK: - Phase 2: Start web server + databases

    private func startWebServerAndDatabases() async {
        async let caddyTask: Void = startCaddyAndWaitForCA()
        async let databasesTask: Void = serviceProcesses.startAutoStartServices()

        await caddyTask
        await databasesTask
    }

    private func startCaddyAndWaitForCA() async {
        // Generate project Caddyfiles (needs PHP version info from Phase 1)
        caddyConfig.reconcile()

        // Start Caddy without restarting dependencies (they haven't started yet)
        // Services will start after Caddy with correct certificates already installed
        do {
            try await caddy.start(restartDependencies: false)
        } catch {
            logger.warning("Failed to start Caddy: \(error)")
        }
    }

    // MARK: - Phase 3: Start PHP runtime

    private func startPHPRuntime() async {
        // Add Caddy CA to PHP's trusted certificates
        do {
            if try PHPConfigService.ensureCaddyCACert() {
                logger.info("Caddy CA added to cacert.pem")
            }
        } catch {
            logger.warning("Failed to add Caddy CA to cacert.pem: \(error)")
        }

        // Start PHP-FPM with correct cacert.pem (includes Caddy CA)
        await phpFPM.startAll()

        // Start watching extension directories for auto-restart
        phpExtensionWatcher.startWatching()
    }

    // MARK: - Phase 4: Start applications

    private func startApplications() async {
        // Start Reverb if autoStart enabled
        await reverbProcess.startAutoStartService()

        // Start Typesense if autoStart enabled
        await typesenseProcess.startAutoStartService()

        // Start Garage if autoStart enabled
        await garageProcess.startAutoStartService()

        // Start Mailpit if autoStart enabled
        await mailpit.startAutoStartService()

        // Start Cloudflared tunnel if active routes exist
        await startCloudflaredIfConfigured()
    }

    private func startCloudflaredIfConfigured() async {
        // Find Cloudflare integration
        let descriptor = FetchDescriptor<Integration>(
            predicate: #Predicate { $0.typeRawValue == "cloudflare" }
        )

        let integration = try? modelContext.fetch(descriptor).first

        // Start tunnel if any active routes exist
        await cloudflaredTunnel.startIfRoutesExist(integration: integration)
    }

    func shutdown() async {
        await caddy.stop()

        // Stop all running database/cache services
        await serviceProcesses.stopAll()

        // Stop Reverb if running
        await reverbProcess.stop()

        // Stop Typesense if running
        await typesenseProcess.stop()

        // Stop Garage if running
        await garageProcess.stop()

        // Stop Mailpit if running
        await mailpit.stop()

        // Stop Cloudflared if running
        await cloudflaredTunnel.stop()

        // Stop all quick tunnels
        await quickTunnel.stopAll()

        // Stop all PHP-FPM processes
        await phpFPM.stopAll()

        // Stop extension watching
        phpExtensionWatcher.shutdown()

        // Stop directory monitoring
        directoryWatcher.shutdown()
    }
}
