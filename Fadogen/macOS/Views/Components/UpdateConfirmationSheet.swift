import SwiftUI

/// Confirmation sheet for service updates
/// Used by ServiceDetailView and ReverbDetailView
struct UpdateConfirmationSheet: View {
    let serviceName: String
    let currentVersion: String
    let latestVersion: String
    let isUpdating: Bool
    let onUpdate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            // Title
            Text("Update \(serviceName)?")
                .font(.headline)

            // Version info
            Text("Update from \(currentVersion) to \(latestVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .disabled(isUpdating)

                Button {
                    onUpdate()
                } label: {
                    if isUpdating {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Updating...")
                        }
                    } else {
                        Text("Update")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isUpdating)
            }
        }
        .padding(24)
        .frame(minWidth: 300)
    }
}
