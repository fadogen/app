import SwiftUI
import SwiftData

/// Main Reverb view that switches between installed/not installed states
struct ReverbView: View {
    @Query private var installedReverb: [ReverbVersion]
    @Environment(AppServices.self) private var appServices

    /// Check if Reverb is installed
    private var isInstalled: Bool {
        !installedReverb.isEmpty
    }

    var body: some View {
        Group {
            if isInstalled {
                ReverbDetailView()
            } else {
                ReverbNotInstalledView()
            }
        }
        .toolbar {
            // Shared refresh button for metadata
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await appServices.reverb.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .symbolEffect(.rotate, value: appServices.reverb.isLoading)
                .disabled(appServices.reverb.isLoading)
                .help("Refresh Reverb metadata")
            }
        }
        .task {
            // Refresh metadata if not loaded (e.g., app launched offline)
            if appServices.reverb.availableMetadata == nil {
                await appServices.reverb.refresh()
            }
        }
    }
}