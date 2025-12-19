import SwiftUI
import SwiftData

/// Unified sheet for adding or editing a service version
struct ServiceSheet: View {
    let serviceTypes: [ServiceType]
    let existingVersion: ServiceVersion?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var appServices
    @Environment(\.modelContext) private var modelContext
    @Query private var installedServices: [ServiceVersion]

    @State private var selectedService: ServiceType
    @State private var selectedMajor: String = ""
    @State private var port: String = ""
    @State private var autoStart: Bool = false
    @State private var isProcessing = false
    @State private var showError = false
    @State private var errorMessage = ""

    private var isEditing: Bool {
        existingVersion != nil
    }

    /// Initialize for adding a new service
    init(adding serviceTypes: [ServiceType]) {
        self.serviceTypes = serviceTypes
        self.existingVersion = nil
        _selectedService = State(initialValue: serviceTypes.first ?? .mariadb)
    }

    /// Initialize for editing an existing service
    init(editing serviceVersion: ServiceVersion) {
        self.serviceTypes = []
        self.existingVersion = serviceVersion
        _selectedService = State(initialValue: serviceVersion.serviceType)
    }

    var body: some View {
        NavigationStack {
            content
                .formStyle(.grouped)
                .navigationTitle(navigationTitle)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isProcessing)
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            if !isEditing && allServicesInstalled {
                                dismiss()
                            } else {
                                submit()
                            }
                        } label: {
                            if isProcessing {
                                ProgressView()
                                    .controlSize(.small)
                            } else if !isEditing && allServicesInstalled {
                                Text("OK")
                            } else {
                                Text(isEditing ? "Save" : "Add")
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit && !allServicesInstalled || isProcessing)
                    }
                }
                .alert(String(localized: "Error"), isPresented: $showError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage)
                }
                .onAppear {
                    initializeState()
                }
                .onChange(of: selectedService) { _, _ in
                    if !isEditing {
                        updateDefaults()
                    }
                }
                .onChange(of: installedServices.count) { _, _ in
                    if !isEditing {
                        updateDefaults()
                    }
                }
        }
        .frame(width: 400)
    }

    // MARK: - Content

    private var navigationTitle: String {
        if isEditing, let version = existingVersion {
            return String(localized: "Edit \(version.serviceType.displayName) \(version.major)")
        }
        return String(localized: "Add Service")
    }

    @ViewBuilder
    private var content: some View {
        if !isEditing && allServicesInstalled {
            allInstalledView
        } else {
            Form {
                if !isEditing {
                    serviceSelectionSection
                }
                configurationSection
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var allInstalledView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("All services installed")
                .font(.title3)
                .fontWeight(.medium)

            Text("All available services and versions are already installed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    @ViewBuilder
    private var serviceSelectionSection: some View {
        Section {
            Picker("Service", selection: $selectedService) {
                ForEach(pickerServiceTypes, id: \.self) { service in
                    Text(service.displayName).tag(service)
                }
            }

            Picker("Version", selection: $selectedMajor) {
                if selectedMajor.isEmpty {
                    Text("Select a version").tag("")
                }
                ForEach(pickerVersions, id: \.self) { version in
                    Text(version).tag(version)
                }
            }
            .disabled(availableVersions.isEmpty)
        }
    }

    @ViewBuilder
    private var configurationSection: some View {
        Section {
            HStack {
                Text("Port")
                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .onSubmit {
                        submit()
                    }
            }

            if let conflict = portConflict {
                Label(String(localized: "Port already used by \(conflict)"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            Toggle("Start automatically on app launch", isOn: $autoStart)
        } header: {
            Text("Configuration")
        } footer: {
            Text("Port must be between 1024 and 65535.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Computed Properties

    private var allServicesInstalled: Bool {
        availableServiceTypes.isEmpty
    }

    private var availableServiceTypes: [ServiceType] {
        serviceTypes.filter { serviceType in
            if serviceType.isSingleInstallation {
                return !installedServices.contains { $0.serviceType == serviceType }
            }

            guard let metadata = appServices.services.availableServices[serviceType.rawValue] else {
                return false
            }
            let allVersions = Set(metadata.keys)
            let installedVersions = Set(installedServices
                .filter { $0.serviceType == serviceType }
                .map { $0.major })
            return !installedVersions.isSuperset(of: allVersions)
        }
    }

    private var pickerServiceTypes: [ServiceType] {
        availableServiceTypes.contains(selectedService)
            ? availableServiceTypes
            : availableServiceTypes + [selectedService]
    }

    private var availableVersions: [String] {
        guard let metadata = appServices.services.availableServices[selectedService.rawValue] else {
            return []
        }

        if selectedService.isSingleInstallation {
            let hasAnyInstalled = installedServices.contains { $0.serviceType == selectedService }
            return hasAnyInstalled ? [] : Array(metadata.keys).sorted(by: >)
        }

        let allVersions = Set(metadata.keys)
        let installedVersions = Set(installedServices
            .filter { $0.serviceType == selectedService }
            .map { $0.major })
        return allVersions.subtracting(installedVersions).sorted(by: >)
    }

    private var pickerVersions: [String] {
        availableVersions.contains(selectedMajor) || selectedMajor.isEmpty
            ? availableVersions
            : availableVersions + [selectedMajor]
    }

    private var portConflict: String? {
        guard !isEditing else { return nil }
        guard let portNumber = Int(port) else { return nil }
        return try? appServices.services.detectPortConflict(port: portNumber)
    }

    private var canSubmit: Bool {
        if isEditing {
            return PortValidator.isValid(port)
        }
        return !selectedMajor.isEmpty && PortValidator.isValid(port)
    }

    // MARK: - Actions

    private func initializeState() {
        if let version = existingVersion {
            port = "\(version.port)"
            autoStart = version.autoStart
        } else {
            updateDefaults()
        }
    }

    private func updateDefaults() {
        if !availableServiceTypes.contains(selectedService),
           let firstAvailableService = availableServiceTypes.first {
            selectedService = firstAvailableService
        }

        if let firstVersion = availableVersions.first {
            selectedMajor = firstVersion
        } else {
            selectedMajor = ""
        }

        if let suggestedPort = try? appServices.services.suggestPort(for: selectedService) {
            port = String(suggestedPort)
        }
    }

    private func submit() {
        if isEditing {
            saveChanges()
        } else {
            performInstall()
        }
    }

    private func performInstall() {
        let portNumber: Int
        do {
            portNumber = try PortValidator.validate(port)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return
        }

        isProcessing = true

        Task {
            do {
                try await appServices.services.install(
                    service: selectedService,
                    major: selectedMajor,
                    port: portNumber,
                    autoStart: autoStart
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
                isProcessing = false
            }
        }
    }

    private func saveChanges() {
        guard let serviceVersion = existingVersion else { return }

        let portNumber: Int
        do {
            portNumber = try PortValidator.validate(port)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return
        }

        let serviceType = serviceVersion.serviceType
        let isRunning = appServices.serviceProcesses.isRunning(
            service: serviceType,
            major: serviceVersion.major
        )
        let portChanged = serviceVersion.port != portNumber

        serviceVersion.port = portNumber
        serviceVersion.autoStart = autoStart

        do {
            try modelContext.save()

            if isRunning && portChanged {
                isProcessing = true
                Task {
                    do {
                        try await appServices.serviceProcesses.restart(
                            service: serviceType,
                            major: serviceVersion.major,
                            port: portNumber
                        )
                        dismiss()
                    } catch {
                        errorMessage = String(localized: "Failed to restart service: \(error.localizedDescription)")
                        showError = true
                        isProcessing = false
                    }
                }
            } else {
                dismiss()
            }
        } catch {
            errorMessage = String(localized: "Failed to save changes: \(error.localizedDescription)")
            showError = true
        }
    }
}
