import SwiftUI
import SwiftData
import AppKit

struct LocalURLEditSheet: View {
    @Bindable var project: LocalProject
    let onSave: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var hostname = ""
    @State private var suggestion: String?

    private var isValid: Bool {
        guard let sanitized = hostname.sanitizedHostname(), !sanitized.isEmpty else {
            return false
        }
        return suggestion == nil
    }

    private var previewURL: String {
        guard let sanitized = hostname.sanitizedHostname(), !sanitized.isEmpty else {
            return project.localURL
        }
        return "https://\(sanitized).localhost"
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Local URL")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    Text("https://")
                        .foregroundStyle(.secondary)
                    TextField("hostname", text: $hostname)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onChange(of: hostname) { _, newValue in
                            validateHostname(newValue)
                        }
                        .onSubmit {
                            if isValid { save() }
                        }
                    Text(".localhost")
                        .foregroundStyle(.secondary)
                }

                Button(previewURL) {
                    if let url = URL(string: previewURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)

                if let suggestion {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("URL already taken.")
                            .foregroundStyle(.secondary)
                        Button("Use \(suggestion)") {
                            hostname = suggestion
                            self.suggestion = nil
                        }
                        .buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            hostname = project.sanitizedName
        }
    }

    private func validateHostname(_ value: String) {
        guard let sanitized = value.sanitizedHostname(), !sanitized.isEmpty else {
            suggestion = nil
            return
        }

        let targetURL = "https://\(sanitized).localhost"

        // Same as current = OK
        if targetURL == project.localURL {
            suggestion = nil
            return
        }

        // Check if taken
        if modelContext.isLocalURLTaken(targetURL, excludingProjectID: project.id) {
            suggestion = modelContext.findUniqueHostname(sanitized, excludingProjectID: project.id)
        } else {
            suggestion = nil
        }
    }

    private func save() {
        guard let sanitized = hostname.sanitizedHostname(), !sanitized.isEmpty else { return }

        let newURL = "https://\(sanitized).localhost"
        guard !modelContext.isLocalURLTaken(newURL, excludingProjectID: project.id) else { return }

        project.localURL = newURL
        try? modelContext.save()
        onSave()
        dismiss()
    }
}
