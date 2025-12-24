import SwiftUI
import SwiftData

/// Main Typesense view that switches between installed/not installed states
struct TypesenseView: View {
    @Query private var installedTypesense: [TypesenseVersion]
    @Environment(AppServices.self) private var appServices

    /// Check if Typesense is installed
    private var isInstalled: Bool {
        !installedTypesense.isEmpty
    }

    var body: some View {
        Group {
            if isInstalled {
                TypesenseDetailView()
            } else {
                TypesenseNotInstalledView()
            }
        }
        .toolbar {
            // Shared refresh button for metadata
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await appServices.typesense.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .symbolEffect(.rotate, value: appServices.typesense.isLoading)
                .disabled(appServices.typesense.isLoading)
                .help("Refresh Typesense metadata")
            }
        }
        .task {
            // Refresh metadata if not loaded (e.g., app launched offline)
            if appServices.typesense.availableMetadata == nil {
                await appServices.typesense.refresh()
            }
        }
    }
}
