import Foundation

nonisolated struct IntegrationCredentials: Codable, Sendable {
    // Cloudflare : email + globalAPIKey OU apiToken
    var email: String?
    var globalAPIKey: String?

    // Autres providers : token ou apiKey
    var token: String?
    var apiKey: String?

    // Future : OAuth, AWS keys, etc.
    var accessKey: String?
    var secretKey: String?
    var oauthAccessToken: String?
    var oauthRefreshToken: String?

    // Cloudflare R2 (S3-compatible storage)
    var r2AccessKeyId: String?
    var r2SecretAccessKey: String?

    // Scaleway Object Storage
    var scalewayRegion: String?  // fr-par, nl-ams, pl-waw

    // Dropbox OAuth2
    var dropboxAppKey: String?
    var dropboxAppSecret: String?
    var dropboxRefreshToken: String?

    init(
        email: String? = nil,
        globalAPIKey: String? = nil,
        token: String? = nil,
        apiKey: String? = nil,
        accessKey: String? = nil,
        secretKey: String? = nil,
        r2AccessKeyId: String? = nil,
        r2SecretAccessKey: String? = nil,
        scalewayRegion: String? = nil,
        dropboxAppKey: String? = nil,
        dropboxAppSecret: String? = nil,
        dropboxRefreshToken: String? = nil
    ) {
        self.email = email
        self.globalAPIKey = globalAPIKey
        self.token = token
        self.apiKey = apiKey
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.r2AccessKeyId = r2AccessKeyId
        self.r2SecretAccessKey = r2SecretAccessKey
        self.scalewayRegion = scalewayRegion
        self.dropboxAppKey = dropboxAppKey
        self.dropboxAppSecret = dropboxAppSecret
        self.dropboxRefreshToken = dropboxRefreshToken
    }

    /// Retourne le token principal selon le type d'intégration
    func primaryToken(for type: IntegrationType) -> String? {
        switch type.metadata.authMethod {
        case .emailAndGlobalKey:
            return globalAPIKey
        case .bearerToken:
            return token
        case .apiKey:
            return apiKey
        case .accessKeyAndSecret:
            return accessKey
        case .oauth2:
            return dropboxRefreshToken
        }
    }

    /// Valide que les credentials sont complets pour un type donné
    func isValid(for type: IntegrationType) -> Bool {
        switch type.metadata.authMethod {
        case .emailAndGlobalKey:
            return email?.isEmpty == false && globalAPIKey?.isEmpty == false
        case .bearerToken:
            return token?.isEmpty == false
        case .apiKey:
            return apiKey?.isEmpty == false
        case .accessKeyAndSecret:
            return accessKey?.isEmpty == false && secretKey?.isEmpty == false
        case .oauth2:
            // Dropbox uses app key + app secret + refresh token
            return dropboxAppKey?.isEmpty == false
                && dropboxAppSecret?.isEmpty == false
                && dropboxRefreshToken?.isEmpty == false
        }
    }
}
