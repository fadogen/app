import Foundation
import Subprocess
import System

// MARK: - Laravel

extension ProjectGeneratorService {
    func laravelGenerationSteps() -> [GenerationStep] {
        [
            GenerationStep(name: "Creating project...", weight: 25) { [self] config, _ in
                try await createLaravelProject(config: config)
            },
            GenerationStep(name: "Running post-install setup...", weight: 5) { [self] config, projectPath in
                try await laravelPostInstallSetup(projectPath: projectPath!, config: config)
                return projectPath
            },
            GenerationStep(name: "Installing JavaScript dependencies...", weight: 15) { [self] config, projectPath in
                try await installJSDependencies(config: config, projectPath: projectPath!)
                return projectPath
            },
            GenerationStep(name: "Installing Fadogen Vite plugin...", weight: 5) { [self] config, projectPath in
                try await installFadogenVitePlugin(config: config, projectPath: projectPath!)
                return projectPath
            },
            GenerationStep(name: "Configuring environment...", weight: 5) { [self] config, projectPath in
                try await configureLaravelEnvironment(config: config, projectPath: projectPath!)
                return projectPath
            },
            GenerationStep(name: "Running migrations...", weight: 10) { [self] config, projectPath in
                try await runLaravelMigrations(projectPath: projectPath!, config: config)
                return projectPath
            },
            GenerationStep(name: "Configuring test framework...", weight: 10) { [self] config, projectPath in
                try await migrateToPest(config: config, projectPath: projectPath!)
                return projectPath
            },
            GenerationStep(name: "Installing optional packages...", weight: 15) { [self] config, projectPath in
                try await installOptionalPackages(config: config, projectPath: projectPath!)
                return projectPath
            },
            GenerationStep(name: "Configuring proxy settings...", weight: 2) { [self] config, projectPath in
                try await configureTrustedProxies(config: config, projectPath: projectPath!)
                return projectPath
            },
            GenerationStep(name: "Generating Docker configuration...", weight: 5) { [self] config, projectPath in
                try await generateDockerFiles(config: config, projectPath: projectPath!)
                return projectPath
            },
            GenerationStep(name: "Creating production environment template...", weight: 3) { [self] config, projectPath in
                try await createProductionEnvTemplate(projectPath: projectPath!, config: config)
                return projectPath
            },
            GenerationStep(name: "Syncing environment files...", weight: 1) { [self] _, projectPath in
                try syncEnvExample(projectPath: projectPath!)
                return projectPath
            },
            GenerationStep(name: "Initializing Git repository...", weight: 10) { [self] _, projectPath in
                try await initializeGit(projectPath: projectPath!)
                return projectPath
            }
        ]
    }

    // MARK: - Composer

    func composerPackageInfo(for config: ProjectConfiguration) -> (package: String, needsStabilityDev: Bool) {
        switch config.starterKit {
        case .none:
            return ("laravel/laravel:^12", false)
        case .custom:
            return (config.customStarterKitRepo.trimmingCharacters(in: .whitespacesAndNewlines), true)
        case .react, .vue, .livewire:
            let type = config.starterKit.rawValue
            if config.authentication == .workos {
                return ("laravel/\(type)-starter-kit:dev-workos", true)
            } else if config.starterKit == .livewire && config.volt {
                return ("laravel/livewire-starter-kit:dev-components", true)
            } else {
                return ("laravel/\(type)-starter-kit", true)
            }
        }
    }

    // MARK: - Project Creation

    func createLaravelProject(config: ProjectConfiguration) async throws -> URL {
        guard let installDirectory = config.installDirectory,
              let projectName = config.projectName.sanitizedHostname() else {
            throw ProjectGeneratorError.invalidProjectName(config.projectName)
        }

        let projectPath = installDirectory.appendingPathComponent(projectName)
        let phpBinary = FadogenPaths.binaryPath(for: config.phpVersion)
        let composerPhar = FadogenPaths.binDirectory.appendingPathComponent("composer.phar")

        guard FileManager.default.fileExists(atPath: phpBinary.path) else {
            throw ProjectGeneratorError.commandFailed(
                command: "php",
                exitCode: 1,
                output: "PHP \(config.phpVersion) not installed"
            )
        }

        let (composerPackage, needsStabilityDev) = composerPackageInfo(for: config)

        var arguments: [String] = [
            composerPhar.path,
            "create-project",
            "--no-interaction",
            "--remove-vcs",
            "--prefer-dist",
            "--no-scripts",
            composerPackage,
            projectName
        ]

        if needsStabilityDev {
            arguments.insert("--stability=dev", at: 3)
        }

        try await runCommand(phpBinary, arguments: arguments, workingDirectory: installDirectory)
        return projectPath
    }

    // MARK: - Post-Installation

    func laravelPostInstallSetup(projectPath: URL, config: ProjectConfiguration) async throws {
        let phpBinary = FadogenPaths.binaryPath(for: config.phpVersion)
        let composerPhar = FadogenPaths.binDirectory.appendingPathComponent("composer.phar")

        try await runCommand(
            phpBinary,
            arguments: [composerPhar.path, "run", "post-root-package-install"],
            workingDirectory: projectPath
        )

        let artisanPath = projectPath.appendingPathComponent("artisan").path
        try await runCommand(
            phpBinary,
            arguments: [artisanPath, "key:generate", "--ansi"],
            workingDirectory: projectPath
        )

        let lockFile = projectPath.appendingPathComponent("package-lock.json")
        if FileManager.default.fileExists(atPath: lockFile.path) {
            try FileManager.default.removeItem(at: lockFile)
        }
    }

    // MARK: - JavaScript

    var jsEnvironment: Subprocess.Environment {
        let binPath = FadogenPaths.binDirectory.path
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return .inherit.updating(["PATH": "\(binPath):\(currentPath)"])
    }

    func installJSDependencies(config: ProjectConfiguration, projectPath: URL) async throws {
        let binary: URL
        switch config.jsPackageManager {
        case .none:
            return  // No JavaScript dependencies to install
        case .bun:
            binary = FadogenPaths.binDirectory.appendingPathComponent("bun")
        case .npm:
            binary = FadogenPaths.binDirectory.appendingPathComponent("npm")
        }

        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw ProjectGeneratorError.commandFailed(
                command: config.jsPackageManager.rawValue,
                exitCode: 1,
                output: "\(config.jsPackageManager.displayName) not installed"
            )
        }

        try await runCommand(binary, arguments: ["install"], workingDirectory: projectPath, environment: jsEnvironment)
    }

    // MARK: - Environment

    func configureLaravelEnvironment(config: ProjectConfiguration, projectPath: URL) async throws {
        let projectName = config.projectName.sanitizedHostname() ?? config.projectName
        let envPath = projectPath.appendingPathComponent(".env")

        var envContent = try String(contentsOf: envPath, encoding: .utf8)

        envContent = EnvFileEditor.configureAppURL(in: envContent, projectName: projectName)

        if config.databaseType == .sqlite {
            let databaseDir = projectPath.appendingPathComponent("database")
            let sqliteFile = databaseDir.appendingPathComponent("database.sqlite")
            FileManager.default.createFile(atPath: sqliteFile.path, contents: nil)
        } else {
            let dbPort = config.databasePort ?? config.databaseType.defaultPort
            envContent = EnvFileEditor.configureDatabaseConnection(
                in: envContent,
                databaseType: config.databaseType,
                port: dbPort,
                databaseName: projectName
            )
        }

        if let cacheService = config.cacheService {
            let cachePort = config.cachePort ?? cacheService.defaultPort
            envContent = EnvFileEditor.configureCacheService(in: envContent, port: cachePort)
        }

        envContent = EnvFileEditor.configureMailpit(in: envContent)

        try envContent.write(to: envPath, atomically: true, encoding: .utf8)
    }

    func syncEnvExample(projectPath: URL) throws {
        let envPath = projectPath.appendingPathComponent(".env")
        let envExamplePath = projectPath.appendingPathComponent(".env.example")

        let envContent = try String(contentsOf: envPath, encoding: .utf8)
        let envExampleContent = envContent.replacingOccurrences(
            of: #"APP_KEY=.+"#,
            with: "APP_KEY=",
            options: .regularExpression
        )
        try envExampleContent.write(to: envExamplePath, atomically: true, encoding: .utf8)
    }

    // MARK: - Migrations

    func runLaravelMigrations(projectPath: URL, config: ProjectConfiguration) async throws {
        let phpBinary = FadogenPaths.binaryPath(for: config.phpVersion)
        let artisanPath = projectPath.appendingPathComponent("artisan").path

        try await runCommand(
            phpBinary,
            arguments: [artisanPath, "migrate", "--force", "--no-interaction"],
            workingDirectory: projectPath
        )
    }

    // MARK: - Testing

    func migrateToPest(config: ProjectConfiguration, projectPath: URL) async throws {
        guard config.testingFramework == .pest else { return }

        let phpBinary = FadogenPaths.binaryPath(for: config.phpVersion)
        let composerPhar = FadogenPaths.binDirectory.appendingPathComponent("composer.phar")
        let pestBinary = projectPath.appendingPathComponent("vendor/bin/pest")

        try await runCommand(
            phpBinary,
            arguments: [composerPhar.path, "remove", "phpunit/phpunit", "--dev", "--no-update"],
            workingDirectory: projectPath
        )

        try await runCommand(
            phpBinary,
            arguments: [composerPhar.path, "require", "pestphp/pest", "pestphp/pest-plugin-laravel", "--no-update", "--dev"],
            workingDirectory: projectPath
        )

        try await runCommand(
            phpBinary,
            arguments: [composerPhar.path, "update"],
            workingDirectory: projectPath
        )

        if config.starterKit == .none {
            let testsFeature = projectPath.appendingPathComponent("tests/Feature/ExampleTest.php")
            let testsUnit = projectPath.appendingPathComponent("tests/Unit/ExampleTest.php")
            try? FileManager.default.removeItem(at: testsFeature)
            try? FileManager.default.removeItem(at: testsUnit)
        }

        try await runCommand(
            phpBinary,
            arguments: [pestBinary.path, "--init"],
            workingDirectory: projectPath,
            environment: .inherit.updating(["PEST_NO_SUPPORT": "true"])
        )

        if config.starterKit != .none {
            try await runCommand(
                phpBinary,
                arguments: [composerPhar.path, "require", "pestphp/pest-plugin-drift", "--dev"],
                workingDirectory: projectPath
            )

            try await runCommand(
                phpBinary,
                arguments: [pestBinary.path, "--drift"],
                workingDirectory: projectPath
            )

            try await runCommand(
                phpBinary,
                arguments: [composerPhar.path, "remove", "pestphp/pest-plugin-drift", "--dev"],
                workingDirectory: projectPath
            )

            let workflowPath = projectPath.appendingPathComponent(".github/workflows/tests.yml")
            if FileManager.default.fileExists(atPath: workflowPath.path) {
                var content = try String(contentsOf: workflowPath, encoding: .utf8)
                content = content.replacingOccurrences(of: "phpunit", with: "pest")
                try content.write(to: workflowPath, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Optional Packages

    func installOptionalPackages(config: ProjectConfiguration, projectPath: URL) async throws {
        let phpBinary = FadogenPaths.binaryPath(for: config.phpVersion)
        let composerPhar = FadogenPaths.binDirectory.appendingPathComponent("composer.phar")
        let artisanPath = projectPath.appendingPathComponent("artisan").path

        if config.queueService == .horizon {
            try await runCommand(
                phpBinary,
                arguments: [composerPhar.path, "require", "laravel/horizon"],
                workingDirectory: projectPath
            )
            try await runCommand(
                phpBinary,
                arguments: [artisanPath, "horizon:install", "--no-interaction"],
                workingDirectory: projectPath
            )
        }

        if config.reverb {
            try await runCommand(
                phpBinary,
                arguments: [
                    artisanPath, "install:broadcasting",
                    "--reverb", "--without-node", "--no-interaction",
                    "--composer=\(composerPhar.path)"
                ],
                workingDirectory: projectPath
            )

            let envPath = projectPath.appendingPathComponent(".env")
            var envContent = try String(contentsOf: envPath, encoding: .utf8)
            envContent = EnvFileEditor.configureReverb(in: envContent)
            try envContent.write(to: envPath, atomically: true, encoding: .utf8)

            try await installEchoPackages(config: config, projectPath: projectPath)
        }

        if config.octane {
            try await runCommand(
                phpBinary,
                arguments: [composerPhar.path, "require", "laravel/octane"],
                workingDirectory: projectPath
            )
            try await runCommand(
                phpBinary,
                arguments: [artisanPath, "octane:install", "--server=frankenphp", "--no-interaction"],
                workingDirectory: projectPath
            )
        }

        if config.scout {
            try await runCommand(
                phpBinary,
                arguments: [composerPhar.path, "require", "laravel/scout"],
                workingDirectory: projectPath
            )
            try await runCommand(
                phpBinary,
                arguments: [artisanPath, "vendor:publish", "--provider=Laravel\\Scout\\ScoutServiceProvider", "--no-interaction"],
                workingDirectory: projectPath
            )

            let envPath = projectPath.appendingPathComponent(".env")
            var envContent = try String(contentsOf: envPath, encoding: .utf8)
            let projectName = config.projectName.sanitizedHostname() ?? config.projectName
            let hasQueueWorker = config.queueService != .none
            envContent = EnvFileEditor.configureScout(in: envContent, projectName: projectName, hasQueueWorker: hasQueueWorker)
            try envContent.write(to: envPath, atomically: true, encoding: .utf8)
        }
    }

    func installEchoPackages(config: ProjectConfiguration, projectPath: URL) async throws {
        var packages = ["laravel-echo", "pusher-js"]

        switch config.starterKit {
        case .react:
            packages.append("@laravel/echo-react")
        case .vue:
            packages.append("@laravel/echo-vue")
        case .none, .livewire, .custom:
            break
        }

        let binary: URL
        let arguments: [String]

        switch config.jsPackageManager {
        case .none:
            return  // No JavaScript package manager
        case .bun:
            binary = FadogenPaths.binDirectory.appendingPathComponent("bun")
            arguments = ["add", "--dev"] + packages
        case .npm:
            binary = FadogenPaths.binDirectory.appendingPathComponent("npm")
            arguments = ["install", "--save-dev"] + packages
        }

        try await runCommand(binary, arguments: arguments, workingDirectory: projectPath, environment: jsEnvironment)
    }

    // MARK: - Trusted Proxies

    func configureTrustedProxies(config: ProjectConfiguration, projectPath: URL) async throws {
        let bootstrapAppPath = projectPath.appendingPathComponent("bootstrap/app.php")
        guard FileManager.default.fileExists(atPath: bootstrapAppPath.path) else { return }

        var content = try String(contentsOf: bootstrapAppPath, encoding: .utf8)
        content = BootstrapAppEditor.addTrustedProxies(in: content)
        try content.write(to: bootstrapAppPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Vite Plugin

    func installFadogenVitePlugin(config: ProjectConfiguration, projectPath: URL) async throws {
        let viteConfigTS = projectPath.appendingPathComponent("vite.config.ts")
        let viteConfigJS = projectPath.appendingPathComponent("vite.config.js")

        let viteConfigPath: URL
        if FileManager.default.fileExists(atPath: viteConfigTS.path) {
            viteConfigPath = viteConfigTS
        } else if FileManager.default.fileExists(atPath: viteConfigJS.path) {
            viteConfigPath = viteConfigJS
        } else {
            return
        }

        let binary: URL
        let arguments: [String]

        switch config.jsPackageManager {
        case .none:
            return  // No JavaScript package manager
        case .bun:
            binary = FadogenPaths.binDirectory.appendingPathComponent("bun")
            arguments = ["add", "--dev", "@fadogen/vite-plugin"]
        case .npm:
            binary = FadogenPaths.binDirectory.appendingPathComponent("npm")
            arguments = ["install", "--save-dev", "@fadogen/vite-plugin"]
        }

        try await runCommand(binary, arguments: arguments, workingDirectory: projectPath, environment: jsEnvironment)

        var viteConfigContent = try String(contentsOf: viteConfigPath, encoding: .utf8)
        viteConfigContent = ViteConfigEditor.addFadogenPlugin(in: viteConfigContent)
        if config.ssr {
            viteConfigContent = ViteConfigEditor.addSSRConfig(in: viteConfigContent)
        }
        try viteConfigContent.write(to: viteConfigPath, atomically: true, encoding: .utf8)

        let composerJsonPath = projectPath.appendingPathComponent("composer.json")
        if FileManager.default.fileExists(atPath: composerJsonPath.path) {
            var composerContent = try String(contentsOf: composerJsonPath, encoding: .utf8)
            composerContent = ComposerJsonEditor.removeArtisanServe(in: composerContent)
            if config.jsPackageManager == .bun {
                composerContent = ComposerJsonEditor.replaceNpmWithBun(in: composerContent)
            }
            try composerContent.write(to: composerJsonPath, atomically: true, encoding: .utf8)
        }

        if config.jsPackageManager == .bun {
            for workflowName in ["lint.yml", "tests.yml"] {
                let workflowPath = projectPath.appendingPathComponent(".github/workflows/\(workflowName)")
                if FileManager.default.fileExists(atPath: workflowPath.path) {
                    var workflowContent = try String(contentsOf: workflowPath, encoding: .utf8)
                    workflowContent = GitHubWorkflowEditor.replaceNpmWithBun(in: workflowContent)
                    try workflowContent.write(to: workflowPath, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    // MARK: - Docker

    func generateDockerFiles(config: ProjectConfiguration, projectPath: URL) async throws {
        let dockerBuilder = DockerTemplateBuilder(config: config)

        let dockerfile = dockerBuilder.generateDockerfile()
        let dockerfilePath = projectPath.appendingPathComponent("Dockerfile")
        try dockerfile.write(to: dockerfilePath, atomically: true, encoding: .utf8)

        try generateDockerignore(projectPath: projectPath)

        let composeBuilder = ComposeYAMLBuilder(config: config)
        let composeYAML = try await composeBuilder.generate()
        let composePath = projectPath.appendingPathComponent("compose.prod.yaml")
        try composeYAML.write(to: composePath, atomically: true, encoding: .utf8)

        let certresolverYAML = try await composeBuilder.generateCertresolver()
        let certresolverPath = projectPath.appendingPathComponent("compose.prod.certresolver.yaml")
        try certresolverYAML.write(to: certresolverPath, atomically: true, encoding: .utf8)

        let workflowDir = projectPath.appendingPathComponent(".github/workflows")
        try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
        let deployWorkflow = dockerBuilder.generateDeployWorkflow()
        let workflowPath = workflowDir.appendingPathComponent("deploy.yml")
        try deployWorkflow.write(to: workflowPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Production Environment

    func createProductionEnvTemplate(projectPath: URL, config: ProjectConfiguration) async throws {
        let envDistPath = projectPath.appendingPathComponent(".env.production.dist")

        let hasRedisOrValkey = config.cacheService != nil ||
            config.queueBackend == .redis ||
            config.queueBackend == .valkey

        let redisHostName: String
        if let cacheService = config.cacheService {
            redisHostName = cacheService.rawValue
        } else if config.queueBackend == .valkey {
            redisHostName = "valkey"
        } else {
            redisHostName = "redis"
        }

        var template = """
            APP_NAME=Laravel
            APP_ENV=production
            APP_KEY=
            APP_DEBUG=false
            APP_HOST=
            APP_URL="https://${APP_HOST}"

            APP_LOCALE=en
            APP_FALLBACK_LOCALE=en
            APP_FAKER_LOCALE=en_US

            APP_MAINTENANCE_DRIVER=file
            # APP_MAINTENANCE_STORE=database

            # PHP_CLI_SERVER_WORKERS=4

            BCRYPT_ROUNDS=12

            LOG_CHANNEL=daily
            LOG_STACK=single
            LOG_DEPRECATIONS_CHANNEL=null
            LOG_LEVEL=warning

            """

        if config.databaseType == .sqlite {
            template += """
                DB_CONNECTION=sqlite
                DB_DATABASE=/var/www/html/storage/database/database.sqlite

                """
        } else {
            let dbConnection = config.databaseType.envConnectionName
            let dbPort = config.databaseType.defaultPort
            let dbHost = config.databaseType == .postgresql ? "pgsql" : config.databaseType.rawValue

            template += """
                DB_CONNECTION=\(dbConnection)
                DB_HOST=\(dbHost)
                DB_PORT=\(dbPort)
                DB_DATABASE=
                DB_USERNAME=
                DB_PASSWORD=

                """
        }

        if hasRedisOrValkey {
            template += """
                SESSION_DRIVER=redis
                SESSION_LIFETIME=120
                SESSION_ENCRYPT=false
                SESSION_PATH=/
                SESSION_DOMAIN=null

                BROADCAST_CONNECTION=log
                FILESYSTEM_DISK=local
                QUEUE_CONNECTION=redis

                CACHE_STORE=redis

                REDIS_CLIENT=phpredis
                REDIS_HOST=\(redisHostName)
                REDIS_PASSWORD=
                REDIS_PORT=6379

                """
        } else if config.queueBackend == .database {
            template += """
                SESSION_DRIVER=database
                SESSION_LIFETIME=120
                SESSION_ENCRYPT=false
                SESSION_PATH=/
                SESSION_DOMAIN=null

                BROADCAST_CONNECTION=log
                FILESYSTEM_DISK=local
                QUEUE_CONNECTION=database

                CACHE_STORE=database

                """
        } else {
            template += """
                SESSION_DRIVER=file
                SESSION_LIFETIME=120
                SESSION_ENCRYPT=false
                SESSION_PATH=/
                SESSION_DOMAIN=null

                BROADCAST_CONNECTION=log
                FILESYSTEM_DISK=local
                QUEUE_CONNECTION=sync

                CACHE_STORE=file

                """
        }

        template += """
            MAIL_MAILER=log
            MAIL_SCHEME=null
            MAIL_HOST=127.0.0.1
            MAIL_PORT=2525
            MAIL_USERNAME=null
            MAIL_PASSWORD=null
            MAIL_FROM_ADDRESS="hello@example.com"
            MAIL_FROM_NAME="${APP_NAME}"

            VITE_APP_NAME="${APP_NAME}"
            """

        if config.reverb {
            template += """

                REVERB_APP_ID=
                REVERB_APP_KEY=
                REVERB_APP_SECRET=
                REVERB_HOST="${APP_HOST}"
                REVERB_PORT=443
                REVERB_SCHEME=https

                VITE_REVERB_APP_KEY="${REVERB_APP_KEY}"
                VITE_REVERB_HOST="${REVERB_HOST}"
                VITE_REVERB_PORT="${REVERB_PORT}"
                VITE_REVERB_SCHEME="${REVERB_SCHEME}"
                """
        }

        if config.scout {
            let prefix = (config.projectName.sanitizedHostname() ?? "app").replacingOccurrences(of: "-", with: "_")
            // Enable queue-based indexing only if a queue worker is configured
            let scoutQueue = config.queueService != .none ? "true" : "false"
            template += """


                SCOUT_DRIVER=typesense
                SCOUT_QUEUE=\(scoutQueue)
                SCOUT_PREFIX=\(prefix)_

                TYPESENSE_API_KEY=
                TYPESENSE_HOST=typesense
                TYPESENSE_PORT=8108
                TYPESENSE_PROTOCOL=http
                """
        }

        try template.write(to: envDistPath, atomically: true, encoding: .utf8)
    }
}
