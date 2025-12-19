import SwiftUI
import SwiftData

struct CaddyView: View {
    @Environment(AppServices.self) private var services

    @State private var isAtBottom = true
    @State private var errorAlert: String?

    private var caddyService: CaddyService { services.caddy }

    @ViewBuilder
    private var infoBar: some View {
        HStack {
            // Status indicator with spinner
            HStack(spacing: 8) {
                if caddyService.state.showSpinner {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Circle()
                        .fill(caddyService.state.statusColor)
                        .frame(width: 8, height: 8)
                }

                if case .error = caddyService.state {
                    Text("Error")
                        .font(.subheadline)
                        .foregroundStyle(.red)

                    Text("Please verify that ports 80 and 443 are available")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(caddyService.state.displayText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
        Group {
            if caddyService.logs.isEmpty {
                ContentUnavailableView(
                    "Empty Logs",
                    systemImage: "doc.text",
                    description: Text("Logs will appear here when Caddy is running")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(caddyService.logs.joined(separator: "\n"))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
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
                    .onChange(of: caddyService.logs) { _, _ in
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
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            logsArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Caddy Server")
        .toolbar {
            ToolbarSpacer(.flexible)

            // Clear logs button
            ToolbarItem(placement: .automatic) {
                Button {
                    caddyService.clearLogs()
                } label: {
                    Label("Clear Logs", systemImage: "eraser")
                }
                .disabled(caddyService.logs.isEmpty)
                .help("Clear all logs")
            }

            ToolbarSpacer(.flexible)

            // Start/Stop/Retry button
            ToolbarItem(placement: .automatic) {
                Button {
                    toggleCaddy()
                } label: {
                    if case .error = caddyService.state {
                        Label("Retry", systemImage: "arrow.clockwise")
                    } else {
                        Label(
                            caddyService.state == .running ? "Stop" : "Start",
                            systemImage: caddyService.state == .running ? "stop.fill" : "play.fill"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(caddyService.state == .running ? .red : nil)
                .keyboardShortcut(caddyService.state == .running ? "k" : "r", modifiers: .command)
                .disabled(caddyService.state.showSpinner)
                .help(caddyService.state == .running ? "Stop Caddy (⌘K)" : "Start Caddy (⌘R)")
            }
        }
        .alert("Caddy Error", isPresented: .constant(errorAlert != nil)) {
            Button("OK") { errorAlert = nil }
        } message: {
            if let error = errorAlert {
                Text(error)
            }
        }
    }

    private func toggleCaddy() {
        Task {
            do {
                switch caddyService.state {
                case .running:
                    await caddyService.stop()
                case .stopped, .error:
                    try await caddyService.start()
                default:
                    break
                }
            } catch {
                errorAlert = error.localizedDescription
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
