import Foundation

/// In-memory model for an active quick tunnel.
/// Not persisted to SwiftData - tunnels are lost when the app quits.
struct QuickTunnel: Identifiable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let publicURL: String
    let startedAt: Date

    init(projectID: UUID, publicURL: String) {
        self.id = UUID()
        self.projectID = projectID
        self.publicURL = publicURL
        self.startedAt = Date()
    }

    /// Hostname extracted from publicURL for display
    var hostname: String {
        URL(string: publicURL)?.host ?? publicURL
    }
}

/// State of a quick tunnel operation for a specific project.
enum QuickTunnelState: Equatable, Sendable {
    case idle
    case starting
    case running(QuickTunnel)
    case stopping
    case failed(String)

    var isActive: Bool {
        if case .running = self { return true }
        return false
    }

    var isTransitioning: Bool {
        switch self {
        case .starting, .stopping: return true
        default: return false
        }
    }
}

/// Errors that can occur when managing quick tunnels.
enum QuickTunnelError: LocalizedError {
    case operationInProgress
    case binaryNotFound
    case failedToParseURL
    case processExitedUnexpectedly(String)
    case tunnelAlreadyActive
    case timeout

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            String(localized: "Another operation is in progress")
        case .binaryNotFound:
            String(localized: "cloudflared binary not found")
        case .failedToParseURL:
            String(localized: "Failed to parse tunnel URL")
        case .processExitedUnexpectedly(let details):
            String(localized: "Tunnel process exited: \(details)")
        case .tunnelAlreadyActive:
            String(localized: "A quick tunnel is already active for this project")
        case .timeout:
            String(localized: "Tunnel startup timed out")
        }
    }
}
