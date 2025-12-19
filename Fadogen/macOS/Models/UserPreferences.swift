import Foundation
import SwiftData

/// Singleton for user-wide settings
@Model
final class UserPreferences {

    var id: UUID = UUID()

    /// For Let's Encrypt certificate
    @Attribute(.allowsCloudEncryption)
    var acmeEmail: String? = nil

    init(acmeEmail: String? = nil) {
        self.id = UUID()
        self.acmeEmail = acmeEmail
    }
}
