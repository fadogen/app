import SwiftUI
import SwiftData

/// Cache management view (Redis, Valkey)
/// Follows the same pattern as DatabasesView
struct CachesView: View {
    @Environment(AppServices.self) private var appServices
    @Query private var installedServices: [ServiceVersion]

    /// Filter only cache services (Redis, Valkey)
    private var installedCaches: [ServiceVersion] {
        installedServices.filter { $0.serviceType.isCache }
    }

    @State private var showAddSheet = false
    @State private var hoveredID: String?

    var body: some View {
        Group {
            if installedCaches.isEmpty {
                ContentUnavailableView {
                    Label("No Caches Installed", systemImage: "speedometer")
                } description: {
                    Text("Add Redis or Valkey to get started")
                } actions: {
                    Button("Add Cache") {
                        showAddSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    // Section Redis
                    if !redisVersions.isEmpty {
                        Section("Redis") {
                            ForEach(redisVersions) { version in
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

                    // Section Valkey
                    if !valkeyVersions.isEmpty {
                        Section("Valkey") {
                            ForEach(valkeyVersions) { version in
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
                .id(installedCaches.map { service in
                    // For single-installation: include highest major's latest to refresh on new major availability
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
        .navigationTitle("Caches")
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
                ProgressView("Loading cache versions...")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ServiceSheet(adding: [.redis, .valkey])
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

    private var redisVersions: [DisplayServiceVersion] {
        buildDisplayVersions(for: .redis)
    }

    private var valkeyVersions: [DisplayServiceVersion] {
        buildDisplayVersions(for: .valkey)
    }

    /// Build display models for installed versions only
    private func buildDisplayVersions(for service: ServiceType) -> [DisplayServiceVersion] {
        let installedForService = installedCaches.filter { $0.serviceType == service }

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
