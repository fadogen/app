import SwiftUI
import SwiftData

/// Navigation-based view for configuring project deployment to production server
struct ProductionConfigurationView: View {
    enum DNSRecordStatus: Equatable {
        case unchecked
        case checking
        case available
        case currentDomain  // DNS already configured for this project
        case taken(existingRecord: DNSRecord)
        case formatError(String)

        static func == (lhs: DNSRecordStatus, rhs: DNSRecordStatus) -> Bool {
            switch (lhs, rhs) {
            case (.unchecked, .unchecked), (.checking, .checking), (.available, .available), (.currentDomain, .currentDomain):
                return true
            case (.taken(let lhsRecord), .taken(let rhsRecord)):
                return lhsRecord.id == rhsRecord.id
            case (.formatError(let lhsMsg), .formatError(let rhsMsg)):
                return lhsMsg == rhsMsg
            default:
                return false
            }
        }
    }

    /// Local project (optional for remote-only sites)
    var project: LocalProject?

    // Data passed from parent view to avoid @Query (causes infinite loops in navigation destinations)
    let servers: [Server]
    let allIntegrations: [Integration]
    let deployedProjects: [DeployedProject]
    let userPreferences: [UserPreferences]

    /// The deployed project - passed from parent (nil for new deployments, created lazily on save)
    /// IMPORTANT: Do NOT create SwiftData @Model objects in view initializers - causes infinite loops
    let existingDeployedProject: DeployedProject?

    /// Convenience initializer for LocalProject with optional DeployedProject
    init(
        project: LocalProject,
        deployedProject: DeployedProject?,
        servers: [Server],
        allIntegrations: [Integration],
        deployedProjects: [DeployedProject],
        userPreferences: [UserPreferences]
    ) {
        self.project = project
        self.servers = servers
        self.allIntegrations = allIntegrations
        self.deployedProjects = deployedProjects
        self.userPreferences = userPreferences
        self.existingDeployedProject = deployedProject
    }

    /// Convenience initializer for remote-only DeployedProject
    init(
        deployedProject: DeployedProject,
        servers: [Server],
        allIntegrations: [Integration],
        deployedProjects: [DeployedProject],
        userPreferences: [UserPreferences]
    ) {
        self.project = nil
        self.servers = servers
        self.allIntegrations = allIntegrations
        self.deployedProjects = deployedProjects
        self.userPreferences = userPreferences
        self.existingDeployedProject = deployedProject
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigateToSection) private var navigateToSection
    @Environment(DNSManager.self) private var dnsManager
    @Environment(ProjectDeploymentService.self) private var deploymentService

    private var dnsIntegrations: [Integration] {
        allIntegrations.filter { $0.supports(.dns) }
    }

    private var backupIntegrations: [Integration] {
        allIntegrations.filter { $0.supports(.backup) }
    }

    private var readyServers: [Server] {
        servers.filter { $0.status == .ready }
    }

    /// Filtered zones based on server configuration
    /// If server has Cloudflare Tunnel, only show Cloudflare DNS zones
    private var filteredZones: [DNSZone] {
        guard let server = selectedServer else {
            return availableZones
        }

        guard server.cloudflareTunnel != nil else {
            return availableZones
        }

        // Cloudflare Tunnel requires Cloudflare DNS (CNAME flattening for apex domains)
        return availableZones.filter { $0.integration.type == .cloudflare }
    }

    enum DomainMode: String, CaseIterable {
        case managed = "Your Domains"
        case custom = "Custom Domain"
    }

    @State private var domainMode: DomainMode = .managed
    @State private var selectedDNSIntegration: Integration?
    @State private var availableZones: [DNSZone] = []
    @State private var selectedZone: DNSZone?
    @State private var subdomain = ""
    @State private var customDomain = ""
    @State private var isLoadingZones = false

    @State private var selectedServer: Server?
    @State private var selectedBackupIntegration: Integration?

    @State private var acmeEmail = ""

    @State private var dnsRecordStatus: DNSRecordStatus = .unchecked
    @State private var checkTask: Task<Void, Never>?
    @State private var isDeletingRecord = false
    @State private var deletionError: String?
    @State private var showingDeleteConfirmation = false
    @State private var showingAddIntegration: IntegrationType?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Info banner when using saved env configuration (no local path)
                if let path = project?.path, !FileManager.default.fileExists(atPath: path), existingDeployedProject?.envProductionContent != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Using saved environment configuration (project not available locally)")
                            .font(.callout)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                serverSection

                if selectedServer != nil {
                    dnsZoneSection

                    if selectedServer?.cloudflareTunnel == nil {
                        traefikSection
                    }

                    if !backupIntegrations.isEmpty {
                        backupSection
                    }

                    if isGitHubRepo && githubIntegration == nil {
                        githubWarningSection
                    }
                } else {
                    // Help message when no server is selected
                    GroupBox {
                        Text("Select a server above to configure production deployment")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Production Configuration")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark") {
                    configureDeploy()
                }
                .disabled(!canDeploy)
            }
        }
        .overlay {
            if deploymentService.isDeploying {
                ProgressView("Configuring deployment...")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear {
            // Re-scan Git repository to catch remote URL changes (only for local projects)
            if let project, let repo = try? project.detectGitRepository() {
                if project.gitRemoteURL != repo.remoteURL || project.gitBranch != repo.branch {
                    project.gitRemoteURL = repo.remoteURL
                    project.gitBranch = repo.branch
                    try? modelContext.save()
                }
            }

            // Load existing configuration ONLY if project is actually deployed
            if let deployedProject = existingDeployedProject, deployedProject.server != nil && deployedProject.productionDomain != nil {
                loadExistingConfiguration(from: deployedProject)
            }

            // Load all zones from all DNS integrations
            loadAllZones()

            loadUserPreferences()
        }
        .sheet(item: $showingAddIntegration) { type in
            IntegrationSheet(adding: type)
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        GroupBox {
            VStack(spacing: 12) {
                if readyServers.isEmpty {
                    VStack(spacing: 12) {
                        Text("Add and provision a server to enable deployment")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            navigateToSection(.servers)
                        } label: {
                            Label("Go to Servers", systemImage: "arrow.forward")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Deploy to")
                            .frame(width: 110, alignment: .trailing)
                            .foregroundStyle(.secondary)

                        Picker(selection: $selectedServer) {
                            Text("Select server").tag(nil as Server?)
                            ForEach(readyServers) { server in
                                Text(server.name ?? server.host ?? "Unknown").tag(server as Server?)
                            }
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let server = selectedServer, server.cloudflareTunnel != nil {
                        HStack(spacing: 6) {
                            Spacer().frame(width: 110)
                            Label("Cloudflare Tunnel enabled", systemImage: "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundStyle(.blue)
                            Spacer()
                        }
                    }
                }
            }
            .padding(8)
        } label: {
            Text("Server")
                .font(.headline)
        }
    }

    private var dnsZoneSection: some View {
        GroupBox {
            VStack(spacing: 12) {
                // Domain Type picker
                HStack(alignment: .center, spacing: 12) {
                    Text("Domain Type")
                        .frame(width: 110, alignment: .trailing)
                        .foregroundStyle(.secondary)

                    Picker(selection: $domainMode) {
                        ForEach(DomainMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300, alignment: .leading)

                    Spacer()
                }

                Divider()

                // Domain configuration based on mode
                switch domainMode {
                case .managed:
                    managedDomainFields
                case .custom:
                    customDomainFields
                }
            }
            .padding(8)
        } label: {
            Text("Production Domain")
                .font(.headline)
        }
        .onChange(of: selectedZone) { _, newZone in
            if let zone = newZone {
                selectedDNSIntegration = zone.integration
                debouncedCheckDNSRecord()
            }
        }
        .onChange(of: selectedServer) { _, _ in
            // Reset zone selection if it's no longer in filtered zones
            if let currentZone = selectedZone {
                if !filteredZones.contains(where: { $0.id == currentZone.id }) {
                    selectedZone = nil
                }
            }
        }
    }

    @ViewBuilder
    private var managedDomainFields: some View {
        if dnsIntegrations.isEmpty {
            HStack {
                Spacer().frame(width: 110)
                Text("No DNS integrations configured")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if isLoadingZones {
            HStack(spacing: 12) {
                Spacer().frame(width: 110)
                ProgressView()
                    .controlSize(.small)
                Text("Loading domains...")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if !filteredZones.isEmpty {
            // Domain picker
            HStack(alignment: .center, spacing: 12) {
                Text("Domain")
                    .frame(width: 110, alignment: .trailing)
                    .foregroundStyle(.secondary)

                Picker(selection: $selectedZone) {
                    Text("Select domain").tag(nil as DNSZone?)
                    ForEach(filteredZones, id: \.id) { zone in
                        Text("\(zone.name) (\(zone.integration.type.metadata.displayName))").tag(zone as DNSZone?)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Cloudflare Tunnel DNS restriction notice
            if selectedServer?.cloudflareTunnel != nil {
                HStack(spacing: 6) {
                    Spacer().frame(width: 110)
                    Label("Only Cloudflare DNS zones shown (Cloudflare Tunnel requires Cloudflare DNS)", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Spacer()
                }
            }

            // Subdomain (if domain selected)
            if selectedZone != nil {
                HStack(alignment: .top, spacing: 12) {
                    Text("Subdomain")
                        .frame(width: 110, alignment: .trailing)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Optional", text: $subdomain)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.none)
                            .onChange(of: subdomain) { _, _ in
                                debouncedCheckDNSRecord()
                            }
                            .onChange(of: selectedZone) { _, _ in
                                debouncedCheckDNSRecord()
                            }

                        // Domain preview with status
                        if let fqdn = fullDomain {
                            HStack(spacing: 6) {
                                Text("→ https://\(fqdn)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                dnsRecordStatusIndicator
                            }
                        }

                        // Conflict resolution
                        if case .taken = dnsRecordStatus {
                            conflictResolutionView
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            HStack {
                Spacer().frame(width: 110)
                Text("No domains available")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var customDomainFields: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Domain")
                .frame(width: 110, alignment: .trailing)
                .foregroundStyle(.secondary)

            TextField("example.com", text: $customDomain)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .autocorrectionDisabled()
        }

        HStack {
            Spacer().frame(width: 110)
            Text("Configure DNS records manually for custom domains")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var traefikSection: some View {
        GroupBox {
            VStack(spacing: 12) {
                // Email field for ACME (Let's Encrypt)
                HStack(alignment: .center, spacing: 12) {
                    Text("Email")
                        .frame(width: 110, alignment: .trailing)
                        .foregroundStyle(.secondary)

                    TextField("your@email.com", text: $acmeEmail)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                }
            }
            .padding(8)
        } label: {
            Text("SSL Certificates")
                .font(.headline)
        }
    }

    private var backupSection: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                Text("Service")
                    .frame(width: 110, alignment: .trailing)
                    .foregroundStyle(.secondary)

                Picker(selection: $selectedBackupIntegration) {
                    Text("None").tag(nil as Integration?)
                    ForEach(backupIntegrations) { integration in
                        Text(integration.displayName).tag(integration as Integration?)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        } label: {
            HStack {
                Text("Backup")
                    .font(.headline)
                Text("Optional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var githubWarningSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("GitHub Integration Required")
                        .font(.headline)
                        .foregroundStyle(.orange)
                }

                Text("This project requires GitHub integration for automated deployment with GitHub Actions.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Text("Deployment secrets will be configured automatically when you save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showingAddIntegration = .github
                } label: {
                    Label("Add GitHub Integration", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(8)
        } label: {
            Text("GitHub CI/CD")
                .font(.headline)
        }
    }

    // MARK: - Helper Views

    private var dnsRecordStatusIndicator: some View {
        Group {
            switch dnsRecordStatus {
            case .unchecked:
                EmptyView()
            case .checking:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                Text("Checking...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .available:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Available")
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .currentDomain:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
                Text("Current domain")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            case .taken:
                EmptyView()  // Handled by conflictResolutionView
            case .formatError(let message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var conflictResolutionView: some View {
        Group {
            if case .taken(let existingRecord) = dnsRecordStatus {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        // Warning header
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.orange)
                            Text(subdomain.isEmpty ? "This domain is already in use" : "This subdomain is already in use")
                                .font(.caption)
                                .fontWeight(.medium)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        // Show deletion error if exists
                        if let error = deletionError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .padding(.bottom, 4)
                        }

                        // Two-button layout
                        HStack(spacing: 8) {
                            // Option 1: Use alternative (only if subdomain is not empty)
                            if !subdomain.isEmpty {
                                Button {
                                    useAlternativeSubdomain()
                                } label: {
                                    Text("Use \"\(suggestedAlternative)\"")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.bordered)
                                .disabled(isDeletingRecord)
                            }

                            // Option 2: Delete OR Retry
                            if deletionError != nil {
                                Button {
                                    deleteDNSRecord(existingRecord)
                                } label: {
                                    Text("Retry Deletion")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                            } else {
                                Button(role: .destructive) {
                                    showingDeleteConfirmation = true
                                } label: {
                                    HStack(spacing: 4) {
                                        if isDeletingRecord {
                                            ProgressView()
                                                .controlSize(.mini)
                                                .scaleEffect(0.8)
                                        }
                                        Text(isDeletingRecord ? "Deleting..." : "Delete")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .disabled(isDeletingRecord)
                                .confirmationDialog(
                                    "Delete existing DNS record?",
                                    isPresented: $showingDeleteConfirmation,
                                    titleVisibility: .visible
                                ) {
                                    Button("Delete", role: .destructive) {
                                        deleteDNSRecord(existingRecord)
                                    }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("This will delete the existing \(existingRecord.type) record. The new DNS record will be created automatically during deployment.")
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var fullDomain: String? {
        switch domainMode {
        case .managed:
            guard let zone = selectedZone else { return nil }
            return subdomain.isEmpty ? zone.name : "\(subdomain).\(zone.name)"
        case .custom:
            return customDomain.isEmpty ? nil : customDomain
        }
    }

    private var dnsRecordType: String {
        selectedServer?.cloudflareTunnel != nil ? "CNAME" : "A"
    }

    private var githubIntegration: Integration? {
        allIntegrations.first { $0.type == .github }
    }

    private var isGitHubRepo: Bool {
        // Check project first, then fall back to existingDeployedProject
        if let project {
            return project.githubOwner != nil && project.githubRepo != nil
        }
        return existingDeployedProject?.githubOwner != nil && existingDeployedProject?.githubRepo != nil
    }

    private var canDeploy: Bool {
        guard selectedServer != nil else { return false }
        guard fullDomain != nil else { return false }

        // For managed domains, ensure DNS record is available or already ours
        if domainMode == .managed {
            guard dnsRecordStatus == .available || dnsRecordStatus == .currentDomain else { return false }
        }

        // If server without tunnel, DNS integration and email required for SSL
        if selectedServer?.cloudflareTunnel == nil {
            // For managed domains: selectedDNSIntegration is set via selectedZone
            // For custom domains: need at least one DNS integration available
            switch domainMode {
            case .managed:
                guard selectedDNSIntegration != nil else { return false }
            case .custom:
                guard dnsIntegrations.first != nil else { return false }
            }
            guard !acmeEmail.isEmpty else { return false }
        }

        // If GitHub repository, GitHub integration required
        if isGitHubRepo && githubIntegration == nil {
            return false
        }

        return true
    }

    private var suggestedAlternative: String {
        // Auto-increment subdomain suggestion (e.g., "www" → "www-2", "www-2" → "www-3")
        let pattern = /^(.+)-(\d+)$/

        if let match = subdomain.firstMatch(of: pattern) {
            // Already has a number suffix (e.g., "www-2")
            let base = String(match.1)
            let number = Int(match.2) ?? 1
            return "\(base)-\(number + 1)"
        } else {
            // No number suffix yet (e.g., "www")
            return "\(subdomain)-2"
        }
    }

    // MARK: - Methods

    private func loadExistingConfiguration(from deployedProject: DeployedProject) {
        // Load existing configuration if project is already configured
        selectedServer = deployedProject.server

        if let integration = deployedProject.dnsIntegration {
            selectedDNSIntegration = integration
        }

        // Load existing backup integration
        selectedBackupIntegration = deployedProject.backupIntegration

        // Parse domain from production domain
        if let productionDomain = deployedProject.productionDomain,
           let zoneName = deployedProject.dnsZoneName,
           let zoneIntegration = deployedProject.dnsIntegration,
           let zoneID = deployedProject.dnsZoneID {

            if zoneID == "custom" {
                // This was a custom domain
                domainMode = .custom
                customDomain = productionDomain
            } else {
                // This was a managed domain
                domainMode = .managed

                if productionDomain == zoneName {
                    subdomain = ""
                } else if productionDomain.hasSuffix(".\(zoneName)") {
                    subdomain = String(productionDomain.dropLast(zoneName.count + 1))
                }

                // Reconstruct selected zone from stored data
                selectedZone = DNSZone(name: zoneName, id: zoneID, integration: zoneIntegration)
            }
        }

        // Trigger DNS check for existing configuration
        if selectedZone != nil && selectedDNSIntegration != nil {
            debouncedCheckDNSRecord()
        }
    }

    private func loadUserPreferences() {
        // Load email from UserPreferences or use empty string
        if let preferences = userPreferences.first {
            acmeEmail = preferences.acmeEmail ?? ""
        }
    }

    private func loadAllZones() {
        isLoadingZones = true

        Task { @MainActor in
            var allZones: [DNSZone] = []

            // Load zones from each integration sequentially (to avoid Sendable issues)
            for integration in dnsIntegrations {
                if let zones = try? await dnsManager.listZones(for: integration) {
                    allZones.append(contentsOf: zones)
                }
            }

            availableZones = allZones
            isLoadingZones = false
        }
    }

    private func configureDeploy() {
        guard let server = selectedServer else { return }

        Task {
            // Save ACME email to UserPreferences
            saveUserPreferences()

            // Prepare DNS zone based on domain mode
            let zoneToUse: DNSZone?
            let subdomainToUse: String

            switch domainMode {
            case .managed:
                zoneToUse = selectedZone
                subdomainToUse = subdomain
            case .custom:
                // Create virtual zone for custom domain
                if let firstIntegration = dnsIntegrations.first {
                    zoneToUse = DNSZone(
                        name: customDomain,
                        id: "custom",
                        integration: firstIntegration
                    )
                } else {
                    zoneToUse = nil
                }
                subdomainToUse = ""  // No subdomain for custom domains
            }

            // Dismiss immediately - user sees deployment progress in Production tab
            await MainActor.run {
                dismiss()
            }

            // Continue deployment in background
            do {
                if let project {
                    // Local project: full deployment with file operations
                    try await deploymentService.configureProjectDeployment(
                        project: project,
                        server: server,
                        domain: zoneToUse,
                        subdomain: subdomainToUse,
                        backupIntegration: selectedBackupIntegration
                    )
                } else if let deployedProject = existingDeployedProject {
                    // Remote-only: update existing DeployedProject (no local files)
                    try await deploymentService.updateDeployedProjectConfiguration(
                        deployedProject: deployedProject,
                        server: server,
                        domain: zoneToUse,
                        subdomain: subdomainToUse,
                        backupIntegration: selectedBackupIntegration
                    )
                }
            } catch {
                // On error, update status on the created/updated DeployedProject
                // The service handles this internally
            }
        }
    }

    private func saveUserPreferences() {
        if let preferences = userPreferences.first {
            // Update existing preferences
            preferences.acmeEmail = acmeEmail.isEmpty ? nil : acmeEmail
        } else {
            // Create new preferences singleton
            let newPreferences = UserPreferences(acmeEmail: acmeEmail.isEmpty ? nil : acmeEmail)
            modelContext.insert(newPreferences)
        }

        try? modelContext.save()
    }

    private func useAlternativeSubdomain() {
        subdomain = suggestedAlternative
        dnsRecordStatus = .unchecked
        debouncedCheckDNSRecord()
    }

    private func deleteDNSRecord(_ record: DNSRecord) {
        isDeletingRecord = true
        deletionError = nil

        Task {
            do {
                guard let zone = selectedZone else {
                    return
                }

                try await dnsManager.deleteRecord(record, in: zone)

                // Success - re-check availability
                await MainActor.run {
                    dnsRecordStatus = .available
                    isDeletingRecord = false
                }
            } catch {
                // Handle 404 as success (already deleted)
                if let dnsError = error as? DNSError,
                   case .apiError(let message) = dnsError,
                   message.contains("404") {
                    // Re-check availability
                    if let zone = selectedZone,
                       let integration = selectedDNSIntegration {
                        await checkDNSRecordAvailability(zone: zone, integration: integration)
                    }
                    await MainActor.run {
                        isDeletingRecord = false
                    }
                    return
                }

                // Other errors
                await MainActor.run {
                    deletionError = error.localizedDescription
                    isDeletingRecord = false
                }
            }
        }
    }

    // MARK: - DNS Record Checking

    private func debouncedCheckDNSRecord() {
        checkTask?.cancel()
        dnsRecordStatus = .unchecked

        guard let zone = selectedZone,
              let integration = selectedDNSIntegration else {
            return
        }

        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await checkDNSRecordAvailability(zone: zone, integration: integration)
        }
    }

    private func checkDNSRecordAvailability(zone: DNSZone, integration: Integration) async {
        await MainActor.run {
            dnsRecordStatus = .checking
        }

        do {
            let fullDomainName = subdomain.isEmpty ? zone.name : "\(subdomain).\(zone.name)"

            // Check if this domain is reserved for SSH tunnel access
            if isSshTunnelDomain(fullDomainName) {
                await MainActor.run {
                    dnsRecordStatus = .formatError("Reserved for SSH access to this server")
                }
                return
            }

            let allRecords = try await dnsManager.listRecords(
                in: zone,
                type: nil,
                name: fullDomainName
            )

            // Filter only web hosting record types (A, AAAA, CNAME)
            let webRecords = allRecords.filter { record in
                ["A", "AAAA", "CNAME"].contains(record.type)
            }

            await MainActor.run {
                let isOurs: Bool
                let recordExists: Bool

                if let existingRecord = webRecords.first {
                    recordExists = true
                    isOurs = isOurServerRecord(existingRecord)
                    if !isOurs {
                        dnsRecordStatus = .taken(existingRecord: existingRecord)
                    }
                } else {
                    recordExists = false
                    isOurs = false
                }

                if !recordExists || isOurs {
                    if let server = selectedServer {
                        let conflictingProject = deployedProjects.first { otherSite in
                            otherSite.id != existingDeployedProject?.id &&
                            otherSite.server?.id == server.id &&
                            otherSite.productionDomain == fullDomainName
                        }

                        if let conflict = conflictingProject {
                            dnsRecordStatus = .formatError("Domain already used by '\(conflict.name)' on this server")
                        } else if recordExists && isOurs && existingDeployedProject?.productionDomain == fullDomainName {
                            dnsRecordStatus = .currentDomain
                        } else if recordExists && isOurs, let existingRecord = webRecords.first {
                            dnsRecordStatus = .taken(existingRecord: existingRecord)
                        } else {
                            dnsRecordStatus = .available
                        }
                    } else {
                        dnsRecordStatus = recordExists && isOurs ? .currentDomain : .available
                    }
                }
            }
        } catch {
            await MainActor.run {
                dnsRecordStatus = .formatError("Failed to check availability")
            }
        }
    }

    /// Check if a DNS record points to our selected server
    private func isOurServerRecord(_ record: DNSRecord) -> Bool {
        guard let server = selectedServer else { return false }

        if record.type == "CNAME" {
            if let tunnel = server.cloudflareTunnel {
                let normalizedContent = record.content.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let normalizedTunnel = tunnel.tunnelCNAME.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return normalizedContent == normalizedTunnel
            }
            return false
        }

        if record.type == "A" {
            return record.content == server.host
        }

        return false
    }

    /// Check if a domain is reserved for SSH tunnel access
    private func isSshTunnelDomain(_ domain: String) -> Bool {
        guard let server = selectedServer,
              let tunnel = server.cloudflareTunnel else {
            return false
        }
        return domain == tunnel.sshHostname
    }
}
