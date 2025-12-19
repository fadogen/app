// Service lifecycle state management

import Foundation
import SwiftUI

enum ServiceState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case error(String)

    var isActive: Bool {
        self == .starting || self == .running || self == .stopping
    }

    var displayText: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .running: return "Running"
        case .stopping: return "Stopping..."
        case .error(let message): return "Error: \(message)"
        }
    }

    var showSpinner: Bool {
        self == .starting || self == .stopping
    }

    var statusColor: Color {
        switch self {
        case .stopped: return .secondary
        case .starting, .stopping: return .secondary
        case .running: return .green
        case .error: return .red
        }
    }
}
