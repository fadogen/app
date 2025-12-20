import SwiftUI
import SwiftData

/// Database management view (MariaDB, MySQL, PostgreSQL)
/// Follows the same pattern as PHPView
struct DatabasesView: View {
    @Environment(AppServices.self) private var appServices
    @Query private var installedServices: [ServiceVersion]

    /// Filter only database services (MariaDB, MySQL, PostgreSQL)
    private var installedDatabases: [ServiceVersion] {
        installedServices.filter { $0.serviceType.isDatabase }
    }

    @State private var showAddSheet = false
    @State private var hoveredID: String?

    var body: some View {
        Group {
            if installedDatabases.isEmpty {
                ContentUnavailableView {
                    Label("No Databases Installed", systemImage: "cylinder.split.1x2")
                } description: {
                    Text("Add PostgreSQL, MySQL, or MariaDB to get started")
                } actions: {
                    Button("Add Database") {
                        showAddSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    // Section MariaDB
                    if !mariadbVersions.isEmpty {
                        Section("MariaDB") {
                            ForEach(mariadbVersions) { version in
                                NavigationLink(value: version) {
                                    ServiceListRow(
                                        version: version,
                                        isRunning: appServices.serviceProcesses.isRunning(
                                            service: version.serviceType,
                                            major: version.major
                                        )
                                    )
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .hoverableRow(hoveredID: $hoveredID, versionID: version.id)
                            }
                        }
                    }

                    // Section MySQL
                    if !mysqlVersions.isEmpty {
                        Section("MySQL") {
                            ForEach(mysqlVersions) { version in
                                NavigationLink(value: version) {
                                    ServiceListRow(
                                        version: version,
                                        isRunning: appServices.serviceProcesses.isRunning(
                                            service: version.serviceType,
                                            major: version.major
                                        )
                                    )
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .hoverableRow(hoveredID: $hoveredID, versionID: version.id)
                            }
                        }
                    }

                    // Section PostgreSQL
                    if !postgresqlVersions.isEmpty {
                        Section("PostgreSQL") {
                            ForEach(postgresqlVersions) { version in
                                NavigationLink(value: version) {
                                    ServiceListRow(
                                        version: version,
                                        isRunning: appServices.serviceProcesses.isRunning(
                                            service: version.serviceType,
                                            major: version.major
                                        )
                                    )
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .hoverableRow(hoveredID: $hoveredID, versionID: version.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .id(installedDatabases.map { service in
                    let latestVersion = appServices.services.latestAvailable(
                        service: service.serviceType,
                        major: service.major
                    ) ?? ""
                    return "\(service.serviceType.rawValue)-\(service.major)-\(service.minor)-\(service.port)-\(service.autoStart)-\(latestVersion)"
                }.joined())
                .navigationDestination(for: DisplayServiceVersion.self) { version in
                    ServiceDetailView(service: version)
                }
            }
        }
        .navigationTitle("Databases")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await appServices.services.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .symbolEffect(.rotate, value: appServices.services.isLoading)
                .disabled(appServices.services.isLoading)
            }

            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .overlay {
            if appServices.services.isLoading && appServices.services.availableServices.isEmpty {
                ProgressView("Loading database versions...")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ServiceSheet(adding: [.mariadb, .mysql, .postgresql])
        }
        .alert("Operation Error", isPresented: .constant(!appServices.services.operationErrors.isEmpty)) {
            Button("OK") {
                appServices.services.operationErrors.removeAll()
            }
        } message: {
            if let firstError = appServices.services.operationErrors.first {
                Text("\(firstError.key): \(firstError.value)")
            }
        }
    }

    // MARK: - Computed Properties

    private var mariadbVersions: [DisplayServiceVersion] {
        buildDisplayVersions(for: .mariadb)
    }

    private var mysqlVersions: [DisplayServiceVersion] {
        buildDisplayVersions(for: .mysql)
    }

    private var postgresqlVersions: [DisplayServiceVersion] {
        buildDisplayVersions(for: .postgresql)
    }

    /// Build display models for installed versions only
    private func buildDisplayVersions(for service: ServiceType) -> [DisplayServiceVersion] {
        let installedForService = installedDatabases.filter { $0.serviceType == service }

        return installedForService.sorted { $0.major > $1.major }.map { installed in
            let latestAvailable = appServices.services.latestAvailable(
                service: service,
                major: installed.major
            ) ?? installed.minor

            let hasUpdate = appServices.services.hasUpdate(
                service: service,
                major: installed.major,
                currentMinor: installed.minor
            )

            return DisplayServiceVersion(
                serviceType: service,
                major: installed.major,
                minor: installed.minor,
                latestAvailable: latestAvailable,
                isInstalled: true,
                hasUpdate: hasUpdate,
                port: installed.port,
                autoStart: installed.autoStart
            )
        }
    }

}
