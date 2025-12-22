import SwiftUI
import SwiftData

/// Sheet for configuring a custom domain for permanent tunnel sharing.
struct CustomDomainSheet: View {
    let project: LocalProject
    let integration: Integration
    var onSuccess: () -> Void

    @Environment(AppServices.self) private var appServices
    @Environment(\.dismiss) private var dismiss

    @State private var availableZones: [CloudflareZone] = []
    @State private var selectedZone: CloudflareZone?
    @State private var subdomain: String = ""
    @State private var isLoadingZones = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var availability: SubdomainAvailability = .unchecked
    @State private var checkTask: Task<Void, Never>?

    private var canShare: Bool {
        selectedZone != nil && !subdomain.isEmpty && availability == .available && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Custom Domain")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Content
            Form {
                if isLoadingZones {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    Picker("Domain", selection: $selectedZone) {
                        Text("Select a domain...").tag(nil as CloudflareZone?)
                        ForEach(availableZones, id: \.id) { zone in
                            Text(zone.name).tag(zone as CloudflareZone?)
                        }
                    }

                    if selectedZone != nil {
                        HStack {
                            TextField("Subdomain", text: $subdomain)
                                .textFieldStyle(.roundedBorder)

                            availabilityIndicator
                        }

                        if let selectedZone {
                            Text("\(subdomain).\(selectedZone.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            // Footer with Cancel and Share buttons
            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button {
                    share()
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Share")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canShare)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 300)
        .onAppear {
            subdomain = project.sanitizedName
            loadZones()
        }
        .onChange(of: selectedZone) { _, _ in
            checkAvailability()
        }
        .onChange(of: subdomain) { _, _ in
            checkAvailability()
        }
    }

    @ViewBuilder
    private var availabilityIndicator: some View {
        switch availability {
        case .checking:
            ProgressView().controlSize(.mini)
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .taken:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help("This subdomain is already in use")
        case .invalid:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .help("Invalid subdomain format")
        case .unchecked:
            EmptyView()
        }
    }

    private func loadZones() {
        isLoadingZones = true
        Task { @MainActor in
            do {
                availableZones = try await appServices.cloudflaredTunnel.cloudflareService.listZones(integration: integration)
            } catch {
                self.error = error.localizedDescription
            }
            isLoadingZones = false
        }
    }

    private func checkAvailability() {
        checkTask?.cancel()

        guard let zone = selectedZone,
              let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey,
              !subdomain.isEmpty else {
            availability = .unchecked
            return
        }

        do {
            try CloudflareTunnel.validateSubdomain(subdomain)
        } catch {
            availability = .invalid
            return
        }

        availability = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            let hostname = "\(subdomain).\(zone.name)"
            do {
                let records = try await appServices.cloudflaredTunnel.cloudflareService.listDNSRecords(
                    zoneID: zone.id,
                    name: hostname,
                    email: email,
                    apiKey: apiKey
                )
                await MainActor.run {
                    availability = records.isEmpty ? .available : .taken
                }
            } catch {
                await MainActor.run {
                    availability = .available
                }
            }
        }
    }

    private func share() {
        guard let zone = selectedZone else { return }

        isSaving = true
        error = nil

        Task { @MainActor in
            do {
                _ = try await appServices.cloudflaredTunnel.addRoute(
                    project: project,
                    zone: zone,
                    subdomain: subdomain,
                    integration: integration
                )
                onSuccess()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}

private enum SubdomainAvailability: Equatable {
    case unchecked, checking, available, taken, invalid
}
