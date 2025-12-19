import SwiftUI

/// Shared view constants to maintain consistency across the app
enum ViewConstants {
    /// Standard grid layout for provider cards (3 columns)
    static let providerGridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
}
