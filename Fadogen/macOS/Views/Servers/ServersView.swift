import SwiftUI
import SwiftData

struct ServersView: View {
    @Query(sort: [SortDescriptor(\Server.name, comparator: .localizedStandard)]) private var servers: [Server]
    @Query(sort: [SortDescriptor(\DeployedProject.name, comparator: .localizedStandard)]) private var deployedProjects: [DeployedProject]
    @Query(sort: [SortDescriptor(\LocalProject.name, comparator: .localizedStandard)]) private var localProjects: [LocalProject]
    @Query(sort: \Integration.createdAt) private var allIntegrations: [Integration]
    @Query private var userPreferences: [UserPreferences]
    @Query(sort: \PHPVersion.major) private var phpVersions: [PHPVersion]
    @Query(sort: \NodeVersion.major) private var nodeVersions: [NodeVersion]
    @Query private var bunVersions: [BunVersion]
    @State private var showingAddSheet = false
    @State private var createdServer: Server?
    @State private var hoveredID: String?

    var body: some View {
        Group {
            if servers.isEmpty {
                ContentUnavailableView {
                    Label("No Servers", systemImage: "server.rack")
                } description: {
                    Text("Add a server to deploy your sites")
                } actions: {
                    Button("Add Server") {
                        showingAddSheet = true
                    }
                }
            } else {
                List(servers) { server in
                    NavigationLink(value: server) {
                        ServerRow(server: server)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .hoverableRow(hoveredID: $hoveredID, versionID: server.id.uuidString)
                }
                .listStyle(.inset)
                .navigationDestination(for: Server.self) { server in
                    ServerDetailView(server: server)
                }
                .navigationDestination(for: ProjectDestination.self) { destination in
                    switch destination {
                    case .newProject:
                        EmptyView() // Not used from servers view
                    case .projectDetail(let localProject, let deployedProject):
                        ProjectDetailView(
                            localProject: localProject,
                            deployedProject: deployedProject,
                            servers: servers,
                            allIntegrations: allIntegrations,
                            deployedProjects: deployedProjects,
                            userPreferences: userPreferences,
                            phpVersions: phpVersions,
                            nodeVersions: nodeVersions,
                            bunVersions: bunVersions,
                            localProjects: localProjects
                        )
                    }
                }
            }
        }
        .navigationDestination(item: $createdServer) { server in
            ServerDetailView(server: server)
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItem {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddServerSheet(createdServer: $createdServer)
        }
    }
}

struct ServerRow: View {
    let server: Server

    var body: some View {
        HStack(spacing: 12) {
            // Integration icon
            if let integration = server.integration {
                Image(integration.type.metadata.assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(server.name ?? (server.status == .ready ? server.host : nil) ?? "Server")
                        .font(.body)
                        .fontWeight(.medium)

                    if server.status == .ready {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                // Display based on server status
                switch server.status {
                case .created, .waitingForIP:
                    Text("Server configuring...")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .provisioning:
                    Text("Provisioning in progress...")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .ready:
                    if server.hasCompleteConfig() {
                        Text("\(server.username!)@\(server.host ?? "unknown")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Ready")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .failed:
                    Text("Provisioning failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}
