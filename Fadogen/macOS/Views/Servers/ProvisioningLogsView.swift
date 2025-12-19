import SwiftUI

struct ProvisioningLogsView: View {
    let ansibleManager: AnsibleManager
    let onRetry: () -> Void

    @State private var isAtBottom = true

    private var isFailure: Bool {
        if case .completed(.failure) = ansibleManager.state {
            return true
        }
        return false
    }

    @ViewBuilder
    private var infoBar: some View {
        HStack {
            HStack(spacing: 8) {
                if case .running = ansibleManager.state {
                    ProgressView()
                        .controlSize(.small)
                } else if isFailure {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }

                // Display provisioningStatus if available (concise user-facing message)
                if !ansibleManager.provisioningStatus.isEmpty {
                    Text(ansibleManager.provisioningStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if case .running(let progress) = ansibleManager.state {
                    // Fallback to progress text if no status set
                    Text("Configuring server...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(progress)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else if case .completed(.failure(let error)) = ansibleManager.state {
                    Text("Configuration failed")
                        .font(.subheadline)
                        .foregroundStyle(.red)

                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background.secondary)

        Divider()
    }

    @ViewBuilder
    private var logsArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ansibleManager.logs.joined(separator: "\n"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(isFailure ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onScrollVisibilityChange(threshold: 0.9) { isVisible in
                            isAtBottom = isVisible
                        }
                }
                .padding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: ansibleManager.logs) { _, _ in
                scrollToBottom(proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        scrollToBottom(proxy)
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.blue, in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isAtBottom)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            logsArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            if isFailure {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}
