import SwiftUI
import SwiftData

struct AddServerFromProviderView: View {
    @Binding var createdServer: Server?
    let preselectedIntegration: Integration?
    let onBack: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProvisioningService.self) private var provisioningService
    @Query private var integrations: [Integration]
    @Query private var allServers: [Server]

    @State private var currentStep: CreationStep = .configureServer
    @State private var selectedIntegration: Integration?

    init(createdServer: Binding<Server?>, preselectedIntegration: Integration?, onBack: @escaping () -> Void) {
        self._createdServer = createdServer
        self.preselectedIntegration = preselectedIntegration
        self.onBack = onBack
        self._selectedIntegration = State(initialValue: preselectedIntegration)
    }

    // MARK: - Composition Pattern Access

    private var sshService: SSHService {
        provisioningService.sshService
    }

    // VPSProviderService no longer needed - providers are directly accessible

    private var cloudflareService: CloudflareService {
        provisioningService.cloudflareService
    }

    // Configuration
    @State private var serverName: String = ""
    @State private var availableRegions: [any ServerRegion] = []
    @State private var availableSizes: [any ServerSize] = []
    @State private var selectedRegionID: String?
    @State private var selectedSizeID: String?

    // Cloudflare Tunnel Configuration (managed by CloudflareTunnelConfigSection)
    @State private var tunnelConfig: CloudflareTunnelConfig?

    private var selectedRegion: (any ServerRegion)? {
        availableRegions.first { $0.id == selectedRegionID }
    }

    private var selectedSize: (any ServerSize)? {
        availableSizes.first { $0.id == selectedSizeID }
    }

    /// Sizes filtered by selected region availability
    private var filteredSizes: [any ServerSize] {
        guard let region = selectedRegion else {
            return availableSizes
        }
        return availableSizes.filter { $0.isAvailableInRegion(region.slug) }
    }

    /// Get VPS integrations (non-Cloudflare)
    private var vpsIntegrations: [Integration] {
        integrations.filter { $0.supports(.vpsProvider) }
    }

    // UI State
    @State private var isLoadingConfig = false
    @State private var isCreating = false
    @State private var creationProgress: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Content based on current step
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch currentStep {
                    case .configureServer:
                        serverConfigurationView
                    case .creating:
                        creationProgressView
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            footerView
        }
        .frame(width: 650, height: 600)
        .onAppear {
            loadProviderConfiguration()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 4) {
            Text(currentStep.title)
                .font(.title2)
                .fontWeight(.semibold)
        }
        .padding(20)
        .padding(.bottom, 0)
    }

    // MARK: - Server Configuration

    private var serverConfigurationView: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isLoadingConfig {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading configuration options...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                // Server Name
                LabeledFieldGroupBox(title: String(localized: "Server Name"), label: String(localized: "Name")) {
                    TextField("Optional", text: $serverName)
                        .textFieldStyle(.roundedBorder)
                }

                // Region Selection
                GroupBox {
                    VStack(spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Region")
                                .frame(width: 80, alignment: .trailing)
                                .foregroundStyle(.secondary)

                            Picker(selection: $selectedRegionID) {
                                Text("Select a region...").tag(nil as String?)
                                ForEach(availableRegions, id: \.id) { region in
                                    Text(region.displayName).tag(region.id as String?)
                                }
                            } label: {
                                EmptyView()
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onChange(of: selectedRegionID) { _, _ in
                                // Reset size selection if it's not available in the new region
                                if let sizeID = selectedSizeID,
                                   let region = selectedRegion,
                                   let size = availableSizes.first(where: { $0.id == sizeID }),
                                   !size.isAvailableInRegion(region.slug) {
                                    selectedSizeID = nil
                                }
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Text("Region")
                        .font(.headline)
                }

                // Size Selection
                GroupBox {
                    VStack(spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Size")
                                .frame(width: 80, alignment: .trailing)
                                .foregroundStyle(.secondary)

                            if selectedRegion == nil {
                                Text("Select a region first")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                sizePicker
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Text("Server Size")
                        .font(.headline)
                }

                // Cloudflare Tunnel (Optional)
                CloudflareTunnelConfigSection(tunnelConfig: $tunnelConfig, isDisabled: isCreating)
            }
        }
    }

    // MARK: - Size Picker

    @ViewBuilder
    private var sizePicker: some View {
        // Check if provider is Hetzner to show categorized sections
        if selectedIntegration?.type == .hetzner {
            hetznerSizePicker
        } else {
            standardSizePicker
        }
    }

    private var hetznerSizePicker: some View {
        Picker(selection: $selectedSizeID) {
            Text("Select a size...").tag(nil as String?)

            // Group Hetzner servers by category
            ForEach(HetznerServerCategory.allCases, id: \.self) { category in
                let serversInCategory = filteredSizes.compactMap { $0 as? HetznerServerType }
                    .filter { $0.category == category }

                if !serversInCategory.isEmpty {
                    Section(category.rawValue) {
                        ForEach(serversInCategory, id: \.id) { size in
                            Text(size.displayNameForRegion(selectedRegion!.slug))
                                .tag(size.id as String?)
                        }
                    }
                }
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var standardSizePicker: some View {
        Picker(selection: $selectedSizeID) {
            Text("Select a size...").tag(nil as String?)
            ForEach(filteredSizes, id: \.id) { size in
                Text(size.displayNameForRegion(selectedRegion!.slug)).tag(size.id as String?)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Creation Progress

    private var creationProgressView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)

            Text(creationProgress)
                .font(.headline)
                .multilineTextAlignment(.center)

            ErrorMessageView(message: errorMessage)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: 8) {
            if currentStep != .creating {
                if let error = nameValidationError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }

                ErrorMessageView(message: errorMessage)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                .disabled(isCreating)

                Spacer()

                if currentStep == .configureServer {
                    Button("Back") {
                        onBack()
                    }
                    .disabled(isLoadingConfig || isCreating)

                    Button {
                        createServer()
                    } label: {
                        LoadingButton(
                            title: String(localized: "Create Server"),
                            loadingTitle: String(localized: "Creating..."),
                            isLoading: isCreating
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!canCreateServer || isCreating)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Helper Properties

    private var canCreateServer: Bool {
        let basicRequirementsMet = selectedRegion != nil && selectedSize != nil && !isLoadingConfig

        // Check for duplicate name
        if isDuplicateName {
            return false
        }

        return basicRequirementsMet
    }

    private var isDuplicateName: Bool {
        guard !serverName.isEmpty else { return false }
        return allServers.contains { $0.name == serverName }
    }

    private var nameValidationError: String? {
        if isDuplicateName {
            return String(localized: "A server with this name already exists")
        }
        return nil
    }

    // MARK: - Actions

    private func loadProviderConfiguration() {
        guard let integration = selectedIntegration else { return }

        guard let credentials = ProviderCredentials.retrieve(for: integration) else {
            errorMessage = String(localized: "No API token found for this integration")
            return
        }

        isLoadingConfig = true
        errorMessage = nil

        Task {
            do {
                // Get integration-specific service via factory
                let providerService = try CloudProviderFactory.createService(for: integration.type)

                async let regionList = providerService.listRegions(credentials: credentials)
                async let sizeList = providerService.listSizes(credentials: credentials)

                let (fetchedRegionList, fetchedSizeList) = try await (regionList, sizeList)

                await MainActor.run {
                    availableRegions = fetchedRegionList.regions
                    availableSizes = fetchedSizeList.sizes
                    isLoadingConfig = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = String(localized: "Failed to load configuration: \(error.localizedDescription)")
                    isLoadingConfig = false
                }
            }
        }
    }

    private func createServer() {
        guard let integration = selectedIntegration,
              let region = selectedRegion,
              let size = selectedSize else {
            errorMessage = String(localized: "Missing required configuration")
            return
        }

        isCreating = true
        currentStep = .creating
        errorMessage = nil

        Task {
            do {
                // Create service with dependencies
                let creationService = ServerCreationService(
                    sshService: sshService,

                    cloudflareService: cloudflareService,
                    ansibleManager: AnsibleManager(),
                    modelContext: modelContext
                )

                // Update progress from service (async observation)
                Task {
                    while isCreating {
                        await updateProgress(creationService.creationProgress)
                        try? await Task.sleep(nanoseconds: 100_000_000) // Check every 100ms
                    }
                }

                // Use service to create server from integration
                let newServer = try await creationService.createServerFromIntegration(
                    name: serverName,
                    integration: integration,
                    region: region,
                    size: size,
                    tunnelConfig: self.tunnelConfig
                )

                // Server created successfully - navigate to detail view
                await MainActor.run {
                    createdServer = newServer
                    dismiss()
                }

            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCreating = false
                    currentStep = .configureServer
                }
            }
        }
    }

    private func updateProgress(_ message: String) async {
        await MainActor.run {
            creationProgress = message
        }
    }
}

// MARK: - Creation Steps

private enum CreationStep {
    case configureServer
    case creating

    var title: String {
        switch self {
        case .configureServer:
            return String(localized: "Create Server")
        case .creating:
            return String(localized: "Creating Server")
        }
    }
}

