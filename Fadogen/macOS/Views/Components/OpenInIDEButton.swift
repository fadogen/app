import SwiftUI
import SwiftData

struct OpenInIDEButton: View {
    let projectPath: String

    @Environment(AppServices.self) private var services
    @Query private var userPreferences: [UserPreferences]
    @Environment(\.modelContext) private var modelContext

    private var preferences: UserPreferences? { userPreferences.first }
    private var installedIDEs: [IDE] { services.ideService.installedIDEs }
    private var preferredIDE: IDE? { preferences?.preferredIDE }

    var body: some View {
        Group {
            if installedIDEs.isEmpty {
                Text("No editor found")
                    .foregroundStyle(.secondary)
            } else if let preferred = preferredIDE, services.ideService.isInstalled(preferred) {
                // Preferred IDE is set and installed - show button with dropdown
                Menu {
                    ForEach(installedIDEs) { ide in
                        Button {
                            openInIDE(ide)
                        } label: {
                            if ide == preferred {
                                Label(ide.displayName, systemImage: "checkmark")
                            } else {
                                Text(ide.displayName)
                            }
                        }
                    }
                } label: {
                    Text("Open in \(preferred.displayName)")
                } primaryAction: {
                    openInIDE(preferred)
                }
                .menuIndicator(.visible)
            } else {
                // No preferred IDE - show picker menu
                Menu {
                    ForEach(installedIDEs) { ide in
                        Button {
                            openInIDE(ide)
                            setAsDefault(ide)
                        } label: {
                            Text(ide.displayName)
                        }
                    }
                } label: {
                    Text("Open in Editor")
                }
                .menuIndicator(.visible)
            }
        }
        .onAppear {
            services.ideService.refreshDetection()
        }
    }

    private func openInIDE(_ ide: IDE) {
        services.ideService.open(path: projectPath, in: ide)
    }

    private func setAsDefault(_ ide: IDE) {
        if let prefs = preferences {
            prefs.preferredIDE = ide
        } else {
            let newPrefs = UserPreferences(preferredIDE: ide)
            modelContext.insert(newPrefs)
        }
        try? modelContext.save()
    }
}
