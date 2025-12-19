import Foundation

// MARK: - Symfony

extension ProjectGeneratorService {
    func symfonyGenerationSteps() -> [GenerationStep] {
        [
            GenerationStep(name: "Creating Symfony project...", weight: 40) { [self] config, _ in
                try await createSymfonyProject(config: config)
            },
            GenerationStep(name: "Configuring environment...", weight: 15) { [self] config, projectPath in
                try await configureSymfonyEnvironment(config: config, projectPath: projectPath!)
                return projectPath
            },
            GenerationStep(name: "Generating Docker configuration...", weight: 10) { [self] config, projectPath in
                try await generateSymfonyDockerFiles(config: config, projectPath: projectPath!)
                return projectPath
            },
            GenerationStep(name: "Creating production environment template...", weight: 5) { [self] config, projectPath in
                try await createSymfonyProductionEnvTemplate(projectPath: projectPath!, config: config)
                return projectPath
            },
            GenerationStep(name: "Initializing Git repository...", weight: 15) { [self] _, projectPath in
                try await initializeGit(projectPath: projectPath!)
                return projectPath
            }
        ]
    }

    func createSymfonyProject(config: ProjectConfiguration) async throws -> URL {
        guard let installDirectory = config.installDirectory,
              let projectName = config.projectName.sanitizedHostname() else {
            throw ProjectGeneratorError.invalidProjectName(config.projectName)
        }

        let projectPath = installDirectory.appendingPathComponent(projectName)
        let phpBinary = FadogenPaths.binaryPath(for: config.phpVersion)
        let composerPhar = FadogenPaths.binDirectory.appendingPathComponent("composer.phar")

        // Verify PHP binary exists
        guard FileManager.default.fileExists(atPath: phpBinary.path) else {
            throw ProjectGeneratorError.commandFailed(
                command: "php",
                exitCode: 1,
                output: "PHP \(config.phpVersion) not installed"
            )
        }

        // Create Symfony skeleton project
        try await runCommand(
            phpBinary,
            arguments: [
                composerPhar.path,
                "create-project",
                "--no-interaction",
                "--prefer-dist",
                "symfony/skeleton:^7.4",
                projectName
            ],
            workingDirectory: installDirectory
        )

        // Install webapp pack for full-stack applications
        if config.symfonyProjectType == .webapp {
            try await runCommand(
                phpBinary,
                arguments: [composerPhar.path, "require", "webapp", "--no-interaction"],
                workingDirectory: projectPath
            )
        }

        // Install API Platform for API projects
        if config.symfonyProjectType == .api {
            try await runCommand(
                phpBinary,
                arguments: [composerPhar.path, "require", "api", "--no-interaction"],
                workingDirectory: projectPath
            )
        }

        return projectPath
    }

    func configureSymfonyEnvironment(config: ProjectConfiguration, projectPath: URL) async throws {
        guard let projectName = config.projectName.sanitizedHostname() else { return }
        let envPath = projectPath.appendingPathComponent(".env")

        guard FileManager.default.fileExists(atPath: envPath.path) else { return }

        var envContent = try String(contentsOf: envPath, encoding: .utf8)

        // Configure database URL based on type
        let databaseURL: String
        switch config.databaseType {
        case .sqlite:
            databaseURL = "sqlite:///%kernel.project_dir%/var/data/database.sqlite"
            // Create var/data directory for SQLite database with .gitkeep
            let dataDir = projectPath.appendingPathComponent("var/data")
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try "".write(to: dataDir.appendingPathComponent(".gitkeep"), atomically: true, encoding: .utf8)
        case .mysql:
            let port = config.databasePort ?? 3306
            let version = config.mysqlVersion ?? "9.0"
            databaseURL = "mysql://root:@127.0.0.1:\(port)/\(projectName)?serverVersion=\(version)"
        case .mariadb:
            let port = config.databasePort ?? 3306
            let version = config.mariadbVersion ?? "11"
            databaseURL = "mysql://root:@127.0.0.1:\(port)/\(projectName)?serverVersion=mariadb-\(version)"
        case .postgresql:
            let port = config.databasePort ?? 5432
            let version = config.postgresVersion ?? "17"
            databaseURL = "postgresql://postgres:@127.0.0.1:\(port)/\(projectName)?serverVersion=\(version)"
        }

        // Update or add DATABASE_URL
        if envContent.contains("DATABASE_URL=") {
            envContent = envContent.replacingOccurrences(
                of: #"DATABASE_URL=.*"#,
                with: "DATABASE_URL=\"\(databaseURL)\"",
                options: .regularExpression
            )
        } else {
            envContent += "\nDATABASE_URL=\"\(databaseURL)\"\n"
        }

        // Configure Mailpit for local email testing
        let mailerDSN = "smtp://127.0.0.1:1025"
        if envContent.contains("MAILER_DSN=") {
            envContent = envContent.replacingOccurrences(
                of: #"MAILER_DSN=.*"#,
                with: "MAILER_DSN=\"\(mailerDSN)\"",
                options: .regularExpression
            )
        } else {
            envContent += "MAILER_DSN=\"\(mailerDSN)\"\n"
        }

        try envContent.write(to: envPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Docker

    func generateSymfonyDockerFiles(config: ProjectConfiguration, projectPath: URL) async throws {
        let dockerBuilder = DockerTemplateBuilder(config: config)

        // Generate Dockerfile
        let dockerfile = dockerBuilder.generateDockerfile()
        let dockerfilePath = projectPath.appendingPathComponent("Dockerfile")
        try dockerfile.write(to: dockerfilePath, atomically: true, encoding: .utf8)

        // Copy entrypoint script for container startup automations (migrations, cache warmup)
        let entrypointDir = projectPath.appendingPathComponent("docker/entrypoint.d")
        try FileManager.default.createDirectory(at: entrypointDir, withIntermediateDirectories: true)

        guard let scriptURL = Bundle.main.url(forResource: "99-symfony-automations", withExtension: "sh") else {
            throw ProjectGeneratorError.commandFailed(
                command: "copy entrypoint script",
                exitCode: 1,
                output: "99-symfony-automations.sh not found in bundle"
            )
        }
        let scriptContent = try String(contentsOf: scriptURL, encoding: .utf8)
        let targetScriptPath = entrypointDir.appendingPathComponent("99-symfony-automations.sh")
        try scriptContent.write(to: targetScriptPath, atomically: true, encoding: .utf8)

        // Generate compose.prod.yaml
        let composeBuilder = ComposeYAMLBuilder(config: config)
        let composeYAML = try await composeBuilder.generate()
        let composePath = projectPath.appendingPathComponent("compose.prod.yaml")
        try composeYAML.write(to: composePath, atomically: true, encoding: .utf8)

        // Generate compose.prod.certresolver.yaml for direct exposure (non-tunnel) mode
        let certresolverYAML = try await composeBuilder.generateCertresolver()
        let certresolverPath = projectPath.appendingPathComponent("compose.prod.certresolver.yaml")
        try certresolverYAML.write(to: certresolverPath, atomically: true, encoding: .utf8)

        // Generate GitHub Actions deploy workflow
        let workflowDir = projectPath.appendingPathComponent(".github/workflows")
        try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
        let deployWorkflow = dockerBuilder.generateDeployWorkflow()
        let workflowPath = workflowDir.appendingPathComponent("deploy.yml")
        try deployWorkflow.write(to: workflowPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Production Environment

    func createSymfonyProductionEnvTemplate(projectPath: URL, config: ProjectConfiguration) async throws {
        guard let projectName = config.projectName.sanitizedHostname() else { return }
        let envDistPath = projectPath.appendingPathComponent(".env.production.dist")

        var template = """
            APP_ENV=prod
            APP_SECRET=
            APP_HOST=
            APP_SHARE_DIR=var/share
            DEFAULT_URI="https://${APP_HOST}"

            """

        // Database configuration (variables defined first, then DATABASE_URL references them)
        switch config.databaseType {
        case .sqlite:
            template += """
                DB_CONNECTION=sqlite
                DATABASE_URL="sqlite:///%kernel.project_dir%/var/data/database.sqlite"

                """
        case .mysql:
            let version = config.mysqlVersion ?? "9.0"
            template += """
                DB_CONNECTION=mysql
                DB_DATABASE=\(projectName)
                DB_USERNAME=\(projectName)
                DB_PASSWORD=
                DATABASE_URL="mysql://${DB_USERNAME}:${DB_PASSWORD}@mysql:3306/${DB_DATABASE}?serverVersion=\(version)"

                """
        case .mariadb:
            let version = config.mariadbVersion ?? "11"
            template += """
                DB_CONNECTION=mariadb
                DB_DATABASE=\(projectName)
                DB_USERNAME=\(projectName)
                DB_PASSWORD=
                DATABASE_URL="mysql://${DB_USERNAME}:${DB_PASSWORD}@mariadb:3306/${DB_DATABASE}?serverVersion=mariadb-\(version)"

                """
        case .postgresql:
            let version = config.postgresVersion ?? "18"
            template += """
                DB_CONNECTION=pgsql
                DB_DATABASE=\(projectName)
                DB_USERNAME=\(projectName)
                DB_PASSWORD=
                DATABASE_URL="postgresql://${DB_USERNAME}:${DB_PASSWORD}@pgsql:5432/${DB_DATABASE}?serverVersion=\(version)"

                """
        }

        // Mailer (disabled by default in production)
        template += """
            MAILER_DSN=null://null
            """

        try template.write(to: envDistPath, atomically: true, encoding: .utf8)
    }
}
