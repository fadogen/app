import Foundation

struct DockerTemplateBuilder {
    let config: ProjectConfiguration

    init(config: ProjectConfiguration) {
        self.config = config
    }

    private func loadTemplate(from url: URL) -> String {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Template not found: \(url.path)")
        }
        return content
    }

    // MARK: - Dockerfile Generation

    func generateDockerfile() -> String {
        switch config.framework {
        case .laravel:
            return generateLaravelDockerfile()
        case .symfony:
            return generateSymfonyDockerfile()
        }
    }

    private func generateLaravelDockerfile() -> String {
        let templateURL = FadogenPaths.dockerTemplatesDirectory
            .appendingPathComponent("laravel-dockerfile.template")
        let template = loadTemplate(from: templateURL)
        let isBun = config.jsPackageManager == .bun
        let hasSSR = config.ssr

        var variables: [String: String] = [
            "PHP_VERSION": config.phpVersion,
            "PACKAGE_FILES": isBun ? "package.json bun.lock*" : "package*.json",
            "INSTALL_COMMAND": isBun ? "bun install --frozen-lockfile" : "npm ci",
            "BUILD_COMMAND": isBun
                ? (hasSSR ? "bun run build:ssr" : "bun run build")
                : (hasSSR ? "npm run build:ssr" : "npm run build")
        ]

        // Add only the relevant runtime version (YAGNI)
        if isBun {
            let bunVersion = config.bunVersion ?? "1.3"
            variables["BUN_VERSION"] = bunVersion
            if hasSSR {
                variables["SSR_IMAGE"] = "oven/bun:\(bunVersion)-debian"
                variables["SSR_CMD"] = #"["bun", "bootstrap/ssr/ssr.js"]"#
            }
        } else {
            let nodeVersion = config.nodeVersion ?? "24"
            variables["NODE_VERSION"] = nodeVersion
            if hasSSR {
                variables["SSR_CMD"] = #"["node", "bootstrap/ssr/ssr.js"]"#
            }
        }

        let conditions: [String: Bool] = [
            "IS_BUN": isBun,
            "IS_NPM": !isBun,
            "HAS_SSR": hasSSR,
            "HAS_SQLITE": config.databaseType == .sqlite
        ]

        return SimpleTemplateEngine.render(template, variables: variables, conditions: conditions)
    }

    private func generateSymfonyDockerfile() -> String {
        let templateURL = FadogenPaths.dockerTemplatesDirectory
            .appendingPathComponent("symfony-dockerfile.template")
        let template = loadTemplate(from: templateURL)

        let variables: [String: String] = [
            "PHP_VERSION": config.phpVersion
        ]

        let conditions: [String: Bool] = [
            "HAS_SQLITE": config.databaseType == .sqlite,
            "HAS_ASSET_MAPPER": config.symfonyProjectType == .webapp
        ]

        return SimpleTemplateEngine.render(template, variables: variables, conditions: conditions)
    }

    // MARK: - GitHub Actions Workflow Generation

    func generateDeployWorkflow() -> String {
        switch config.framework {
        case .laravel:
            return generateLaravelDeployWorkflow()
        case .symfony:
            return generateSymfonyDeployWorkflow()
        }
    }

    private func generateLaravelDeployWorkflow() -> String {
        let templateURL = FadogenPaths.dockerTemplatesDirectory
            .appendingPathComponent("laravel-deploy.yaml.template")
        let template = loadTemplate(from: templateURL)

        let conditions: [String: Bool] = [
            "HAS_SSR": config.ssr
        ]

        return SimpleTemplateEngine.render(template, variables: [:], conditions: conditions)
    }

    private func generateSymfonyDeployWorkflow() -> String {
        let templateURL = FadogenPaths.dockerTemplatesDirectory
            .appendingPathComponent("symfony-deploy.yaml.template")
        let template = loadTemplate(from: templateURL)
        return SimpleTemplateEngine.render(template, variables: [:], conditions: [:])
    }
}
