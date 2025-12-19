import SwiftUI
import SwiftData

struct PHPConfigEditSheet: View {
    let phpVersion: PHPVersion

    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var appServices

    @State private var uploadSize: String = ""
    @State private var memoryLimit: String = ""
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isLoading: Bool = false

    private let parser = PHPConfigParser()

    var body: some View {
        Form {
            Section {
                TextField("Max Upload Size (MB)", text: $uploadSize)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        save()
                    }

                TextField("Memory Limit (MB)", text: $memoryLimit)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        save()
                    }
            } header: {
                Text("PHP Runtime Configuration")
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .navigationTitle("PHP \(phpVersion.major) Configuration")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isLoading)
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    openConfigFolder()
                } label: {
                    Label("Open Config Folder", systemImage: "folder")
                }
                .help("Open configuration folder in Finder")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading)
            }
        }
        .alert("Configuration Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            loadConfiguration()
        }
    }

    private func loadConfiguration() {
        let iniPath = phpVersion.configPath.appendingPathComponent("php.ini")

        do {
            let config = try parser.parse(iniPath: iniPath)
            uploadSize = "\(config.uploadMaxFilesize)"
            memoryLimit = "\(config.memoryLimit)"
        } catch {
            // Use defaults if parsing fails
            uploadSize = "\(PHPConfig.default.uploadMaxFilesize)"
            memoryLimit = "\(PHPConfig.default.memoryLimit)"
            errorMessage = String(localized: "Could not load existing configuration. Using defaults: \(error.localizedDescription)")
            showError = true
        }
    }

    private func save() {
        // Validate inputs
        guard let uploadMB = Int(uploadSize), uploadMB >= 1 && uploadMB <= 8192 else {
            errorMessage = String(localized: "Upload size must be a number between 1 and 8192 MB")
            showError = true
            return
        }

        guard let memoryMB = Int(memoryLimit), memoryMB >= 1 && memoryMB <= 8192 else {
            errorMessage = String(localized: "Memory limit must be a number between 1 and 8192 MB")
            showError = true
            return
        }

        // Optional: Warn if memory limit is lower than upload size
        if memoryMB < uploadMB {
            errorMessage = String(localized: "Memory limit (\(memoryMB) MB) is lower than upload size (\(uploadMB) MB). This may cause issues with large file uploads.")
            showError = true
            return
        }

        isLoading = true

        // Check if PHP-FPM is running
        let isRunning = appServices.phpFPM.states[phpVersion.major] == .running

        // Update php.ini
        let iniPath = phpVersion.configPath.appendingPathComponent("php.ini")
        let config = PHPConfig(uploadMaxFilesize: uploadMB, memoryLimit: memoryMB)

        do {
            try parser.update(iniPath: iniPath, config: config)

            // Restart PHP-FPM if running to apply changes (async in background)
            if isRunning {
                appServices.phpFPM.restart(major: phpVersion.major)
            }

            // Dismiss immediately - restart happens in background
            isLoading = false
            dismiss()
        } catch {
            errorMessage = String(localized: "Failed to save configuration: \(error.localizedDescription)")
            showError = true
            isLoading = false
        }
    }

    private func openConfigFolder() {
        NSWorkspace.shared.open(phpVersion.configPath)
    }
}
