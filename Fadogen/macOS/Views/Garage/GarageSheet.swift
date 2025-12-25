import SwiftUI
import SwiftData

/// Unified sheet for installing or editing Garage configuration
struct GarageSheet: View {
    let existingVersion: GarageVersion?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var appServices
    @Environment(\.modelContext) private var modelContext

    @State private var port: String = ""
    @State private var autoStart: Bool = true
    @State private var isProcessing = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var portConflict: String?

    private var isEditing: Bool {
        existingVersion != nil
    }

    /// Initialize for installation
    init() {
        self.existingVersion = nil
    }

    /// Initialize for editing
    init(editing garageVersion: GarageVersion) {
        self.existingVersion = garageVersion
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isEditing {
                    versionSection
                }

                configurationSection
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .navigationTitle(isEditing ? "Edit Garage" : "Install Garage")
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
                        submit()
                    } label: {
                        if isProcessing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(isEditing ? "Save" : "Install")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || isProcessing)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                initializeState()
            }
        }
        .frame(width: 400)
    }

    // MARK: - Sections

    @ViewBuilder
    private var versionSection: some View {
        Section {
            if let metadata = appServices.garage.availableMetadata {
                LabeledContent("Version", value: metadata.latest)
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading version information...")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var configurationSection: some View {
        Section {
            HStack {
                Text("S3 Port")
                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .onChange(of: port) {
                        checkPortConflict()
                    }
                    .onSubmit {
                        submit()
                    }
            }

            if let conflict = portConflict {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Port already used by \(conflict)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Start automatically on app launch", isOn: $autoStart)
        } header: {
            Text("Configuration")
        } footer: {
            Text("S3 API port. RPC will use port+1, Admin will use port+3.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        guard PortValidator.isValid(port) else { return false }
        if portConflict != nil { return false }
        if !isEditing && appServices.garage.availableMetadata == nil { return false }
        return true
    }

    private func initializeState() {
        if let version = existingVersion {
            port = "\(version.s3Port)"
            autoStart = version.autoStart
        } else {
            port = "3900"
            autoStart = true
        }
    }

    private func checkPortConflict() {
        guard PortValidator.isValid(port),
              let portNumber = Int(port) else {
            portConflict = nil
            return
        }

        portConflict = try? appServices.garage.detectPortConflict(port: portNumber)
    }

    private func submit() {
        if isEditing {
            saveChanges()
        } else {
            performInstall()
        }
    }

    private func performInstall() {
        guard let portNumber = Int(port) else { return }

        isProcessing = true

        Task {
            do {
                try await appServices.garage.install(
                    s3Port: portNumber,
                    autoStart: autoStart
                )

                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isProcessing = false
                }
            }
        }
    }

    private func saveChanges() {
        guard let garageVersion = existingVersion else { return }

        let portNumber: Int
        do {
            portNumber = try PortValidator.validate(port)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return
        }

        let portChanged = garageVersion.s3Port != portNumber
        garageVersion.autoStart = autoStart

        do {
            try modelContext.save()

            if portChanged {
                isProcessing = true
                Task {
                    do {
                        try await appServices.garage.updatePort(newPort: portNumber)
                        dismiss()
                    } catch {
                        errorMessage = String(localized: "Failed to update port: \(error.localizedDescription)")
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
