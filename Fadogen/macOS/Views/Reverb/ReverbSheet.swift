import SwiftUI
import SwiftData

/// Unified sheet for installing or editing Reverb configuration
struct ReverbSheet: View {
    let existingVersion: ReverbVersion?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var appServices
    @Environment(\.modelContext) private var modelContext

    @State private var port: String = ""
    @State private var autoStart: Bool = false
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
    init(editing reverbVersion: ReverbVersion) {
        self.existingVersion = reverbVersion
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
            .frame(width: 450)
            .navigationTitle(isEditing ? "Edit Reverb" : "Install Reverb")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isProcessing)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Install") {
                        submit()
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
    }

    // MARK: - Sections

    @ViewBuilder
    private var versionSection: some View {
        Section {
            if let metadata = appServices.reverb.availableMetadata {
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
                Text("Port")
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
            Text("Port must be between 1024 and 65535. Multiple services can share the same port if they don't run simultaneously.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        guard PortValidator.isValid(port) else { return false }
        if portConflict != nil { return false }
        if !isEditing && appServices.reverb.availableMetadata == nil { return false }
        return true
    }

    private func initializeState() {
        if let version = existingVersion {
            port = "\(version.port)"
            autoStart = version.autoStart
        } else {
            port = "8080"
            autoStart = false
        }
    }

    private func checkPortConflict() {
        guard PortValidator.isValid(port),
              let portNumber = Int(port) else {
            portConflict = nil
            return
        }

        portConflict = try? appServices.reverb.detectPortConflict(port: portNumber)
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
                try await appServices.reverb.install(
                    port: portNumber,
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
        guard let reverbVersion = existingVersion else { return }

        let portNumber: Int
        do {
            portNumber = try PortValidator.validate(port)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return
        }

        let portChanged = reverbVersion.port != portNumber
        reverbVersion.autoStart = autoStart

        do {
            try modelContext.save()

            if portChanged {
                isProcessing = true
                Task {
                    do {
                        try await appServices.reverb.updatePort(newPort: portNumber)
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
