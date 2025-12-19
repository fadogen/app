import Foundation

/// Configurable PHP runtime settings from php.ini
struct PHPConfig {
    var uploadMaxFilesize: Int  // MB
    var memoryLimit: Int  // MB

    static let `default` = PHPConfig(
        uploadMaxFilesize: 64,
        memoryLimit: 256
    )
}
