import SwiftUI

// MARK: - Basic Info Section

struct BasicInfoSection: View {
    @Binding var name: String
    @Binding var username: String
    @Binding var host: String
    @Binding var sshPort: String

    var body: some View {
        GroupBox {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Name")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "Optional"), text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(alignment: .center, spacing: 12) {
                    Text("Username")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    TextField("Required", text: $username)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(alignment: .center, spacing: 12) {
                    Text("Host")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    TextField("IP or domain", text: $host)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(alignment: .center, spacing: 12) {
                    Text("SSH Port")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    TextField("22", text: $sshPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                    Spacer()
                }
            }
            .padding(8)
        } label: {
            Text("Server Information")
                .font(.headline)
        }
    }
}

// MARK: - SSH Key Section

struct SSHKeySection: View {
    @Binding var selectedSSHKey: SSHKeyOption

    var body: some View {
        GroupBox {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Method")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)

                    Picker(selection: $selectedSSHKey) {
                        Text(SSHKeyOption.auto.displayName).tag(SSHKeyOption.auto)
                        Text(SSHKeyOption.custom.displayName).tag(SSHKeyOption.custom)
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300, alignment: .leading)

                    Spacer()
                }
            }
            .padding(8)
        } label: {
            Text("SSH Key Authentication")
                .font(.headline)
        }
    }
}

// MARK: - Custom SSH Key Input

struct CustomSSHKeyInput: View {
    @Binding var customSSHKeyContent: String

    var body: some View {
        GroupBox {
            VStack(spacing: 12) {
                HStack {
                    Text("Content")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)

                    Text("Paste your SSH private key below")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Spacer()
                }

                HStack(alignment: .top, spacing: 12) {
                    Spacer()
                        .frame(width: 80)

                    TextEditor(text: $customSSHKeyContent)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
            }
            .padding(8)
        } label: {
            Text("Private Key")
                .font(.headline)
        }
    }
}

// MARK: - Password Section

struct PasswordSection: View {
    @Binding var password: String

    var body: some View {
        GroupBox {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Password")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)

                    SecureField("Enter password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300, alignment: .leading)

                    Spacer()
                }
            }
            .padding(8)
        } label: {
            Text("Password Authentication")
                .font(.headline)
        }
    }
}

// MARK: - Sudo Password Section

/// Sudo password for privilege escalation on custom servers
struct SudoPasswordSection: View {
    @Binding var sudoPassword: String

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Password")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)

                    SecureField("Required for provisioning", text: $sudoPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300, alignment: .leading)

                    Spacer()
                }

                HStack(spacing: 12) {
                    Spacer()
                        .frame(width: 80)
                    Text("Required if not connecting as root. Used for sudo commands during server setup.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(8)
        } label: {
            Text("Sudo Access")
                .font(.headline)
        }
    }
}

// MARK: - Labeled Field Group Box

/// Reusable GroupBox with labeled field pattern (80pt label width)
struct LabeledFieldGroupBox<Content: View>: View {
    let title: String
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .frame(width: 80, alignment: .trailing)
                    .foregroundStyle(.secondary)

                content()
            }
            .padding(8)
        } label: {
            Text(title).font(.headline)
        }
    }
}

// MARK: - Selectable Card

/// Reusable card component for provider/custom server selection
struct SelectableCard: View {
    let icon: String
    let title: String
    let iconColor: Color
    let isAsset: Bool // true for asset image, false for SF Symbol

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 12) {
            // Icon
            if isAsset {
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(iconColor)
            }

            // Label
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 10 : 4, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Loading Button

/// Button content with loading state
struct LoadingButton: View {
    let title: String
    let loadingTitle: String
    let isLoading: Bool

    var body: some View {
        if isLoading {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(loadingTitle)
            }
        } else {
            Text(title)
        }
    }
}

// MARK: - Error Message View

/// Standardized error message display
struct ErrorMessageView: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .foregroundStyle(.red)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }
}
