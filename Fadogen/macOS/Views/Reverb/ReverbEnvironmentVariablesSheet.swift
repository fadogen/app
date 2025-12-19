import SwiftUI

/// Sheet displaying Reverb environment variables
/// Users can preview and copy .env configuration
struct ReverbEnvironmentVariablesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showCopiedConfirmation = false

    /// Reverb environment variables for Laravel projects
    private var environmentVariables: String {
        """
        REVERB_APP_ID=1001
        REVERB_APP_KEY=laravel-fadogen
        REVERB_APP_SECRET=secret
        REVERB_HOST="reverb.localhost"
        REVERB_PORT=443
        REVERB_SCHEME=https
        """
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment Variables")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Copy these variables to your .env file")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()

            // Environment variables display
            Text(environmentVariables)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .padding(24)

            Divider()

            // Footer with copy button
            HStack {
                Spacer()

                Button {
                    copyToClipboard()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showCopiedConfirmation ? "checkmark" : "doc.on.doc")
                            .font(.callout)
                        Text(showCopiedConfirmation ? "Copied!" : "Copy to Clipboard")
                            .font(.callout)
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .disabled(showCopiedConfirmation)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 500)
        .presentationSizing(.fitted)
    }

    // MARK: - Actions

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(environmentVariables, forType: .string)

        withAnimation(.easeInOut(duration: 0.2)) {
            showCopiedConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopiedConfirmation = false
            }
        }
    }
}

// MARK: - Preview