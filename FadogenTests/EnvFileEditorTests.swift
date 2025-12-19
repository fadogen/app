import Testing
@testable import Fadogen

@MainActor
struct EnvFileEditorTests {
    // MARK: - Test Fixtures

    /// Sample Laravel 12 .env content with SQLite as default
    let sampleEnvContent = """
        APP_NAME=Laravel
        APP_ENV=local
        APP_KEY=
        APP_DEBUG=true
        APP_URL=http://localhost

        LOG_CHANNEL=stack
        LOG_DEPRECATIONS_CHANNEL=null
        LOG_LEVEL=debug

        DB_CONNECTION=sqlite
        # DB_HOST=127.0.0.1
        # DB_PORT=3306
        # DB_DATABASE=laravel
        # DB_USERNAME=root
        # DB_PASSWORD=

        SESSION_DRIVER=database
        SESSION_LIFETIME=120
        SESSION_ENCRYPT=false
        SESSION_PATH=/
        SESSION_DOMAIN=null

        BROADCAST_CONNECTION=log
        FILESYSTEM_DISK=local
        QUEUE_CONNECTION=database

        CACHE_STORE=database
        CACHE_PREFIX=

        REDIS_HOST=127.0.0.1
        REDIS_PASSWORD=null
        REDIS_PORT=6379
        """

    // MARK: - APP_URL Configuration Tests

    @Test func configuresAppURLForLocalDevelopment() {
        let result = EnvFileEditor.configureAppURL(in: sampleEnvContent, projectName: "my-project")

        #expect(result.contains("APP_URL=https://my-project.localhost"))
        #expect(!result.contains("APP_URL=http://localhost"))
    }

    @Test func configuresAppURLWithSanitizedName() {
        let result = EnvFileEditor.configureAppURL(in: sampleEnvContent, projectName: "test-app")

        #expect(result.contains("APP_URL=https://test-app.localhost"))
    }

    // MARK: - Database Configuration Tests

    @Test func configuresPostgreSQLConnection() {
        let result = EnvFileEditor.configureDatabaseConnection(
            in: sampleEnvContent,
            databaseType: .postgresql,
            port: 5432,
            databaseName: "my-app"
        )

        #expect(result.contains("DB_CONNECTION=pgsql"))
        #expect(result.contains("DB_HOST=127.0.0.1"))
        #expect(result.contains("DB_PORT=5432"))
        #expect(result.contains("DB_DATABASE=my-app"))
        #expect(result.contains("DB_USERNAME=root"))
        #expect(result.contains("DB_PASSWORD="))
        #expect(!result.contains("# DB_HOST"))
        #expect(!result.contains("# DB_PORT"))
        #expect(!result.contains("# DB_DATABASE"))
        #expect(!result.contains("# DB_USERNAME"))
        #expect(!result.contains("# DB_PASSWORD"))
    }

    @Test func configuresMySQLConnection() {
        let result = EnvFileEditor.configureDatabaseConnection(
            in: sampleEnvContent,
            databaseType: .mysql,
            port: 3307,
            databaseName: "test-db"
        )

        #expect(result.contains("DB_CONNECTION=mysql"))
        #expect(result.contains("DB_PORT=3307"))
        #expect(result.contains("DB_DATABASE=test-db"))
    }

    @Test func configuresMariaDBConnection() {
        let result = EnvFileEditor.configureDatabaseConnection(
            in: sampleEnvContent,
            databaseType: .mariadb,
            port: 3308,
            databaseName: "mariadb-app"
        )

        #expect(result.contains("DB_CONNECTION=mariadb"))
        #expect(result.contains("DB_PORT=3308"))
        #expect(result.contains("DB_DATABASE=mariadb-app"))
    }

    @Test func preservesOtherEnvVariables() {
        let result = EnvFileEditor.configureDatabaseConnection(
            in: sampleEnvContent,
            databaseType: .postgresql,
            port: 5432,
            databaseName: "my-app"
        )

        #expect(result.contains("APP_NAME=Laravel"))
        #expect(result.contains("APP_ENV=local"))
        #expect(result.contains("LOG_CHANNEL=stack"))
    }

    // MARK: - Cache Service Configuration Tests

    @Test func configuresCacheServicePort() {
        let result = EnvFileEditor.configureCacheService(
            in: sampleEnvContent,
            port: 6380
        )

        #expect(result.contains("REDIS_PORT=6380"))
    }

    @Test func updatesCacheStore() {
        let result = EnvFileEditor.configureCacheService(
            in: sampleEnvContent,
            port: 6379
        )

        #expect(result.contains("CACHE_STORE=redis"))
        #expect(!result.contains("CACHE_STORE=database"))
    }

    @Test func updatesQueueConnection() {
        let result = EnvFileEditor.configureCacheService(
            in: sampleEnvContent,
            port: 6379
        )

        #expect(result.contains("QUEUE_CONNECTION=redis"))
        #expect(!result.contains("QUEUE_CONNECTION=database"))
    }

    @Test func updatesSessionDriver() {
        let result = EnvFileEditor.configureCacheService(
            in: sampleEnvContent,
            port: 6379
        )

        #expect(result.contains("SESSION_DRIVER=redis"))
        #expect(!result.contains("SESSION_DRIVER=database"))
    }

    @Test func configuresCacheServicePreservesOtherSettings() {
        let result = EnvFileEditor.configureCacheService(
            in: sampleEnvContent,
            port: 6380
        )

        #expect(result.contains("REDIS_HOST=127.0.0.1"))
        #expect(result.contains("REDIS_PASSWORD=null"))
        #expect(result.contains("APP_NAME=Laravel"))
    }

    // MARK: - Combined Configuration Tests

    @Test func configuresDatabaseAndCacheTogether() {
        var content = sampleEnvContent

        // First configure database
        content = EnvFileEditor.configureDatabaseConnection(
            in: content,
            databaseType: .postgresql,
            port: 5433,
            databaseName: "full-app"
        )

        // Then configure cache
        content = EnvFileEditor.configureCacheService(
            in: content,
            port: 6380
        )

        // Verify database settings
        #expect(content.contains("DB_CONNECTION=pgsql"))
        #expect(content.contains("DB_PORT=5433"))
        #expect(content.contains("DB_DATABASE=full-app"))

        // Verify cache settings
        #expect(content.contains("REDIS_PORT=6380"))
        #expect(content.contains("CACHE_STORE=redis"))
        #expect(content.contains("QUEUE_CONNECTION=redis"))
        #expect(content.contains("SESSION_DRIVER=redis"))
    }

    // MARK: - Mailpit Configuration Tests

    @Test func configuresMailpitWithDefaultPort() {
        let envWithMail = """
            MAIL_MAILER=log
            MAIL_HOST=mailpit
            MAIL_PORT=2525
            MAIL_USERNAME=admin
            MAIL_PASSWORD=secret
            MAIL_ENCRYPTION=tls
            MAIL_FROM_ADDRESS="hello@example.com"
            MAIL_FROM_NAME="${APP_NAME}"
            """

        let result = EnvFileEditor.configureMailpit(in: envWithMail)

        #expect(result.contains("MAIL_MAILER=smtp"))
        #expect(result.contains("MAIL_HOST=127.0.0.1"))
        #expect(result.contains("MAIL_PORT=1025"))
        #expect(result.contains("MAIL_USERNAME=null"))
        #expect(result.contains("MAIL_PASSWORD=null"))
        #expect(result.contains("MAIL_ENCRYPTION=null"))
        #expect(!result.contains("MAIL_MAILER=log"))
        #expect(!result.contains("MAIL_PORT=2525"))
    }

    @Test func configuresMailpitWithCustomPort() {
        let envWithMail = """
            MAIL_MAILER=log
            MAIL_PORT=2525
            """

        let result = EnvFileEditor.configureMailpit(in: envWithMail, smtpPort: 1026)

        #expect(result.contains("MAIL_PORT=1026"))
    }

    @Test func configuresMailpitHandlesNewerLaravelMailScheme() {
        let envWithScheme = """
            MAIL_MAILER=smtp
            MAIL_SCHEME=tls
            MAIL_HOST=smtp.example.com
            MAIL_PORT=587
            """

        let result = EnvFileEditor.configureMailpit(in: envWithScheme)

        #expect(result.contains("MAIL_SCHEME=null"))
        #expect(result.contains("MAIL_HOST=127.0.0.1"))
        #expect(result.contains("MAIL_PORT=1025"))
    }

    @Test func configuresMailpitPreservesFromAddress() {
        let envWithMail = """
            MAIL_MAILER=log
            MAIL_FROM_ADDRESS="contact@myapp.com"
            MAIL_FROM_NAME="My App"
            """

        let result = EnvFileEditor.configureMailpit(in: envWithMail)

        // FROM_ADDRESS and FROM_NAME should be preserved (not modified by configureMailpit)
        #expect(result.contains("MAIL_FROM_ADDRESS=\"contact@myapp.com\""))
        #expect(result.contains("MAIL_FROM_NAME=\"My App\""))
    }

    // MARK: - Edge Cases

    @Test func handlesAlreadyUncommentedDatabaseSettings() {
        let envWithUncommentedDB = """
            DB_CONNECTION=mysql
            DB_HOST=127.0.0.1
            DB_PORT=3306
            DB_DATABASE=laravel
            DB_USERNAME=root
            DB_PASSWORD=
            """

        let result = EnvFileEditor.configureDatabaseConnection(
            in: envWithUncommentedDB,
            databaseType: .postgresql,
            port: 5432,
            databaseName: "new-db"
        )

        // Should still work, just won't find commented versions
        #expect(result.contains("DB_HOST=127.0.0.1"))
    }

    @Test func handlesCustomRedisPort() {
        let envWithCustomPort = """
            REDIS_HOST=127.0.0.1
            REDIS_PORT=16379
            """

        let result = EnvFileEditor.configureCacheService(
            in: envWithCustomPort,
            port: 6380
        )

        #expect(result.contains("REDIS_PORT=6380"))
        #expect(!result.contains("REDIS_PORT=16379"))
    }
}
