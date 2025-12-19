import SwiftUI

/// Dialog shown when outdated service versions are detected before project creation
struct VersionCheckView: View {
    @Binding var isPresented: Bool
    @Binding var versionCheckResult: VersionCheckResult
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Updates Available")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Some services have newer versions available. Select which to install before creating your project.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            // Service list
            VStack(alignment: .leading, spacing: 12) {
                if let db = versionCheckResult.databaseStatus, db.needsUpgrade {
                    serviceRow(
                        name: db.displayName,
                        installed: db.installedMajor ?? "?",
                        recommended: db.recommendedMajor,
                        isSelected: Binding(
                            get: { versionCheckResult.databaseStatus?.shouldUpgrade ?? false },
                            set: { versionCheckResult.databaseStatus?.shouldUpgrade = $0 }
                        )
                    )
                }

                if let cache = versionCheckResult.cacheStatus, cache.needsUpgrade {
                    serviceRow(
                        name: cache.displayName,
                        installed: cache.installedMajor ?? "?",
                        recommended: cache.recommendedMajor,
                        isSelected: Binding(
                            get: { versionCheckResult.cacheStatus?.shouldUpgrade ?? false },
                            set: { versionCheckResult.cacheStatus?.shouldUpgrade = $0 }
                        )
                    )
                }

                if let node = versionCheckResult.nodeStatus, node.needsUpgrade {
                    serviceRow(
                        name: "Node.js",
                        installed: node.installedMajor ?? "?",
                        recommended: node.recommendedMajor,
                        isSelected: Binding(
                            get: { versionCheckResult.nodeStatus?.shouldUpgrade ?? false },
                            set: { versionCheckResult.nodeStatus?.shouldUpgrade = $0 }
                        )
                    )
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)

                Button("Continue") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(width: 450)
    }

    @ViewBuilder
    private func serviceRow(
        name: String,
        installed: String,
        recommended: String,
        isSelected: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isSelected) {
            HStack {
                Text(name)
                    .fontWeight(.medium)
                Spacer()
                Text(installed)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(recommended)
                    .foregroundStyle(.blue)
                    .fontWeight(.medium)
            }
        }
        .toggleStyle(.checkbox)
    }
}
