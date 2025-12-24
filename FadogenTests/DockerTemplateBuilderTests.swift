import Foundation
import Testing
@testable import Fadogen

@MainActor
struct DockerTemplateBuilderTests {

    // MARK: - Helper

    private func makeBuilder(
        starterKit: LaravelStarterKit = .livewire,
        jsPackageManager: JSPackageManager = .bun,
        phpVersion: String = "8.4",
        databaseType: DatabaseType = .sqlite
    ) -> DockerTemplateBuilder {
        var config = ProjectConfiguration()
        config.starterKit = starterKit
        config.jsPackageManager = jsPackageManager
        config.phpVersion = phpVersion
        config.databaseType = databaseType
        return DockerTemplateBuilder(config: config)
    }

    // MARK: - Base Stage Tests

    @Test func baseStageUsesFrankenPHP() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("serversideup/php:${PHP_VERSION}-frankenphp AS base"))
    }

    @Test func baseStageInstallsBcmath() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("install-php-extensions bcmath"))
    }

    @Test func phpVersionArgIsSet() {
        let dockerfile = makeBuilder(phpVersion: "8.5").generateDockerfile()
        #expect(dockerfile.contains("ARG PHP_VERSION=8.5"))
    }

    // MARK: - Builder Stage Tests

    @Test func builderStageExistsInAllConfigs() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("FROM base AS builder"))
    }

    @Test func builderStageOptimizesAutoloader() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("composer dump-autoload --classmap-authoritative --no-dev"))
    }

    @Test func builderStageExcludesDevDependencies() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("--no-dev"))
    }

    @Test func builderStageAuditsComposer() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("--audit"))
    }

    // MARK: - Bun Runtime Tests

    @Test func bunImageUsedWhenBunSelected() {
        let dockerfile = makeBuilder(jsPackageManager: .bun).generateDockerfile()
        #expect(dockerfile.contains("COPY --from=oven/bun:1.3-debian /usr/local/bin/bun"))
    }

    @Test func bunCommandsWhenBunSelectedWithoutSSR() {
        let dockerfile = makeBuilder(starterKit: .livewire, jsPackageManager: .bun).generateDockerfile()
        #expect(dockerfile.contains("bun install --frozen-lockfile"))
        #expect(dockerfile.contains("bun run build"))
        #expect(dockerfile.contains("package.json bun.lock*"))
    }

    @Test func bunBuildSSRCommandWhenSSREnabled() {
        let dockerfile = makeBuilder(starterKit: .react, jsPackageManager: .bun).generateDockerfile()
        #expect(dockerfile.contains("bun run build:ssr"))
    }

    // MARK: - NPM Runtime Tests

    @Test func nodeImageUsedWhenNpmSelected() {
        let dockerfile = makeBuilder(jsPackageManager: .npm).generateDockerfile()
        // Uses node-base stage for reusability
        #expect(dockerfile.contains("FROM node:${NODE_VERSION}-bookworm-slim AS node-base"))
        #expect(dockerfile.contains("COPY --from=node-base /usr/local/bin/node"))
        #expect(dockerfile.contains("COPY --from=node-base /usr/local/lib/node_modules"))
    }

    @Test func npmCommandsWhenNpmSelectedWithoutSSR() {
        let dockerfile = makeBuilder(starterKit: .livewire, jsPackageManager: .npm).generateDockerfile()
        #expect(dockerfile.contains("npm ci"))
        #expect(dockerfile.contains("npm run build"))
        #expect(dockerfile.contains("package*.json"))
    }

    @Test func npmBuildSSRCommandWhenSSREnabled() {
        let dockerfile = makeBuilder(starterKit: .react, jsPackageManager: .npm).generateDockerfile()
        #expect(dockerfile.contains("npm run build:ssr"))
    }

    @Test func npmSymlinksCreated() {
        let dockerfile = makeBuilder(jsPackageManager: .npm).generateDockerfile()
        #expect(dockerfile.contains("ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm"))
    }

    // MARK: - App Stage Tests

    @Test func appStageExistsInAllConfigs() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("FROM base AS app"))
    }

    @Test func appStageCopiesFromBuilder() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("COPY --link --chown=33:33 --from=builder /var/www/html/vendor ./vendor"))
    }

    @Test func appStageCopiesAssets() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("COPY --link --chown=33:33 --from=builder /var/www/html/public/build ./public/build"))
    }

    @Test func appStageCreatesStorageDirectories() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("storage/logs"))
        #expect(dockerfile.contains("storage/framework/cache"))
        #expect(dockerfile.contains("bootstrap/cache"))
    }

    @Test func appStageSetsCorrectUser() {
        let dockerfile = makeBuilder().generateDockerfile()
        let lines = dockerfile.components(separatedBy: "\n")
        let userLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("USER ") }
        let lastUserLine = userLines.last
        #expect(lastUserLine?.contains("www-data") == true)
    }

    // MARK: - SSR Stage Tests (Mandatory for React/Vue)

    @Test func ssrStageNotIncludedWithLivewire() {
        let dockerfile = makeBuilder(starterKit: .livewire).generateDockerfile()
        #expect(!dockerfile.contains("AS ssr"))
    }

    @Test func ssrStageNotIncludedWithoutStarterKit() {
        let dockerfile = makeBuilder(starterKit: .none).generateDockerfile()
        #expect(!dockerfile.contains("AS ssr"))
    }

    @Test func ssrStageIncludedWithReact() {
        let dockerfile = makeBuilder(starterKit: .react).generateDockerfile()
        #expect(dockerfile.contains("AS ssr"))
    }

    @Test func ssrStageIncludedWithVue() {
        let dockerfile = makeBuilder(starterKit: .vue).generateDockerfile()
        #expect(dockerfile.contains("AS ssr"))
    }

    @Test func ssrStageWithBunUsesBunImage() {
        let dockerfile = makeBuilder(starterKit: .react, jsPackageManager: .bun).generateDockerfile()
        #expect(dockerfile.contains("FROM oven/bun:1.3-debian AS ssr"))
        #expect(dockerfile.contains(#"CMD ["bun", "bootstrap/ssr/ssr.js"]"#))
    }

    @Test func ssrStageWithNpmUsesNodeImage() {
        let dockerfile = makeBuilder(starterKit: .react, jsPackageManager: .npm).generateDockerfile()
        // Uses node-base stage (reused from builder)
        #expect(dockerfile.contains("FROM node-base AS ssr"))
        #expect(dockerfile.contains(#"CMD ["node", "bootstrap/ssr/ssr.js"]"#))
    }

    @Test func ssrStageCopiesRequiredFiles() {
        let dockerfile = makeBuilder(starterKit: .react).generateDockerfile()
        // node_modules is NOT copied anymore (using ssr: { noExternal: true } in vite.config)
        #expect(!dockerfile.contains("COPY --from=builder /var/www/html/node_modules ./node_modules"))
        #expect(dockerfile.contains("COPY --from=builder /var/www/html/bootstrap/ssr ./bootstrap/ssr"))
        #expect(dockerfile.contains("EXPOSE 13714"))
    }

    // MARK: - SQLite Storage Tests

    @Test func sqliteCreatesDatabaseDirectory() {
        let dockerfile = makeBuilder(databaseType: .sqlite).generateDockerfile()
        #expect(dockerfile.contains("mkdir -p storage/database"))
    }

    @Test func sqliteCreatesDatabaseFile() {
        let dockerfile = makeBuilder(databaseType: .sqlite).generateDockerfile()
        #expect(dockerfile.contains("touch storage/database/database.sqlite"))
    }

    @Test func sqliteSetsCorrectOwnership() {
        let dockerfile = makeBuilder(databaseType: .sqlite).generateDockerfile()
        #expect(dockerfile.contains("chown -R www-data:www-data storage/database"))
    }

    @Test func postgresqlDoesNotIncludeSqliteSetup() {
        let dockerfile = makeBuilder(databaseType: .postgresql).generateDockerfile()
        #expect(!dockerfile.contains("storage/database"))
        #expect(!dockerfile.contains("database.sqlite"))
    }

    @Test func mysqlDoesNotIncludeSqliteSetup() {
        let dockerfile = makeBuilder(databaseType: .mysql).generateDockerfile()
        #expect(!dockerfile.contains("storage/database"))
        #expect(!dockerfile.contains("database.sqlite"))
    }

    @Test func mariadbDoesNotIncludeSqliteSetup() {
        let dockerfile = makeBuilder(databaseType: .mariadb).generateDockerfile()
        #expect(!dockerfile.contains("storage/database"))
        #expect(!dockerfile.contains("database.sqlite"))
    }

    // MARK: - Stage Order Tests

    @Test func stagesAreInCorrectOrderWithSSR() {
        let dockerfile = makeBuilder(starterKit: .react).generateDockerfile()
        let baseIndex = dockerfile.range(of: "AS base")!.lowerBound
        let builderIndex = dockerfile.range(of: "AS builder")!.lowerBound
        let appIndex = dockerfile.range(of: "AS app")!.lowerBound
        let ssrIndex = dockerfile.range(of: "AS ssr")!.lowerBound

        #expect(baseIndex < builderIndex)
        #expect(builderIndex < appIndex)
        #expect(appIndex < ssrIndex)
    }

    // MARK: - Full Output Snapshot Tests

    @Test func configWithoutSSRGeneratesThreeStages() {
        let dockerfile = makeBuilder(starterKit: .livewire).generateDockerfile()
        let stageCount = dockerfile.components(separatedBy: "FROM ").count - 1
        #expect(stageCount == 3) // base, builder, app
    }

    @Test func configWithSSRGeneratesFourStages() {
        let dockerfile = makeBuilder(starterKit: .react).generateDockerfile()
        let stageCount = dockerfile.components(separatedBy: "FROM ").count - 1
        #expect(stageCount == 4) // base, builder, app, ssr
    }

    // MARK: - Docker Best Practices Tests

    @Test func usesLinkFlagForCaching() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("COPY --link"))
    }

    @Test func usesNumericChownForEfficiency() {
        let dockerfile = makeBuilder().generateDockerfile()
        #expect(dockerfile.contains("--chown=33:33"))
    }
}
