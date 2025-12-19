import SwiftUI

/// Reusable status badge for labels like "Default", "Running", etc.
struct StatusBadge: View {
    let text: String
    let color: Color

    init(text: String, color: Color = .blue) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
