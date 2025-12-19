import SwiftUI
import SwiftData

struct MailpitEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var appServices
    @Environment(\.modelContext) private var modelContext
    @Query private var mailpitConfigs: [MailpitConfig]

    @State private var smtpPort: String = "1025"
    @State private var uiPort: String = "8025"
    @State private var autoStart: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    private var config: MailpitConfig? {
        mailpitConfigs.first
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("SMTP Port")
                    TextField("SMTP Port", text: $smtpPort)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .onSubmit {
                            save()
                        }
                }

                HStack {
                    Text("Web UI Port")
                    TextField("Web UI Port", text: $uiPort)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .onSubmit {
                            save()
                        }
                }

                Toggle("Start automatically on app launch", isOn: $autoStart)
            } header: {
                Text("Configuration")
            } footer: {
                Text("SMTP port is for receiving emails (default 1025). Web UI port is proxied to mail.localhost (default 8025).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .navigationTitle("Edit Mailpit")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .alert("Invalid Configuration", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            if let config {
                smtpPort = "\(config.smtpPort)"
                uiPort = "\(config.uiPort)"
                autoStart = config.autoStart
            }
        }
    }

    private func save() {
        // Validate SMTP port
        let smtpPortNumber: Int
        do {
            smtpPortNumber = try PortValidator.validate(smtpPort, fieldName: "SMTP port")
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return
        }

        // Validate UI port
        let uiPortNumber: Int
        do {
            uiPortNumber = try PortValidator.validate(uiPort, fieldName: "Web UI port")
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return
        }

        // Ports must be different
        guard smtpPortNumber != uiPortNumber else {
            errorMessage = String(localized: "SMTP and Web UI ports must be different")
            showError = true
            return
        }

        // Update configuration
        Task {
            do {
                try await appServices.mailpit.updateConfig(
                    smtpPort: smtpPortNumber,
                    uiPort: uiPortNumber,
                    autoStart: autoStart
                )
                dismiss()
            } catch {
                await MainActor.run {
                    errorMessage = String(localized: "Failed to save changes: \(error.localizedDescription)")
                    showError = true
                }
            }
        }
    }
}

/// Sheet displaying environment variables for Laravel .env configuration
struct MailpitEnvironmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var mailpitConfigs: [MailpitConfig]

    private var config: MailpitConfig? {
        mailpitConfigs.first
    }

    private var envContent: String {
        let smtpPort = config?.smtpPort ?? 1025
        return """
        MAIL_MAILER=smtp
        MAIL_HOST=127.0.0.1
        MAIL_PORT=\(smtpPort)
        MAIL_USERNAME=null
        MAIL_PASSWORD=null
        MAIL_ENCRYPTION=null
        MAIL_FROM_ADDRESS="hello@example.com"
        MAIL_FROM_NAME="${APP_NAME}"
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add these variables to your Laravel .env file:")
                .font(.headline)

            ScrollView {
                Text(envContent)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(envContent, forType: .string)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500, height: 350)
        .navigationTitle("Mail Environment Variables")
    }
}
