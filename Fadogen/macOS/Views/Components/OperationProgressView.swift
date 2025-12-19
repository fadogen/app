import SwiftUI

/// Reusable progress bar for long-running operations (install, update, remove)
struct OperationProgressView: View {
    let progress: Double
    let tint: Color

    init(progress: Double, tint: Color = .accentColor) {
        self.progress = progress
        self.tint = tint
    }

    var body: some View {
        ProgressView(value: progress, total: 1.0)
            .progressViewStyle(.linear)
            .frame(width: 80, height: 24)
            .tint(tint)
    }
}