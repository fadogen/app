import SwiftUI

struct HoverableRowModifier: ViewModifier {
    @Binding var hoveredID: String?
    let versionID: String

    func body(content: Content) -> some View {
        content
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hoveredID == versionID ? Color.gray.opacity(0.1) : Color.clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            )
            .onHover { isHovered in
                withAnimation(.easeInOut(duration: 0.15)) {
                    hoveredID = isHovered ? versionID : nil
                }
            }
    }
}

extension View {

    func hoverableRow(hoveredID: Binding<String?>, versionID: String) -> some View {
        self.modifier(HoverableRowModifier(hoveredID: hoveredID, versionID: versionID))
    }
}
