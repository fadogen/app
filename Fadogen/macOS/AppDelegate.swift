// macOS Application Lifecycle Management

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Reference to services (injected by FadogenApp)
    var services: AppServices?

    /// Called when user attempts to quit the app (Cmd+Q or Quit from menu)
    /// Returns .terminateLater to allow async cleanup before app terminates
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await services?.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
