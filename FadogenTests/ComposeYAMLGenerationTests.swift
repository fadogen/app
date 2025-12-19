import Foundation
import Testing
@testable import Fadogen

/// Helper class to locate the test bundle
private final class ComposeTestBundleLocator {}

@MainActor
struct ComposeYAMLTemplateSelectionTests {
    private let testBundle = Bundle(for: ComposeTestBundleLocator.self)

    // MARK: - Helper

    private func makeBuilder(
        projectName: String = "myapp",
        starterKit: LaravelStarterKit = .none,
        jsPackageManager: JSPackageManager = .bun,
        databaseType: DatabaseType = .sqlite,
        queueService: QueueService = .none,
        queueBackend: QueueBackend? = nil,
        cacheService: CacheService? = nil,
        taskScheduler: Bool = false,
        reverb: Bool = false,
        octane: Bool = false
    ) -> ComposeYAMLBuilder {
        var config = ProjectConfiguration()
        config.projectName = projectName
        config.starterKit = starterKit
        config.jsPackageManager = jsPackageManager
        config.databaseType = databaseType
        config.queueService = queueService
        config.queueBackend = queueBackend
        config.cacheService = cacheService
        config.taskScheduler = taskScheduler
        config.reverb = reverb
        config.octane = octane
        return ComposeYAMLBuilder(config: config, bundle: testBundle)
    }

    private func templateNames(for builder: ComposeYAMLBuilder) -> [String] {
        builder.templateFiles().map { $0.lastPathComponent }
    }

    // MARK: - Base Templates Tests

    @Test func baseTemplatesAlwaysIncluded() {
        let templates = templateNames(for: makeBuilder())
        #expect(templates.contains("base.yaml"))
        #expect(templates.contains("app.yaml"))
        #expect(templates.contains("backup.yaml"))
    }

    // MARK: - SSR Templates Tests

    @Test func ssrEnvIncludedWhenReactStarterKit() {
        let templates = templateNames(for: makeBuilder(starterKit: .react))
        #expect(templates.contains("ssr-env.yaml"))
    }

    @Test func ssrEnvIncludedWhenVueStarterKit() {
        let templates = templateNames(for: makeBuilder(starterKit: .vue))
        #expect(templates.contains("ssr-env.yaml"))
    }

    @Test func ssrEnvNotIncludedWhenLivewire() {
        let templates = templateNames(for: makeBuilder(starterKit: .livewire))
        #expect(!templates.contains("ssr-env.yaml"))
    }

    @Test func ssrBunTemplateIncludedWhenReactWithBun() {
        let templates = templateNames(for: makeBuilder(starterKit: .react, jsPackageManager: .bun))
        #expect(templates.contains("ssr-bun.yaml"))
        #expect(!templates.contains("ssr-node.yaml"))
    }

    @Test func ssrNodeTemplateIncludedWhenReactWithNpm() {
        let templates = templateNames(for: makeBuilder(starterKit: .react, jsPackageManager: .npm))
        #expect(templates.contains("ssr-node.yaml"))
        #expect(!templates.contains("ssr-bun.yaml"))
    }

    // MARK: - SQLite Templates Tests

    @Test func sqliteVolumeIncludedWhenSQLite() {
        let templates = templateNames(for: makeBuilder(databaseType: .sqlite))
        #expect(templates.contains("sqlite.yaml"))
    }

    @Test func sqliteTemplatesNotIncludedWhenPostgreSQL() {
        let templates = templateNames(for: makeBuilder(databaseType: .postgresql))
        #expect(!templates.contains("sqlite.yaml"))
    }

    @Test func sqliteQueueVolumeIncludedWhenSQLiteWithQueue() {
        let templates = templateNames(for: makeBuilder(databaseType: .sqlite, queueService: .native, queueBackend: .database))
        #expect(templates.contains("sqlite-queue.yaml"))
    }

    @Test func sqliteHorizonVolumeIncludedWhenSQLiteWithHorizon() {
        let templates = templateNames(for: makeBuilder(databaseType: .sqlite, queueService: .horizon, queueBackend: .database))
        #expect(templates.contains("sqlite-horizon.yaml"))
    }

    @Test func sqliteSchedulerVolumeIncludedWhenSQLiteWithScheduler() {
        let templates = templateNames(for: makeBuilder(databaseType: .sqlite, taskScheduler: true))
        #expect(templates.contains("sqlite-scheduler.yaml"))
    }

    @Test func sqliteReverbVolumeIncludedWhenSQLiteWithReverb() {
        let templates = templateNames(for: makeBuilder(databaseType: .sqlite, reverb: true))
        #expect(templates.contains("sqlite-reverb.yaml"))
    }

    // MARK: - Octane Template Tests

    @Test func octaneTemplateIncludedWhenOctaneEnabled() {
        let templates = templateNames(for: makeBuilder(octane: true))
        #expect(templates.contains("app-octane.yaml"))
    }

    @Test func octaneTemplateNotIncludedWhenOctaneDisabled() {
        let templates = templateNames(for: makeBuilder(octane: false))
        #expect(!templates.contains("app-octane.yaml"))
    }

    // MARK: - Queue Service Templates Tests

    @Test func horizonTemplateIncludedWhenHorizonEnabled() {
        let templates = templateNames(for: makeBuilder(queueService: .horizon, queueBackend: .valkey))
        #expect(templates.contains("horizon.yaml"))
        #expect(!templates.contains("queue.yaml"))
    }

    @Test func queueTemplateIncludedWhenNativeEnabled() {
        let templates = templateNames(for: makeBuilder(queueService: .native, queueBackend: .valkey))
        #expect(templates.contains("queue.yaml"))
        #expect(!templates.contains("horizon.yaml"))
    }

    @Test func noQueueTemplateWhenQueueDisabled() {
        let templates = templateNames(for: makeBuilder(queueService: .none))
        #expect(!templates.contains("horizon.yaml"))
        #expect(!templates.contains("queue.yaml"))
    }

    // MARK: - Scheduler Template Tests

    @Test func schedulerTemplateIncludedWhenEnabled() {
        let templates = templateNames(for: makeBuilder(taskScheduler: true))
        #expect(templates.contains("scheduler.yaml"))
    }

    @Test func schedulerTemplateNotIncludedWhenDisabled() {
        let templates = templateNames(for: makeBuilder(taskScheduler: false))
        #expect(!templates.contains("scheduler.yaml"))
    }

    // MARK: - Reverb Template Tests

    @Test func reverbTemplateIncludedWhenEnabled() {
        let templates = templateNames(for: makeBuilder(reverb: true))
        #expect(templates.contains("reverb.yaml"))
    }

    @Test func reverbTemplateNotIncludedWhenDisabled() {
        let templates = templateNames(for: makeBuilder(reverb: false))
        #expect(!templates.contains("reverb.yaml"))
    }

    // MARK: - Valkey/Redis Templates Tests

    @Test func valkeyTemplateIncludedWhenValkeyQueue() {
        let templates = templateNames(for: makeBuilder(queueService: .horizon, queueBackend: .valkey))
        #expect(templates.contains("valkey.yaml"))
        #expect(!templates.contains("redis.yaml"))
    }

    @Test func valkeyTemplateIncludedWhenValkeyCache() {
        let templates = templateNames(for: makeBuilder(cacheService: .valkey))
        #expect(templates.contains("valkey.yaml"))
    }

    @Test func redisTemplateIncludedWhenRedisQueue() {
        let templates = templateNames(for: makeBuilder(queueService: .horizon, queueBackend: .redis))
        #expect(templates.contains("redis.yaml"))
        #expect(!templates.contains { $0 == "valkey.yaml" && !templates.contains("redis.yaml") })
    }

    @Test func redisTemplateIncludedWhenRedisCache() {
        let templates = templateNames(for: makeBuilder(cacheService: .redis))
        #expect(templates.contains("redis.yaml"))
    }

    // MARK: - Database Templates Tests

    @Test func mariadbTemplateIncludedWhenMariaDB() {
        let templates = templateNames(for: makeBuilder(databaseType: .mariadb))
        #expect(templates.contains("mariadb.yaml"))
    }

    @Test func mysqlTemplateIncludedWhenMySQL() {
        let templates = templateNames(for: makeBuilder(databaseType: .mysql))
        #expect(templates.contains("mysql.yaml"))
    }

    @Test func pgsqlTemplateIncludedWhenPostgreSQL() {
        let templates = templateNames(for: makeBuilder(databaseType: .postgresql))
        #expect(templates.contains("pgsql.yaml"))
    }

    @Test func noDatabaseServiceTemplateWhenSQLite() {
        let templates = templateNames(for: makeBuilder(databaseType: .sqlite))
        #expect(!templates.contains("mariadb.yaml"))
        #expect(!templates.contains("mysql.yaml"))
        #expect(!templates.contains("pgsql.yaml"))
    }

    // MARK: - Full Stack Configuration Tests

    @Test func fullStackConfigurationIncludesAllTemplates() {
        let builder = makeBuilder(
            projectName: "fullstack",
            starterKit: .react,
            jsPackageManager: .bun,
            databaseType: .postgresql,
            queueService: .horizon,
            queueBackend: .valkey,
            taskScheduler: true,
            reverb: true,
            octane: true
        )
        let templates = templateNames(for: builder)

        // Base templates
        #expect(templates.contains("base.yaml"))
        #expect(templates.contains("ssr-env.yaml"))
        #expect(templates.contains("app.yaml"))
        #expect(templates.contains("app-octane.yaml"))

        // Services
        #expect(templates.contains("horizon.yaml"))
        #expect(templates.contains("scheduler.yaml"))
        #expect(templates.contains("reverb.yaml"))
        #expect(templates.contains("ssr-bun.yaml"))
        #expect(templates.contains("valkey.yaml"))
        #expect(templates.contains("pgsql.yaml"))
        #expect(templates.contains("backup.yaml"))
    }

    @Test func minimalConfigurationIncludesMinimalTemplates() {
        let builder = makeBuilder(
            projectName: "minimal",
            starterKit: .none,
            databaseType: .sqlite,
            queueService: .none,
            taskScheduler: false,
            reverb: false,
            octane: false
        )
        let templates = templateNames(for: builder)

        // Should include
        #expect(templates.contains("base.yaml"))
        #expect(templates.contains("sqlite.yaml"))
        #expect(templates.contains("app.yaml"))
        #expect(templates.contains("backup.yaml"))

        // Should NOT include
        #expect(!templates.contains("ssr-env.yaml"))
        #expect(!templates.contains("app-octane.yaml"))
        #expect(!templates.contains("horizon.yaml"))
        #expect(!templates.contains("queue.yaml"))
        #expect(!templates.contains("scheduler.yaml"))
        #expect(!templates.contains("reverb.yaml"))
        #expect(!templates.contains("ssr-bun.yaml"))
        #expect(!templates.contains("ssr-node.yaml"))
        #expect(!templates.contains("valkey.yaml"))
        #expect(!templates.contains("redis.yaml"))
    }

    // MARK: - Certresolver Template Tests

    @Test func certresolverAlwaysIncluded() {
        let builder = makeBuilder(reverb: false)
        let templates = builder.certresolverFiles().map { $0.lastPathComponent }
        #expect(templates.contains("certresolver.yaml"))
    }

    @Test func certresolverReverbIncludedWhenReverbEnabled() {
        let builder = makeBuilder(reverb: true)
        let templates = builder.certresolverFiles().map { $0.lastPathComponent }
        #expect(templates.contains("certresolver.yaml"))
        #expect(templates.contains("certresolver-reverb.yaml"))
    }

    @Test func certresolverReverbNotIncludedWhenReverbDisabled() {
        let builder = makeBuilder(reverb: false)
        let templates = builder.certresolverFiles().map { $0.lastPathComponent }
        #expect(!templates.contains("certresolver-reverb.yaml"))
    }

    // MARK: - Template Order Tests

    @Test func templatesAreInCorrectOrder() {
        let builder = makeBuilder(
            starterKit: .react,
            databaseType: .postgresql,
            queueService: .horizon,
            queueBackend: .valkey,
            taskScheduler: true,
            reverb: true,
            octane: true
        )
        let templates = templateNames(for: builder)

        // app.yaml should be first
        #expect(templates.first == "app.yaml")

        // base.yaml should be last (so volumes/networks/secrets appear at end)
        #expect(templates.last == "base.yaml")

        // app before other services
        let appIndex = templates.firstIndex(of: "app.yaml")!
        let backupIndex = templates.firstIndex(of: "backup.yaml")!
        #expect(appIndex < backupIndex)
    }
}

// MARK: - Integration Tests (require yq binary)

/// These tests require the yq binary and compose templates from the app bundle
/// They are serialized because they all access the same yq binary
@Suite(.serialized)
@MainActor
struct ComposeYAMLIntegrationTests {
    private let testBundle = Bundle(for: ComposeTestBundleLocator.self)

    /// App bundle accessed via a class from the main target (official approach)
    /// Bundle(for: MainAppClass.self) returns the bundle containing that class
    /// See: https://stackoverflow.com/questions/1879247/why-cant-code-inside-unit-tests-find-bundle-resources
    private var appBundle: Bundle {
        Bundle(for: ProjectGeneratorService.self)
    }

    /// Path to yq binary in the app bundle
    private var yqPath: URL {
        appBundle.resourceURL!.appendingPathComponent("yq")
    }

    private var appBundleAvailable: Bool {
        guard let resourceURL = appBundle.resourceURL else { return false }
        let yqExists = FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("yq").path)
        let templatesExist = FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("base.yaml").path)
        return yqExists && templatesExist
    }

    private func makeBuilder(
        projectName: String = "myapp",
        starterKit: LaravelStarterKit = .none,
        jsPackageManager: JSPackageManager = .bun,
        databaseType: DatabaseType = .sqlite,
        queueService: QueueService = .none,
        queueBackend: QueueBackend? = nil,
        cacheService: CacheService? = nil,
        taskScheduler: Bool = false,
        reverb: Bool = false,
        octane: Bool = false
    ) -> ComposeYAMLBuilder {
        var config = ProjectConfiguration()
        config.projectName = projectName
        config.starterKit = starterKit
        config.jsPackageManager = jsPackageManager
        config.databaseType = databaseType
        config.queueService = queueService
        config.queueBackend = queueBackend
        config.cacheService = cacheService
        config.taskScheduler = taskScheduler
        config.reverb = reverb
        config.octane = octane
        return ComposeYAMLBuilder(config: config, bundle: appBundle, yqPath: yqPath)
    }

    // MARK: - Integration Tests

    @Test func bundleAccessWorks() throws {
        #expect(appBundleAvailable, "App bundle should have yq and templates")
    }

    @Test func generateProducesValidYAML() async throws {
        try #require(appBundleAvailable, "App bundle with yq and templates not available")

        let builder = makeBuilder()
        let yaml = try await builder.generate()

        // Basic structure checks
        #expect(yaml.contains("services:"))
        #expect(yaml.contains("networks:"))
        #expect(yaml.contains("volumes:"))
        #expect(yaml.contains("secrets:"))
    }

    @Test func projectNameSubstitutionWorks() async throws {
        try #require(appBundleAvailable, "App bundle with yq and templates not available")

        let builder = makeBuilder(projectName: "my-test-app", reverb: true)
        let yaml = try await builder.generate()

        // Check that {{PROJECT_NAME}} was replaced
        #expect(!yaml.contains("{{PROJECT_NAME}}"))
        #expect(yaml.contains("my-test-app"))
    }

    @Test func fullStackConfigGeneratesAllServices() async throws {
        try #require(appBundleAvailable, "App bundle with yq and templates not available")

        let builder = makeBuilder(
            projectName: "fullstack",
            starterKit: .react,
            jsPackageManager: .bun,
            databaseType: .postgresql,
            queueService: .horizon,
            queueBackend: .valkey,
            taskScheduler: true,
            reverb: true,
            octane: true
        )
        let yaml = try await builder.generate()

        // Check all services are present
        #expect(yaml.contains("app:"))
        #expect(yaml.contains("horizon:"))
        #expect(yaml.contains("scheduler:"))
        #expect(yaml.contains("reverb:"))
        #expect(yaml.contains("ssr:"))
        #expect(yaml.contains("valkey:"))
        #expect(yaml.contains("pgsql:"))
        #expect(yaml.contains("backup:"))
    }

    @Test func minimalConfigGeneratesMinimalServices() async throws {
        try #require(appBundleAvailable, "App bundle with yq and templates not available")

        let builder = makeBuilder(
            projectName: "minimal",
            starterKit: .none,
            databaseType: .sqlite,
            queueService: .none,
            taskScheduler: false,
            reverb: false,
            octane: false
        )
        let yaml = try await builder.generate()

        // Should have app and backup
        #expect(yaml.contains("app:"))
        #expect(yaml.contains("backup:"))

        // Should NOT have optional services
        #expect(!yaml.contains("horizon:"))
        #expect(!yaml.contains("queue:"))
        #expect(!yaml.contains("scheduler:"))
        #expect(!yaml.contains("reverb:"))
        #expect(!yaml.contains("ssr:"))
        #expect(!yaml.contains("valkey:"))
        #expect(!yaml.contains("redis:"))
        #expect(!yaml.contains("mariadb:"))
        #expect(!yaml.contains("mysql:"))
        #expect(!yaml.contains("pgsql:"))
    }

    // MARK: - Certresolver Integration Tests

    @Test func generateCertresolverProducesValidYAML() async throws {
        try #require(appBundleAvailable, "App bundle with yq and templates not available")

        let builder = makeBuilder()
        let yaml = try await builder.generateCertresolver()

        #expect(yaml.contains("services:"))
        #expect(yaml.contains("app:"))
        #expect(yaml.contains("certresolver"))
    }

    @Test func generateCertresolverSubstitutesProjectName() async throws {
        try #require(appBundleAvailable, "App bundle with yq and templates not available")

        let builder = makeBuilder(projectName: "my-test-app")
        let yaml = try await builder.generateCertresolver()

        #expect(!yaml.contains("{{PROJECT_NAME}}"))
        #expect(yaml.contains("my-test-app"))
    }

    @Test func generateCertresolverIncludesReverbWhenEnabled() async throws {
        try #require(appBundleAvailable, "App bundle with yq and templates not available")

        let builder = makeBuilder(projectName: "reverb-app", reverb: true)
        let yaml = try await builder.generateCertresolver()

        #expect(yaml.contains("reverb:"))
        #expect(yaml.contains("reverb-app-reverb"))
    }

    @Test func generateCertresolverExcludesReverbWhenDisabled() async throws {
        try #require(appBundleAvailable, "App bundle with yq and templates not available")

        let builder = makeBuilder(reverb: false)
        let yaml = try await builder.generateCertresolver()

        #expect(!yaml.contains("reverb:"))
    }
}
