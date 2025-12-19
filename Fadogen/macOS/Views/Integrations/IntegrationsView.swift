import SwiftUI
import SwiftData

struct IntegrationsView: View {
    @Query(sort: \Integration.createdAt) private var integrations: [Integration]

    @State private var selectedIntegration: Integration?
    @State private var showingAddIntegration: IntegrationType?

    // Grid layout: 3 columns
    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]

    /// All integration cards (configured + unconfigured)
    private var allIntegrationCards: [(integration: Integration?, type: IntegrationType, isConfigured: Bool)] {
        var cards: [(integration: Integration?, type: IntegrationType, isConfigured: Bool)] = []

        // Add configured integrations
        for integration in integrations {
            cards.append((integration, integration.type, true))
        }

        // Add unconfigured integration types
        let configuredTypes = Set(integrations.map { $0.type })
        for type in IntegrationType.allCases where !configuredTypes.contains(type) {
            cards.append((nil, type, false))
        }

        return cards.sorted { lhs, rhs in
            lhs.type.metadata.displayName < rhs.type.metadata.displayName
        }
    }

    var body: some View {
        Group {
            if allIntegrationCards.isEmpty {
                ContentUnavailableView {
                    Label("No Integrations", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Connect cloud providers and services to manage your infrastructure")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(Array(allIntegrationCards.enumerated()), id: \.offset) { _, card in
                            Button {
                                handleCardTap(card)
                            } label: {
                                IntegrationCard(
                                    integration: card.integration,
                                    type: card.type,
                                    isConfigured: card.isConfigured
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Integrations")
        .sheet(item: $selectedIntegration) { integration in
            IntegrationDetailView(integration: integration)
        }
        .sheet(item: $showingAddIntegration) { type in
            IntegrationSheet(adding: type)
        }
    }

    private func handleCardTap(_ card: (integration: Integration?, type: IntegrationType, isConfigured: Bool)) {
        if card.isConfigured, let integration = card.integration {
            // Show detail view
            selectedIntegration = integration
        } else {
            // Show add sheet
            showingAddIntegration = card.type
        }
    }
}

// MARK: - Integration Detail View

struct IntegrationDetailView: View {
    let integration: Integration
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ProvisioningService.self) private var provisioningService
    @State private var showingDeleteAlert = false
    @State private var showingEditSheet = false
    @State private var orphanedTunnelsCount: Int = 0
    @State private var isCleaningUp: Bool = false
    @State private var cleanupError: String?

    private var cloudflareService: CloudflareService {
        provisioningService.cloudflareService
    }

    private var isCloudflare: Bool {
        integration.type == .cloudflare
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    // Integration logo
                    if !integration.type.metadata.assetName.isEmpty {
                        Image(integration.type.metadata.assetName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(integration.type.metadata.displayName)
                            .font(.title2)
                            .fontWeight(.semibold)

                        FlowLayout(spacing: 6) {
                            ForEach(integration.capabilities, id: \.self) { capability in
                                CapabilityBadge(capability: capability)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                if isCloudflare, let email = integration.credentials.email {
                    LabeledContent("Account Email", value: email)
                }

                LabeledContent("Created", value: integration.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            if let servers = integration.servers, !servers.isEmpty {
                Section("Servers") {
                    Text("\(servers.count) server(s) using this integration")
                        .foregroundStyle(.secondary)
                }
            }

            // Cloudflare-specific: Orphaned tunnels cleanup
            if isCloudflare && orphanedTunnelsCount > 0 {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Orphaned Tunnels", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("\(orphanedTunnelsCount) tunnel\(orphanedTunnelsCount == 1 ? "" : "s") need cleanup")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isCleaningUp {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Clean Up All") {
                                cleanUpAllOrphanedTunnels()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                    }
                    .padding(.vertical, 4)

                    if let error = cleanupError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Cleanup Required")
                }
            }

            Section {
                if let docURL = integration.type.metadata.documentationURL {
                    Link("Documentation", destination: docURL.localizedDocumentationURL())
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    showingEditSheet = true
                }
            }

            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            IntegrationSheet(editing: integration)
        }
        .alert("Delete Integration", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteIntegration()
            }
        } message: {
            Text("This will remove the integration and delete the stored credentials. This action cannot be undone.")
        }
        .task {
            if isCloudflare {
                await fetchOrphanedTunnelsCount()
            }
        }
    }

    private func deleteIntegration() {
        modelContext.delete(integration)
        dismiss()
    }

    private func fetchOrphanedTunnelsCount() async {
        let integrationID = integration.id
        let predicate = #Predicate<CloudflareTunnel> { tunnel in
            tunnel.integration?.id == integrationID
        }
        let descriptor = FetchDescriptor<CloudflareTunnel>(predicate: predicate)

        do {
            let tunnels = try modelContext.fetch(descriptor)
            let orphaned = tunnels.filter { $0.server == nil }
            orphanedTunnelsCount = orphaned.count
        } catch {
            orphanedTunnelsCount = 0
        }
    }

    private func cleanUpAllOrphanedTunnels() {
        isCleaningUp = true
        cleanupError = nil

        Task {
            let integrationID = integration.id
            let predicate = #Predicate<CloudflareTunnel> { tunnel in
                tunnel.integration?.id == integrationID
            }
            let descriptor = FetchDescriptor<CloudflareTunnel>(predicate: predicate)

            do {
                let allTunnels = try modelContext.fetch(descriptor)
                let tunnels = allTunnels.filter { $0.server == nil }

                guard let email = integration.credentials.email,
                      let apiKey = integration.credentials.globalAPIKey else {
                    cleanupError = "Invalid Cloudflare credentials"
                    isCleaningUp = false
                    return
                }

                for tunnel in tunnels {
                    guard let tunnelID = tunnel.tunnelID,
                          let zoneID = tunnel.zoneID,
                          let dnsRecordID = tunnel.dnsRecordID else {
                        continue
                    }

                    do {
                        let accountID = try await cloudflareService.getAccountID(integration: integration)

                        try await cloudflareService.deleteDNSRecord(
                            recordID: dnsRecordID,
                            zoneID: zoneID,
                            email: email,
                            apiKey: apiKey
                        )

                        try await cloudflareService.deleteTunnel(
                            tunnelID: tunnelID,
                            accountID: accountID,
                            email: email,
                            apiKey: apiKey
                        )

                        modelContext.delete(tunnel)
                    } catch {
                        cleanupError = "Failed to delete some tunnels: \(error.localizedDescription)"
                    }
                }

                try modelContext.save()
                await fetchOrphanedTunnelsCount()
                isCleaningUp = false
            } catch {
                cleanupError = "Failed to fetch orphaned tunnels: \(error.localizedDescription)"
                isCleaningUp = false
            }
        }
    }
}
