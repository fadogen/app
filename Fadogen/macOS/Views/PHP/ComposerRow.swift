import SwiftUI
import SwiftData

/// Row displaying Composer version information and update actions
/// Designed to be visually distinct from PHP version rows
struct ComposerRow: View {
    @Environment(AppServices.self) private var services
    @Query private var installedVersion: [ComposerVersion]

    @State private var errorAlert: String?

    var body: some View {
        HStack(spacing: 16) {
            // Composer label with version
            HStack(spacing: 8) {
                Text("Composer")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                if let installed = installedVersion.first {
                    Text(installed.version)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Action buttons
            HStack(alignment: .center, spacing: 8) {
                // Update button
                if services.composer.isUpdateAvailable() {
                    if services.composer.isUpdating {
                        OperationProgressView(progress: services.composer.updateProgress, tint: .orange)
                    } else {
                        Button(action: performUpdate) {
                            Image(systemName: "arrow.down.circle")
                                .font(.title2)
                                .foregroundColor(.orange)
                                .frame(height: 24)
                        }
                        .buttonStyle(.borderless)
                        .disabled(services.composer.isUpdating || services.php.isAnyOperationActive)
                        .opacity((services.composer.isUpdating || services.php.isAnyOperationActive) ? 0.3 : 1.0)
                        .help("Update Composer to \(services.composer.availableVersion?.latest ?? "latest version")")
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .alert("Update Error", isPresented: .constant(errorAlert != nil)) {
            Button("OK") {
                errorAlert = nil
            }
        } message: {
            if let error = errorAlert {
                Text(error)
            }
        }
    }

    private func performUpdate() {
        Task {
            do {
                try await services.composer.update()
            } catch {
                await MainActor.run {
                    errorAlert = error.localizedDescription
                }
            }
        }
    }
}
