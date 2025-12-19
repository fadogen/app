import SwiftUI
import SwiftData

/// Reusable Cloudflare Tunnel configuration section for server creation flows
struct CloudflareTunnelConfigSection: View {
    @Binding var tunnelConfig: CloudflareTunnelConfig?

    @Environment(ProvisioningService.self) private var provisioningService
    @Query private var integrations: [Integration]

    // MARK: - State

    @State private var enableCloudflareTunnel: Bool = false
    @State private var availableZones: [CloudflareZone] = []
    @State private var selectedZone: CloudflareZone?
    @State private var sshSubdomain: String = "ssh"
    @State private var isLoadingZones: Bool = false
    @State private var zonesError: String?
    @State private var subdomainValidationError: String?

    // Subdomain availability checking
    @State private var subdomainAvailabilityStatus: SubdomainStatus = .unchecked
    @State private var subdomainCheckTask: Task<Void, Never>?

    // DNS record deletion state
    @State private var isDeletingRecord = false
    @State private var deletionError: String?

    // MARK: - Disabled state (for when parent is creating)

    var isDisabled: Bool = false

    // MARK: - Computed Properties

    private var cloudflareService: CloudflareService {
        provisioningService.cloudflareService
    }

    private var hasCloudflareIntegration: Bool {
        integrations.contains { $0.type == .cloudflare }
    }

    private var cloudflareIntegration: Integration? {
        integrations.first { $0.type == .cloudflare }
    }

    /// Check if subdomain is available for use
    var isSubdomainAvailable: Bool {
        switch subdomainAvailabilityStatus {
        case .available:
            return true
        case .taken, .formatError, .checking, .unchecked:
            return false
        }
    }

    /// Check if tunnel configuration is valid and complete
    var isConfigurationValid: Bool {
        if !enableCloudflareTunnel {
            return true // Not enabled = valid (nothing to configure)
        }
        return selectedZone != nil &&
               !sshSubdomain.isEmpty &&
               subdomainValidationError == nil &&
               !isLoadingZones &&
               isSubdomainAvailable
    }

    // MARK: - Body

    var body: some View {
        GroupBox {
            VStack(spacing: 16) {
                // Toggle for enabling/disabling tunnel
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $enableCloudflareTunnel) {
                        EmptyView()
                    }
                    .toggleStyle(.switch)
                    .onChange(of: enableCloudflareTunnel) { _, newValue in
                        if newValue {
                            loadCloudflareZones()
                        } else {
                            resetTunnelConfiguration()
                        }
                        updateTunnelConfig()
                    }
                    .disabled(!hasCloudflareIntegration || isDisabled)

                    Text("Protect this server with Cloudflare Tunnel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Show warning if no Cloudflare integration
                if !hasCloudflareIntegration && enableCloudflareTunnel {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Please add your Cloudflare account in Integrations first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                // Zone selection (only visible when toggle is on)
                if enableCloudflareTunnel && hasCloudflareIntegration {
                    Divider()
                    zonePickerSection
                    subdomainConfigSection
                }
            }
            .padding(8)
        } label: {
            HStack {
                Text("Cloudflare Tunnel")
                    .font(.headline)
                Text("(Optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Zone Picker Section

    @ViewBuilder
    private var zonePickerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Domain")
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(.secondary)

            if isLoadingZones {
                ProgressView()
                    .controlSize(.small)
                Text("Loading zones...")
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let error = zonesError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                    Button {
                        loadCloudflareZones()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            } else {
                Picker(selection: $selectedZone) {
                    Text("Select a domain...").tag(nil as CloudflareZone?)
                    ForEach(availableZones, id: \.id) { zone in
                        Text(zone.name).tag(zone as CloudflareZone?)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: selectedZone) { _, _ in
                    // Re-check subdomain availability when zone changes
                    if !sshSubdomain.isEmpty {
                        debouncedCheckSubdomain(sshSubdomain)
                    }
                    updateTunnelConfig()
                }
            }
        }
    }

    // MARK: - Subdomain Config Section

    @ViewBuilder
    private var subdomainConfigSection: some View {
        if selectedZone != nil {
            HStack(alignment: .top, spacing: 12) {
                Text("Subdomain")
                    .frame(width: 80, alignment: .trailing)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("ssh", text: $sshSubdomain)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: sshSubdomain) { _, newValue in
                            validateSubdomain(newValue)
                            debouncedCheckSubdomain(newValue)
                            updateTunnelConfig()
                        }

                    // Hostname preview with availability status
                    if let zone = selectedZone {
                        HStack(spacing: 6) {
                            Text("\(sshSubdomain).\(zone.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            // Availability indicator
                            availabilityIndicator
                        }
                    }

                    // Format validation error
                    if let error = subdomainValidationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // Conflict resolution UI (if taken)
                    if case .taken(let record) = subdomainAvailabilityStatus,
                       let zone = selectedZone {
                        ConflictResolutionView(
                            record: record,
                            zone: zone,
                            isDeletingRecord: isDeletingRecord,
                            deletionError: deletionError,
                            onDeleteAndReplace: { record in
                                Task {
                                    await deleteDNSRecord(record)
                                }
                            },
                            onUseAlternative: { suggestion in
                                sshSubdomain = suggestion
                            },
                            onRetryDeletion: { record in
                                Task {
                                    await deleteDNSRecord(record)
                                }
                            }
                        )
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var availabilityIndicator: some View {
        switch subdomainAvailabilityStatus {
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

        case .taken:
            // Hide redundant status - ConflictResolutionView shows it better
            EmptyView()

        case .formatError:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)

        case .unchecked:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func resetTunnelConfiguration() {
        selectedZone = nil
        availableZones = []
        sshSubdomain = "ssh"
        zonesError = nil
        subdomainValidationError = nil
        subdomainAvailabilityStatus = .unchecked
    }

    private func updateTunnelConfig() {
        if enableCloudflareTunnel,
           let integration = cloudflareIntegration,
           let zone = selectedZone,
           !sshSubdomain.isEmpty,
           subdomainValidationError == nil,
           isSubdomainAvailable {
            tunnelConfig = CloudflareTunnelConfig(
                integration: integration,
                zone: zone,
                sshSubdomain: sshSubdomain
            )
        } else {
            tunnelConfig = nil
        }
    }

    private func loadCloudflareZones() {
        guard let integration = cloudflareIntegration else {
            zonesError = String(localized: "No Cloudflare integration found")
            return
        }

        isLoadingZones = true
        zonesError = nil

        Task {
            do {
                let zones = try await cloudflareService.listZones(integration: integration)

                await MainActor.run {
                    availableZones = zones
                    isLoadingZones = false
                }
            } catch {
                await MainActor.run {
                    zonesError = String(localized: "Failed to load zones: \(error.localizedDescription)")
                    isLoadingZones = false
                }
            }
        }
    }

    private func validateSubdomain(_ subdomain: String) {
        do {
            try CloudflareTunnel.validateSubdomain(subdomain)
            subdomainValidationError = nil
        } catch {
            subdomainValidationError = error.localizedDescription
        }
    }

    /// Debounced subdomain availability check with 500ms delay
    private func debouncedCheckSubdomain(_ subdomain: String) {
        // Cancel previous check task
        subdomainCheckTask?.cancel()

        // If subdomain is empty or zone not selected, reset to unchecked
        guard !subdomain.isEmpty, selectedZone != nil else {
            subdomainAvailabilityStatus = .unchecked
            return
        }

        // Set checking state
        subdomainAvailabilityStatus = .checking

        // Start new debounced check (500ms delay)
        subdomainCheckTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)

            guard !Task.isCancelled else { return }

            await checkSubdomainAvailability(subdomain)
        }
    }

    /// Check if subdomain is available by querying DNS records
    private func checkSubdomainAvailability(_ subdomain: String) async {
        guard let zone = selectedZone,
              let provider = cloudflareIntegration else {
            await MainActor.run {
                subdomainAvailabilityStatus = .unchecked
            }
            return
        }

        guard let email = provider.credentials.email,
              let apiKey = provider.credentials.globalAPIKey else {
            await MainActor.run {
                subdomainAvailabilityStatus = .unchecked
            }
            return
        }

        // 1. Format validation first
        do {
            try CloudflareTunnel.validateSubdomain(subdomain)
        } catch {
            await MainActor.run {
                subdomainAvailabilityStatus = .formatError(error.localizedDescription)
            }
            return
        }

        // 2. DNS availability check
        do {
            let fullHostname = "\(subdomain).\(zone.name)"
            let existingRecords = try await cloudflareService.listDNSRecords(
                zoneID: zone.id,
                name: fullHostname,  // Exact match filter
                email: email,
                apiKey: apiKey
            )

            await MainActor.run {
                if existingRecords.isEmpty {
                    subdomainAvailabilityStatus = .available
                } else {
                    subdomainAvailabilityStatus = .taken(existingRecord: existingRecords[0])
                }
                updateTunnelConfig()
            }
        } catch {
            // Don't block user on network errors - show warning but allow proceed
            // Fail open: assume available if we can't check
            await MainActor.run {
                subdomainAvailabilityStatus = .available
                updateTunnelConfig()
            }
        }
    }

    /// Delete an existing DNS record and update subdomain status to available
    private func deleteDNSRecord(_ record: CloudflareDNSRecord) async {
        guard let zone = selectedZone,
              let provider = cloudflareIntegration else {
            await MainActor.run {
                deletionError = String(localized: "Missing Cloudflare credentials")
            }
            return
        }

        guard let email = provider.credentials.email,
              let apiKey = provider.credentials.globalAPIKey else {
            await MainActor.run {
                deletionError = String(localized: "Missing Cloudflare credentials")
            }
            return
        }

        await MainActor.run {
            isDeletingRecord = true
            deletionError = nil
        }

        do {
            try await cloudflareService.deleteDNSRecord(
                recordID: record.id,
                zoneID: zone.id,
                email: email,
                apiKey: apiKey
            )

            // Success - update status to available
            await MainActor.run {
                subdomainAvailabilityStatus = .available
                isDeletingRecord = false
                updateTunnelConfig()
            }
        } catch {
            // Check if error is 404 (record already deleted)
            if let cloudflareError = error as? CloudflareError,
               case .apiError(let code, _) = cloudflareError,
               code == 404 {
                // Record already deleted - re-check availability to confirm
                await checkSubdomainAvailability(sshSubdomain)

                await MainActor.run {
                    isDeletingRecord = false
                }
                return
            }

            await MainActor.run {
                deletionError = error.localizedDescription
                isDeletingRecord = false
            }
        }
    }
}

// MARK: - Subdomain Status

enum SubdomainStatus: Equatable {
    case unchecked
    case checking
    case available
    case taken(existingRecord: CloudflareDNSRecord)
    case formatError(String)

    static func == (lhs: SubdomainStatus, rhs: SubdomainStatus) -> Bool {
        switch (lhs, rhs) {
        case (.unchecked, .unchecked), (.checking, .checking), (.available, .available):
            return true
        case (.taken(let lhsRecord), .taken(let rhsRecord)):
            return lhsRecord.id == rhsRecord.id
        case (.formatError(let lhsError), .formatError(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}

// MARK: - Conflict Resolution View

/// UI component shown when a DNS subdomain conflict is detected
struct ConflictResolutionView: View {
    let record: CloudflareDNSRecord
    let zone: CloudflareZone
    let isDeletingRecord: Bool
    let deletionError: String?
    let onDeleteAndReplace: (CloudflareDNSRecord) -> Void
    let onUseAlternative: (String) -> Void
    let onRetryDeletion: (CloudflareDNSRecord) -> Void

    @State private var showingDeleteConfirmation = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Warning header
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                    Text("This subdomain is already in use")
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Divider()
                    .padding(.vertical, 4)

                // Error message (if deletion failed)
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

                // Options - Two buttons side by side
                HStack(spacing: 8) {
                    // Option 1: Auto-suggest alternative
                    Button {
                        onUseAlternative(suggestedAlternative)
                    } label: {
                        Text("Use \"\(suggestedAlternative)\"")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeletingRecord)

                    // Option 2: Delete (dangerous) OR Retry if error
                    if deletionError != nil {
                        // Show retry button
                        Button {
                            onRetryDeletion(record)
                        } label: {
                            Text("Retry Deletion")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    } else {
                        // Show delete button with loading state
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
                                onDeleteAndReplace(record)
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will delete the existing \(record.type) record for \(record.name). The new DNS record will be created automatically during server provisioning.")
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    /// Auto-increment suggestion (ssh -> ssh-2 -> ssh-3)
    private var suggestedAlternative: String {
        let recordName = record.name

        let parts = recordName.split(separator: ".")
        guard let subdomain = parts.first else {
            return "ssh-2"
        }

        let base = String(subdomain)

        // Try to extract number suffix (e.g., "ssh-2" -> 2)
        let regex = try? NSRegularExpression(pattern: "^(.+?)-(\\d+)$")
        let nsRange = NSRange(base.startIndex..., in: base)

        if let match = regex?.firstMatch(in: base, range: nsRange),
           match.numberOfRanges == 3,
           let numRange = Range(match.range(at: 2), in: base),
           let num = Int(base[numRange]) {
            // Extract prefix without the -number suffix
            let prefixRange = Range(match.range(at: 1), in: base)!
            let prefix = String(base[prefixRange])
            return "\(prefix)-\(num + 1)"
        } else {
            // No number suffix, add -2
            return "\(base)-2"
        }
    }
}
