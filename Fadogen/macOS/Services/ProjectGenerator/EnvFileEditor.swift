import Foundation

enum EnvFileEditor {

    // MARK: - Private

    private enum ValuePattern: String {
        case any = #".*"#        // Any value (including empty)
        case word = #"\w+"#      // Word characters only
        case digits = #"\d+"#    // Digits only
    }

    private static func setValue(
        in content: String,
        key: String,
        value: String,
        pattern: ValuePattern = .any
    ) -> String {
        content.replacingOccurrences(
            of: "\(key)=\(pattern.rawValue)",
            with: "\(key)=\(value)",
            options: .regularExpression
        )
    }

    private static func uncomment(
        in content: String,
        key: String,
        value: String
    ) -> String {
        content.replacingOccurrences(
            of: "# \(key)=\(ValuePattern.any.rawValue)",
            with: "\(key)=\(value)",
            options: .regularExpression
        )
    }

    // MARK: - Public

    static func configureAppURL(in content: String, projectName: String) -> String {
        setValue(in: content, key: "APP_URL", value: "https://\(projectName).localhost")
    }

    static func configureDatabaseConnection(
        in content: String,
        databaseType: DatabaseType,
        port: Int,
        databaseName: String
    ) -> String {
        var result = content

        // Replace DB_CONNECTION (exact match for sqlite default)
        result = result.replacingOccurrences(
            of: "DB_CONNECTION=sqlite",
            with: "DB_CONNECTION=\(databaseType.envConnectionName)"
        )

        // Uncomment database settings
        result = uncomment(in: result, key: "DB_HOST", value: "127.0.0.1")
        result = uncomment(in: result, key: "DB_PORT", value: "\(port)")
        result = uncomment(in: result, key: "DB_DATABASE", value: databaseName)
        result = uncomment(in: result, key: "DB_USERNAME", value: "root")
        result = uncomment(in: result, key: "DB_PASSWORD", value: "")

        return result
    }

    static func configureCacheService(
        in content: String,
        port: Int
    ) -> String {
        var result = content

        result = setValue(in: result, key: "REDIS_PORT", value: "\(port)", pattern: .digits)
        result = setValue(in: result, key: "CACHE_STORE", value: "redis", pattern: .word)
        result = setValue(in: result, key: "QUEUE_CONNECTION", value: "redis", pattern: .word)
        result = setValue(in: result, key: "SESSION_DRIVER", value: "redis", pattern: .word)

        return result
    }

    static func configureMailpit(in content: String, smtpPort: Int = 1025) -> String {
        var result = content

        result = setValue(in: result, key: "MAIL_MAILER", value: "smtp", pattern: .word)
        result = setValue(in: result, key: "MAIL_HOST", value: "127.0.0.1")
        result = setValue(in: result, key: "MAIL_PORT", value: "\(smtpPort)", pattern: .digits)
        result = setValue(in: result, key: "MAIL_USERNAME", value: "null")
        result = setValue(in: result, key: "MAIL_PASSWORD", value: "null")
        result = setValue(in: result, key: "MAIL_ENCRYPTION", value: "null")
        result = setValue(in: result, key: "MAIL_SCHEME", value: "null")  // Newer Laravel versions

        return result
    }

    static func configureReverb(in content: String) -> String {
        var result = content

        // Fadogen runs a single Reverb server at reverb.localhost (proxied via Caddy with HTTPS)
        result = setValue(in: result, key: "REVERB_APP_ID", value: "1001")
        result = setValue(in: result, key: "REVERB_APP_KEY", value: "laravel-fadogen")
        result = setValue(in: result, key: "REVERB_APP_SECRET", value: "secret")
        result = setValue(in: result, key: "REVERB_HOST", value: #""reverb.localhost""#)
        result = setValue(in: result, key: "REVERB_PORT", value: "443")
        result = setValue(in: result, key: "REVERB_SCHEME", value: "https")

        // VITE_REVERB variables reference the REVERB variables
        result = setValue(in: result, key: "VITE_REVERB_HOST", value: #""${REVERB_HOST}""#)
        result = setValue(in: result, key: "VITE_REVERB_PORT", value: #""${REVERB_PORT}""#)
        result = setValue(in: result, key: "VITE_REVERB_SCHEME", value: #""${REVERB_SCHEME}""#)

        return result
    }

    /// Configure Scout with Typesense for development
    /// - Parameters:
    ///   - content: The .env file content
    ///   - projectName: The sanitized project name for SCOUT_PREFIX
    ///   - hasQueueWorker: Whether a queue worker is configured (Horizon or native)
    /// - Returns: Modified .env content with Scout/Typesense configuration
    static func configureScout(in content: String, projectName: String, hasQueueWorker: Bool) -> String {
        // Convert hyphens to underscores for SCOUT_PREFIX (SQL-safe identifier)
        let prefix = projectName.replacingOccurrences(of: "-", with: "_")
        let scoutQueue = hasQueueWorker ? "true" : "false"

        // Scout variables don't exist in Laravel's default .env, so we append them
        let scoutBlock = """

            SCOUT_DRIVER=typesense
            SCOUT_QUEUE=\(scoutQueue)
            SCOUT_PREFIX=\(prefix)_

            TYPESENSE_API_KEY=fadogen-typesense-key
            TYPESENSE_HOST="typesense.localhost"
            TYPESENSE_PORT=443
            TYPESENSE_PROTOCOL=https
            """

        // Ensure content ends with newline before appending
        var result = content
        if !result.hasSuffix("\n") {
            result += "\n"
        }
        result += scoutBlock

        return result
    }
}
