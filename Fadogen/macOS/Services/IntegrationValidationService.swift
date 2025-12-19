import Foundation
import os

private let logger = Logger(subsystem: "app.fadogen", category: "IntegrationValidation")

enum IntegrationValidationService {

    static func validate(
        type: IntegrationType,
        email: String = "",
        globalAPIKey: String = "",
        token: String = "",
        apiKey: String = "",
        accessKey: String = "",
        secretKey: String = "",
        scalewayRegion: ScalewayRegion = .paris,
        dropboxAppKey: String = "",
        dropboxAppSecret: String = "",
        dropboxAuthCode: String = "",
        dropboxRefreshToken: String = "",
        isEditMode: Bool = false
    ) async throws -> IntegrationCredentials {

        switch type {
        case .cloudflare:
            return try await validateCloudflare(email: email, globalAPIKey: globalAPIKey, skipR2TokenGeneration: isEditMode)

        case .github:
            return try await validateGitHub(token: token)

        case .hetznerDNS:
            return try await validateHetznerDNS(token: token)

        case .linode:
            return try await validateLinode(token: token)

        case .vultr:
            return try await validateVultr(token: token)

        case .bunny:
            return try await validateBunny(apiKey: apiKey)

        case .scaleway:
            return try await validateScaleway(
                accessKey: accessKey,
                secretKey: secretKey,
                region: scalewayRegion
            )

        case .dropbox:
            return try await validateDropbox(
                appKey: dropboxAppKey,
                appSecret: dropboxAppSecret,
                authCode: dropboxAuthCode,
                existingRefreshToken: dropboxRefreshToken.isEmpty ? nil : dropboxRefreshToken
            )

        case .digitalocean, .hetzner:
            // Generic VPS providers
            return try await validateGenericVPS(type: type, token: token)
        }
    }

    // MARK: - Private

    private static func validateCloudflare(
        email: String,
        globalAPIKey: String,
        skipR2TokenGeneration: Bool
    ) async throws -> IntegrationCredentials {
        let cloudflareService = CloudflareService()
        let tempIntegration = Integration.cloudflare(email: email, globalAPIKey: globalAPIKey)

        // Validate by fetching zones
        _ = try await cloudflareService.listZones(integration: tempIntegration)

        // For edit mode, skip R2 token generation (preserve existing tokens)
        if skipR2TokenGeneration {
            return IntegrationCredentials(
                email: email,
                globalAPIKey: globalAPIKey
            )
        }

        // Get account ID and create R2 token for backup capability
        let accountId = try await cloudflareService.getAccountID(integration: tempIntegration)
        let r2Credentials = try await cloudflareService.createR2Token(
            accountId: accountId,
            email: email,
            apiKey: globalAPIKey
        )

        return IntegrationCredentials(
            email: email,
            globalAPIKey: globalAPIKey,
            r2AccessKeyId: r2Credentials.accessKeyId,
            r2SecretAccessKey: r2Credentials.secretAccessKey
        )
    }

    private static func validateGitHub(token: String) async throws -> IntegrationCredentials {
        let githubService = GitHubService()
        _ = try await githubService.validateToken(token: token)
        return IntegrationCredentials(token: token)
    }

    private static func validateHetznerDNS(token: String) async throws -> IntegrationCredentials {
        let hetznerDNSService = HetznerDNSService()
        _ = try await hetznerDNSService.listZones(apiToken: token)
        return IntegrationCredentials(token: token)
    }

    private static func validateLinode(token: String) async throws -> IntegrationCredentials {
        let linodeService = LinodeService()
        try await linodeService.validateToken(apiToken: token)
        return IntegrationCredentials(token: token)
    }

    private static func validateVultr(token: String) async throws -> IntegrationCredentials {
        let vultrService = VultrService()
        try await vultrService.validateToken(apiToken: token)
        return IntegrationCredentials(token: token)
    }

    private static func validateBunny(apiKey: String) async throws -> IntegrationCredentials {
        logger.info("Validating Bunny integration...")
        logger.debug("API Key: \(apiKey.prefix(4))... (length: \(apiKey.count))")

        let bunnyDNSService = BunnyDNSService()
        let zones = try await bunnyDNSService.listZones(apiKey: apiKey)
        logger.info("Bunny validation successful: \(zones.count) zones found")

        return IntegrationCredentials(apiKey: apiKey)
    }

    private static func validateScaleway(
        accessKey: String,
        secretKey: String,
        region: ScalewayRegion
    ) async throws -> IntegrationCredentials {
        let scalewayService = ScalewayService()
        try await scalewayService.validateCredentials(
            accessKey: accessKey,
            secretKey: secretKey,
            region: region
        )

        return IntegrationCredentials(
            accessKey: accessKey,
            secretKey: secretKey,
            scalewayRegion: region.rawValue
        )
    }

    private static func validateDropbox(
        appKey: String,
        appSecret: String,
        authCode: String,
        existingRefreshToken: String? = nil
    ) async throws -> IntegrationCredentials {
        let dropboxService = DropboxService()
        let refreshToken: String

        // Si authCode fourni → nouveau flux OAuth complet
        // Si authCode vide + refreshToken existant → valider avec le token existant
        if !authCode.isEmpty {
            // Nouveau setup ou ré-autorisation
            refreshToken = try await dropboxService.exchangeCodeForRefreshToken(
                code: authCode,
                appKey: appKey,
                appSecret: appSecret
            )
        } else if let existing = existingRefreshToken, !existing.isEmpty {
            // Mode édition: utiliser le token existant
            refreshToken = existing
        } else {
            throw DropboxError.invalidCredentials
        }

        // Valider que les credentials fonctionnent
        try await dropboxService.validateCredentials(
            appKey: appKey,
            appSecret: appSecret,
            refreshToken: refreshToken
        )

        return IntegrationCredentials(
            dropboxAppKey: appKey,
            dropboxAppSecret: appSecret,
            dropboxRefreshToken: refreshToken
        )
    }

    private static func validateGenericVPS(type: IntegrationType, token: String) async throws -> IntegrationCredentials {
        let providerCredentials = ProviderCredentials.bearerToken(token)
        let service = try CloudProviderFactory.createService(for: type)
        _ = try await service.listRegions(credentials: providerCredentials)
        return IntegrationCredentials(token: token)
    }
}
