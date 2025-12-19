import Foundation

/// APP_KEY is generated via `php artisan key:generate` during deployment
enum SecretGenerator {

    private static let lowercaseLetters = "abcdefghijklmnopqrstuvwxyz"
    private static let uppercaseLetters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let digits = "0123456789"
    private static let alphanumeric = lowercaseLetters + uppercaseLetters + digits

    // MARK: - Password

    /// At least one uppercase, lowercase, and digit
    static func generatePassword(length: Int = 32) -> String {
        guard length >= 3 else { return "" }

        var password = (0..<length).compactMap { _ in alphanumeric.randomElement() }

        // Ensure at least one of each required category
        password[0] = uppercaseLetters.randomElement()!
        password[1] = lowercaseLetters.randomElement()!
        password[2] = digits.randomElement()!

        // Shuffle to avoid predictable positions
        password.shuffle()

        return String(password)
    }

    // MARK: - Reverb

    static func generateReverbAppID() -> String {
        String(Int.random(in: 100_000...999_999))
    }

    static func generateReverbAppKey() -> String {
        let chars = lowercaseLetters + digits
        return String((0..<20).compactMap { _ in chars.randomElement() })
    }

    static func generateReverbAppSecret() -> String {
        let chars = lowercaseLetters + digits
        return String((0..<32).compactMap { _ in chars.randomElement() })
    }

    // MARK: - Database

    /// Max 63 chars for PostgreSQL
    static func generateDatabaseName(from projectName: String) -> String {
        let sanitized = projectName
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }

        // Ensure it starts with a letter (database naming requirement)
        let result = sanitized.first?.isLetter == true ? sanitized : "db_\(sanitized)"

        return String(result.prefix(63))
    }

    /// Max 16 chars for MySQL compatibility
    static func generateDatabaseUsername(from projectName: String) -> String {
        let sanitized = projectName
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }

        // Ensure it starts with a letter (username naming requirement)
        let result = sanitized.first?.isLetter == true ? sanitized : "u_\(sanitized)"

        return String(result.prefix(16))
    }
}
