import SwiftUI

// MARK: - Integration Header Section

/// Displays integration logo, name and capability badges
struct IntegrationHeaderSection: View {
    let metadata: IntegrationMetadata
    let capabilities: [IntegrationCapability]

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                // Integration logo
                if !metadata.assetName.isEmpty {
                    Image(metadata.assetName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(metadata.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)

                    FlowLayout(spacing: 6) {
                        ForEach(capabilities, id: \.self) { capability in
                            CapabilityBadge(capability: capability)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Cloudflare Credentials Section

struct CloudflareCredentialsSection: View {
    @Binding var email: String
    @Binding var globalAPIKey: String
    let isDisabled: Bool

    var body: some View {
        Section("Cloudflare API Configuration") {
            TextField("Account Email", text: $email)
                .textContentType(.emailAddress)
                .disabled(isDisabled)

            SecureField("Global API Key", text: $globalAPIKey)
                .textContentType(.password)
                .disabled(isDisabled)
        }
    }
}

// MARK: - Bunny API Section

struct BunnyCredentialsSection: View {
    @Binding var apiKey: String
    let isDisabled: Bool

    var body: some View {
        Section("Bunny API Configuration") {
            SecureField("API Key", text: $apiKey)
                .textContentType(.password)
                .disabled(isDisabled)
        }
    }
}

// MARK: - Generic Token Section

struct TokenCredentialsSection: View {
    let displayName: String
    @Binding var token: String
    let isDisabled: Bool

    var body: some View {
        Section("\(displayName) API Configuration") {
            SecureField("API Token", text: $token)
                .textContentType(.password)
                .disabled(isDisabled)
        }
    }
}

// MARK: - Scaleway Credentials Section

struct ScalewayCredentialsSection: View {
    @Binding var accessKey: String
    @Binding var secretKey: String
    @Binding var region: ScalewayRegion
    let isDisabled: Bool

    var body: some View {
        Section("Scaleway Object Storage Configuration") {
            SecureField("Access Key", text: $accessKey)
                .textContentType(.password)
                .disabled(isDisabled)

            SecureField("Secret Key", text: $secretKey)
                .textContentType(.password)
                .disabled(isDisabled)

            Picker("Region", selection: $region) {
                ForEach(ScalewayRegion.allCases, id: \.self) { region in
                    Text(region.displayName).tag(region)
                }
            }
            .disabled(isDisabled)
        }
    }
}

// MARK: - Dropbox OAuth Section

struct DropboxCredentialsSection: View {
    @Binding var appKey: String
    @Binding var appSecret: String
    @Binding var authCode: String
    let isDisabled: Bool

    var body: some View {
        Section("Step 1: App Credentials") {
            TextField("App Key", text: $appKey)
                .disabled(isDisabled)

            SecureField("App Secret", text: $appSecret)
                .textContentType(.password)
                .disabled(isDisabled)

            Button {
                let url = DropboxService().authorizationURL(appKey: appKey)
                NSWorkspace.shared.open(url)
            } label: {
                Label("Authorize in Browser", systemImage: "safari")
            }
            .disabled(appKey.isEmpty || isDisabled)
        }

        Section("Step 2: Authorization Code") {
            TextField("Paste the code from Dropbox", text: $authCode)
                .disabled(isDisabled)
        }
    }
}

// MARK: - Validation Error Section

struct ValidationErrorSection: View {
    let error: String?

    var body: some View {
        if let error {
            Section {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Documentation Link Section

struct DocumentationLinkSection: View {
    let documentationURL: URL?

    var body: some View {
        Section {
            if let docURL = documentationURL {
                Link("Documentation", destination: docURL)
            }
        }
    }
}

// MARK: - Integration Form Toolbar

struct IntegrationFormToolbar: ToolbarContent {
    let isValidating: Bool
    let canSubmit: Bool
    let confirmTitle: LocalizedStringKey
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: onCancel)
        }

        ToolbarItem(placement: .confirmationAction) {
            Button(action: onConfirm) {
                if isValidating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(confirmTitle)
                }
            }
            .disabled(!canSubmit || isValidating)
        }
    }
}
