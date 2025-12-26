import Foundation
import SwiftData

/// Singleton for user-wide settings
@Model
final class UserPreferences {

    var id: UUID = UUID()

    /// For Let's Encrypt certificate
    @Attribute(.allowsCloudEncryption)
    var acmeEmail: String? = nil

    /// Preferred IDE for "Open in IDE" feature
    var preferredIDERawValue: String? = nil

    var preferredIDE: IDE? {
        get { preferredIDERawValue.flatMap { IDE(rawValue: $0) } }
        set { preferredIDERawValue = newValue?.rawValue }
    }

    init(acmeEmail: String? = nil, preferredIDE: IDE? = nil) {
        self.id = UUID()
        self.acmeEmail = acmeEmail
        self.preferredIDERawValue = preferredIDE?.rawValue
    }
}
