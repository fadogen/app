import Foundation
import SwiftData

/// Local email testing server
@Model
final class MailpitConfig {

    var smtpPort: Int = 1025
    var uiPort: Int = 8025
    var autoStart: Bool = true
    var uniqueIdentifier: String = ""

    init(smtpPort: Int = 1025, uiPort: Int = 8025, autoStart: Bool = true) {
        self.smtpPort = smtpPort
        self.uiPort = uiPort
        self.autoStart = autoStart
        self.uniqueIdentifier = "mailpit"
    }
}
