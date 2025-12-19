import SwiftUI
import SwiftData
import os

private let logger = Logger(subsystem: "app.fadogen", category: "IntegrationSheet")

struct IntegrationSheet: View {
    let integrationType: IntegrationType
    let existingIntegration: Integration?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isValidating = false
    @State private var validationError: String?

    @State private var email: String
    @State private var globalAPIKey: String
    @State private var token: String
    @State private var apiKey: String
    @State private var accessKey: String
    @State private var secretKey: String
    @State private var scalewayRegion: ScalewayRegion
    @State private var dropboxAppKey: String
    @State private var dropboxAppSecret: String
    @State private var dropboxAuthCode: String

    private var isEditing: Bool {
        existingIntegration != nil
    }

    private var metadata: IntegrationMetadata {
        integrationType.metadata
    }

    private var capabilities: [IntegrationCapability] {
        if let integration = existingIntegration {
            return integration.capabilities
        }
        return metadata.defaultCapabilities
    }

    init(adding type: IntegrationType) {
        self.integrationType = type
        self.existingIntegration = nil
        _email = State(initialValue: "")
        _globalAPIKey = State(initialValue: "")
        _token = State(initialValue: "")
        _apiKey = State(initialValue: "")
        _accessKey = State(initialValue: "")
        _secretKey = State(initialValue: "")
        _scalewayRegion = State(initialValue: .paris)
        _dropboxAppKey = State(initialValue: "")
        _dropboxAppSecret = State(initialValue: "")
        _dropboxAuthCode = State(initialValue: "")
    }

    init(editing integration: Integration) {
        self.integrationType = integration.type
        self.existingIntegration = integration
        _email = State(initialValue: integration.credentials.email ?? "")
        _globalAPIKey = State(initialValue: integration.credentials.globalAPIKey ?? "")
        _token = State(initialValue: integration.credentials.token ?? "")
        _apiKey = State(initialValue: integration.credentials.apiKey ?? "")
        _accessKey = State(initialValue: integration.credentials.accessKey ?? "")
        _secretKey = State(initialValue: integration.credentials.secretKey ?? "")
        _scalewayRegion = State(initialValue: ScalewayRegion(rawValue: integration.credentials.scalewayRegion ?? "") ?? .paris)
        _dropboxAppKey = State(initialValue: integration.credentials.dropboxAppKey ?? "")
        _dropboxAppSecret = State(initialValue: integration.credentials.dropboxAppSecret ?? "")
        _dropboxAuthCode = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                IntegrationHeaderSection(
                    metadata: metadata,
                    capabilities: capabilities
                )

                credentialsSection

                ValidationErrorSection(error: validationError)
                DocumentationLinkSection(documentationURL: metadata.documentationURL?.localizedDocumentationURL())
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit \(metadata.displayName)" : "Add \(metadata.displayName)")
            .toolbar {
                IntegrationFormToolbar(
                    isValidating: isValidating,
                    canSubmit: canSubmit,
                    confirmTitle: isEditing ? "Save" : "Add",
                    onCancel: { dismiss() },
                    onConfirm: { save() }
                )
            }
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        switch metadata.authMethod {
        case .emailAndGlobalKey:
            CloudflareCredentialsSection(
                email: $email,
                globalAPIKey: $globalAPIKey,
                isDisabled: isValidating
            )
        case .apiKey:
            BunnyCredentialsSection(
                apiKey: $apiKey,
                isDisabled: isValidating
            )
        case .accessKeyAndSecret:
            ScalewayCredentialsSection(
                accessKey: $accessKey,
                secretKey: $secretKey,
                region: $scalewayRegion,
                isDisabled: isValidating
            )
        case .oauth2:
            DropboxCredentialsSection(
                appKey: $dropboxAppKey,
                appSecret: $dropboxAppSecret,
                authCode: $dropboxAuthCode,
                isDisabled: isValidating
            )
        case .bearerToken:
            TokenCredentialsSection(
                displayName: metadata.displayName,
                token: $token,
                isDisabled: isValidating
            )
        }
    }

    private var canSubmit: Bool {
        switch metadata.authMethod {
        case .emailAndGlobalKey:
            return !email.isEmpty && !globalAPIKey.isEmpty
        case .apiKey:
            return !apiKey.isEmpty
        case .accessKeyAndSecret:
            return !accessKey.isEmpty && !secretKey.isEmpty
        case .oauth2:
            if isEditing {
                return !dropboxAppKey.isEmpty && !dropboxAppSecret.isEmpty
            } else {
                return !dropboxAppKey.isEmpty && !dropboxAppSecret.isEmpty && !dropboxAuthCode.isEmpty
            }
        case .bearerToken:
            return !token.isEmpty
        }
    }

    private func save() {
        isValidating = true
        validationError = nil

        Task {
            do {
                let credentials = try await IntegrationValidationService.validate(
                    type: integrationType,
                    email: email,
                    globalAPIKey: globalAPIKey,
                    token: token,
                    apiKey: apiKey,
                    accessKey: accessKey,
                    secretKey: secretKey,
                    scalewayRegion: scalewayRegion,
                    dropboxAppKey: dropboxAppKey,
                    dropboxAppSecret: dropboxAppSecret,
                    dropboxAuthCode: dropboxAuthCode,
                    dropboxRefreshToken: existingIntegration?.credentials.dropboxRefreshToken ?? "",
                    isEditMode: isEditing
                )

                await MainActor.run {
                    if let existing = existingIntegration {
                        existing.credentials = credentials
                    } else {
                        let integration = Integration(
                            type: integrationType,
                            credentials: credentials
                        )
                        modelContext.insert(integration)
                    }

                    do {
                        try modelContext.save()
                        dismiss()
                    } catch {
                        validationError = "Failed to save: \(error.localizedDescription)"
                        isValidating = false
                    }
                }
            } catch {
                logger.error("Validation error: \(error)")
                await MainActor.run {
                    validationError = "Validation failed: \(error.localizedDescription)"
                    isValidating = false
                }
            }
        }
    }
}
