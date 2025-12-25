import SwiftUI

/// View displayed when Garage is not installed
struct GarageNotInstalledView: View {
    @Environment(AppServices.self) private var services

    @State private var showingInstallSheet = false

    /// Check if metadata is available
    private var hasMetadata: Bool {
        services.garage.availableMetadata != nil
    }

    /// Check if there's an error loading metadata
    private var hasMetadataError: Bool {
        services.garage.errorMessage != nil && !hasMetadata
    }

    var body: some View {
        VStack(spacing: 32) {
            // Icon
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)

            // Title and description
            VStack(spacing: 16) {
                Text("Garage S3 Storage")
                    .font(.title)
                    .fontWeight(.bold)

                VStack(spacing: 12) {
                    Text("Garage is an S3-compatible distributed storage system")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("With Fadogen, install Garage once for all your local projects")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("Perfect for Laravel Flysystem and media storage")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("Simply configure your environment variables per project to connect to")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("https://s3.localhost")
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
                        Task { await services.garage.refresh() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(services.garage.isLoading)
                }
                .padding(12)
                .background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Install button
            Button {
                showingInstallSheet = true
            } label: {
                Text("Install Garage")
                    .frame(width: 160)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasMetadata || services.garage.isLoading)

            // Documentation link
            Link("Learn more about Garage", destination: URL(string: "https://garagehq.deuxfleurs.fr/documentation/")!)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Garage")
        .sheet(isPresented: $showingInstallSheet) {
            GarageSheet()
        }
    }
}
