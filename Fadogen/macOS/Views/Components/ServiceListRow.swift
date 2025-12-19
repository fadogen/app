import SwiftUI

/// Simplified row for master list in master-detail navigation
/// Shows only: service name, status, and port
/// Used in DatabasesView and CachesView for Liquid Glass design
/// "Dumb" component - receives all state as parameters (follows PHPVersionRow pattern)
struct ServiceListRow: View {
    let version: DisplayServiceVersion
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Service name and version (with update indicator if available)
            serviceNameView

            Spacer()

            // Status indicator
            Circle()
                .fill(isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            Text(isRunning ? "Running" : "Stopped")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Port badge
            Text(String(version.port))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())

            // Chevron (navigation indicator)
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    // MARK: - Private Views

    @ViewBuilder
    private var serviceNameView: some View {
        if version.hasUpdate, let minor = version.minor {
            HStack(spacing: 4) {
                Text("\(version.serviceType.displayName) \(version.major)")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text("(\(minor) → \(version.latestAvailable))")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } else {
            Text("\(version.serviceType.displayName) \(version.major)")
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Display Model

struct DisplayServiceVersion: Identifiable, Hashable {
    let serviceType: ServiceType
    let major: String
    let minor: String?
    let latestAvailable: String
    let isInstalled: Bool
    let hasUpdate: Bool
    let port: Int
    let autoStart: Bool

    var id: String {
        "\(serviceType.rawValue)-\(major)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(serviceType)
        hasher.combine(major)
    }

    static func == (lhs: DisplayServiceVersion, rhs: DisplayServiceVersion) -> Bool {
        lhs.serviceType == rhs.serviceType && lhs.major == rhs.major
    }
}

// MARK: - Preview