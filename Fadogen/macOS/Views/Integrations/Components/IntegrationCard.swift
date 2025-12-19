import SwiftUI

/// Card displaying an integration (configured or unconfigured)
struct IntegrationCard: View {
    let integration: Integration?
    let type: IntegrationType
    let isConfigured: Bool
    @State private var isHovered = false

    private var displayName: String {
        integration?.displayName ?? type.metadata.displayName
    }

    private var assetName: String {
        type.metadata.assetName
    }

    private var capabilities: [IntegrationCapability] {
        integration?.capabilities ?? type.metadata.defaultCapabilities
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with logo and name
            HStack(alignment: .top, spacing: 10) {
                // Integration logo/icon
                if !assetName.isEmpty {
                    Image(assetName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                } else {
                    Circle()
                        .fill(.blue.gradient)
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: type.metadata.iconName)
                                .foregroundStyle(.white)
                                .font(.system(size: 14))
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)

                    // Status indicator
                    HStack(spacing: 4) {
                        if isConfigured {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Configured")
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                            Text("Not configured")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }

                Spacer()
            }

            // Capabilities badges
            FlowLayout(spacing: 8) {
                ForEach(capabilities, id: \.self) { capability in
                    CapabilityBadge(capability: capability)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isConfigured ? .regularMaterial : .ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(
            color: .black.opacity(isConfigured ? 0.04 : 0.02),
            radius: isHovered ? 12 : (isConfigured ? 4 : 2),
            y: isHovered ? 6 : (isConfigured ? 2 : 1)
        )
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Simple FlowLayout for badges
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize
        var positions: [CGPoint]

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var positions: [CGPoint] = []
            var currentPosition: CGPoint = .zero
            var lineHeight: CGFloat = 0
            var maxX: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if currentPosition.x + size.width > maxWidth && currentPosition.x > 0 {
                    currentPosition.x = 0
                    currentPosition.y += lineHeight + spacing
                    lineHeight = 0
                }

                positions.append(currentPosition)
                currentPosition.x += size.width + spacing
                lineHeight = max(lineHeight, size.height)
                maxX = max(maxX, currentPosition.x - spacing)
            }

            self.positions = positions
            self.size = CGSize(width: maxX, height: currentPosition.y + lineHeight)
        }
    }
}
