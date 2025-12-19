import SwiftUI

/// Help sheet explaining PHP version management
struct PHPHelpSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            // Content
            VStack(alignment: .leading, spacing: 20) {
                Text("PHP Version Management")
                    .font(.headline)

                Text("The default version (✓) is used for Terminal, Composer, and new sites.")
                    .font(.body)

                Text("You can override it per project in Projects.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 400, height: 200)
    }
}