import SwiftUI
import SwiftData

/// Main Garage view that switches between installed/not installed states
struct GarageView: View {
    @Query private var installedGarage: [GarageVersion]
    @Environment(AppServices.self) private var appServices

    /// Check if Garage is installed
    private var isInstalled: Bool {
        !installedGarage.isEmpty
    }

    var body: some View {
        Group {
            if isInstalled {
                GarageDetailView()
            } else {
                GarageNotInstalledView()
            }
        }
        .toolbar {
            // Shared refresh button for metadata
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await appServices.garage.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .symbolEffect(.rotate, value: appServices.garage.isLoading)
                .disabled(appServices.garage.isLoading)
                .help("Refresh Garage metadata")
            }
        }
        .task {
            // Refresh metadata if not loaded (e.g., app launched offline)
            if appServices.garage.availableMetadata == nil {
                await appServices.garage.refresh()
            }
        }
    }
}
