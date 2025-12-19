import SwiftUI

/// Badge displaying an integration capability (VPS, DNS, TUNNEL)
struct CapabilityBadge: View {
    let capability: IntegrationCapability

    var body: some View {
        Text(capability.badgeLabel)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(capability.color.opacity(0.15))
            .foregroundStyle(capability.color)
            .clipShape(Capsule())
    }
}

#Preview {
    HStack(spacing: 8) {
        CapabilityBadge(capability: .vpsProvider)
        CapabilityBadge(capability: .dns)
        CapabilityBadge(capability: .tunnel)
    }
    .padding()
}
