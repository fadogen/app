import SwiftUI

/// View displayed when Reverb is not installed
struct ReverbNotInstalledView: View {
    @Environment(AppServices.self) private var services

    @State private var showingInstallSheet = false

    /// Check if metadata is available
    private var hasMetadata: Bool {
        services.reverb.availableMetadata != nil
    }

    /// Check if there's an error loading metadata
    private var hasMetadataError: Bool {
        services.reverb.errorMessage != nil && !hasMetadata
    }

    var body: some View {
        VStack(spacing: 32) {
            // Icon
            Image(systemName: "waveform")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)

            // Title and description
            VStack(spacing: 16) {
                Text("Laravel Reverb")
                    .font(.title)
                    .fontWeight(.bold)

                VStack(spacing: 12) {
                    Text("Reverb is an ultra-fast WebSocket server for Laravel")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("With Fadogen, install Reverb once for all your local projects")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("No need to run `php artisan reverb:start` in each project")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("Simply configure your environment variables per project to connect to")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("https://reverb.localhost")
                        .font(.body.monospaced())
                        .foregroundStyle(.blue)
                }
            }
            .frame(maxWidth: 500)

            // Error banner if metadata failed to load
            if hasMetadataError {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Unable to load version information")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await services.reverb.refresh() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(services.reverb.isLoading)
                }
                .padding(12)
                .background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Install button
            Button {
                showingInstallSheet = true
            } label: {
                Text("Install Reverb")
                    .frame(width: 160)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasMetadata || services.reverb.isLoading)

            // Documentation link
            Link("Learn more about Laravel Reverb", destination: URL(string: "https://laravel.com/docs/12.x/reverb")!)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Reverb")
        .sheet(isPresented: $showingInstallSheet) {
            ReverbSheet()
        }
    }
}
