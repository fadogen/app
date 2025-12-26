import SwiftUI
import SwiftData

// Environment key for section navigation
private struct NavigateToSectionKey: EnvironmentKey {
    static let defaultValue: (NavigationSection) -> Void = { _ in }
}

extension EnvironmentValues {
    var navigateToSection: (NavigationSection) -> Void {
        get { self[NavigateToSectionKey.self] }
        set { self[NavigateToSectionKey.self] = newValue }
    }
}

struct ContentView: View {
    @State private var selectedSection: NavigationSection? = .projects
    @State private var projectsNavigationPath = NavigationPath()
    @Query private var watchedDirectories: [WatchedDirectory]
    @Environment(AppServices.self) private var appServices

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                // Projects standalone
                ForEach(NavigationSection.standaloneItems) { section in
                    navigationLink(for: section)
                }

                // Section PRODUCTION
                Section {
                    ForEach(NavigationSection.items(for: .production)) { section in
                        navigationLink(for: section)
                    }
                } header: {
                    Text(MenuCategory.production.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(NavigationSection.items(for: .development)) { section in
                        navigationLink(for: section)
                    }
                } header: {
                    Text(MenuCategory.development.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Divider + Settings
                Divider()
                    .padding(.vertical, 8)

                navigationLink(for: .settings)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            NavigationStack(path: $projectsNavigationPath) {
                DetailView(section: selectedSection, projectsPath: $projectsNavigationPath)
            }
        }
        .environment(\.navigateToSection) { section in
            selectedSection = section
        }
        .frame(minWidth: 950, maxWidth: 950, minHeight: 600, maxHeight: 600)
        .onChange(of: selectedSection) {
            // Clear navigation path when switching sections
            projectsNavigationPath = NavigationPath()
        }
        .onChange(of: watchedDirectories) {
            Task {
                await appServices.directoryWatcher.reconcile(syncCaddy: true)
            }
        }
        .onOpenURL { url in
            guard url.scheme == "fadogen" else { return }

            switch url.host {
            case "integrations":
                selectedSection = .integrations
            case "projects":
                selectedSection = .projects
            case "servers":
                selectedSection = .servers
            default:
                break
            }
        }
    }

    @ViewBuilder
    private func navigationLink(for section: NavigationSection) -> some View {
        NavigationLink(value: section) {
            Label {
                Text(section.localizedTitle)
            } icon: {
                if let assetName = section.assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: section.icon)
                }
            }
        }
    }
}

struct DetailView: View {
    let section: NavigationSection?
    @Binding var projectsPath: NavigationPath

    var body: some View {
        Group {
            if let section {
                switch section {
                case .projects:
                    ProjectsView(navigationPath: $projectsPath)
                case .servers:
                    ServersView()
                case .integrations:
                    IntegrationsView()
                case .php:
                    PHPView()
                case .nodeBun:
                    NodeBunView()
                case .databases:
                    DatabasesView()
                case .caches:
                    CachesView()
                case .reverb:
                    ReverbView()
                case .typesense:
                    TypesenseView()
                case .garage:
                    GarageView()
                case .mail:
                    MailpitView()
                case .caddy:
                    CaddyView()
                case .settings:
                    SettingsView()
                }
            } else {
                EmptyDetailView()
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage(UpdaterDelegate.checkForBetaUpdatesKey) private var checkForBetaUpdates = false
    @Query private var userPreferences: [UserPreferences]
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    private var preferences: UserPreferences? { userPreferences.first }
    private var installedIDEs: [IDE] { services.ideService.installedIDEs }

    private var currentLanguageName: String {
        let languageCode = Locale.current.safeLanguageCode
        return Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode
    }

    var body: some View {
        Form {
            Section("Language") {
                LabeledContent("Current Language", value: currentLanguageName)

                Button("Change Language...") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings")!)
                }

                Text("You can set a different language for this app in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Editor") {
                if installedIDEs.isEmpty {
                    Text("No code editors detected")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Default Editor", selection: Binding(
                        get: { preferences?.preferredIDE },
                        set: { setPreferredIDE($0) }
                    )) {
                        Text("None").tag(nil as IDE?)
                        ForEach(installedIDEs) { ide in
                            Text(ide.displayName).tag(ide as IDE?)
                        }
                    }
                }

                Text("Fadogen will use this editor when opening projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Receive beta updates", isOn: $checkForBetaUpdates)
                Text("When enabled, you'll receive alpha, beta, and release candidate versions in addition to stable releases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            services.ideService.refreshDetection()
        }
    }

    private func setPreferredIDE(_ ide: IDE?) {
        if let prefs = preferences {
            prefs.preferredIDE = ide
        } else {
            let newPrefs = UserPreferences(preferredIDE: ide)
            modelContext.insert(newPrefs)
        }
        try? modelContext.save()
    }
}

struct EmptyDetailView: View {
    var body: some View {
        ContentUnavailableView(
            "Select a Section",
            systemImage: "sidebar.left",
            description: Text("Choose a section from the sidebar to get started")
        )
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
    }
}
