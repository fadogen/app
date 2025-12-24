import SwiftUI

/// View displayed when Typesense is not installed
struct TypesenseNotInstalledView: View {
    @Environment(AppServices.self) private var services

    @State private var showingInstallSheet = false

    /// Check if metadata is available
    private var hasMetadata: Bool {
        services.typesense.availableMetadata != nil
    }

    /// Check if there's an error loading metadata
    private var hasMetadataError: Bool {
        services.typesense.errorMessage != nil && !hasMetadata
    }

    var body: some View {
        VStack(spacing: 32) {
            // Icon
            Image(systemName: "magnifyingglass")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)

            // Title and description
            VStack(spacing: 16) {
                Text("Typesense")
                    .font(.title)
                    .fontWeight(.bold)

                VStack(spacing: 12) {
                    Text("Typesense is a fast, typo-tolerant search engine")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("With Fadogen, install Typesense once for all your local projects")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("Perfect for Laravel Scout integration")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("Simply configure your environment variables per project to connect to")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("https://typesense.localhost")
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
                        Task { await services.typesense.refresh() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(services.typesense.isLoading)
                }
                .padding(12)
                .background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Install button
            Button {
                showingInstallSheet = true
            } label: {
                Text("Install Typesense")
                    .frame(width: 160)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasMetadata || services.typesense.isLoading)

            // Documentation link
            Link("Learn more about Typesense", destination: URL(string: "https://typesense.org/docs/")!)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Typesense")
        .sheet(isPresented: $showingInstallSheet) {
            TypesenseSheet()
        }
    }
}
