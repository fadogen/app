import SwiftUI

/// Confirmation sheet when a renamed GitHub repository is detected
/// Shows old → new name and offers to update local .git/config
struct RepositoryRenamedSheet: View {
    let resolution: RepositoryResolution
    let isUpdating: Bool
    /// Optional - only provided if local project exists (can update git config)
    let onUpdateConfig: (() -> Void)?
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            // Title
            Text("Repository Renamed")
                .font(.headline)

            // Explanation
            VStack(spacing: 8) {
                Text("Your GitHub repository has been renamed:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(resolution.oldFullName)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)

                    Text(resolution.newFullName)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                .font(.callout)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(.fill.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Info about git remote update (only if local project exists)
            if onUpdateConfig != nil {
                Text("Would you like to update your local Git configuration?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // Command preview
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                    Text("git remote set-url origin \(resolution.newRemoteURL)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.fill.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("The deployment will continue with the new repository name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Buttons
            HStack(spacing: 12) {
                if let updateAction = onUpdateConfig {
                    Button("Not Now", role: .cancel) {
                        onSkip()
                    }
                    .disabled(isUpdating)

                    Button {
                        updateAction()
                    } label: {
                        if isUpdating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Updating...")
                            }
                        } else {
                            Text("Update Configuration")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isUpdating)
                } else {
                    Button("Continue") {
                        onSkip()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 400)
    }
}
