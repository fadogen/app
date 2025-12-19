import Foundation

enum ServerDeletionPhase: Sendable {
    case deletingGitHubSecrets
    case cleaningUpProjects
    case deletingCloudflare
    case deletingProvider
    case completed

    var localizedDescription: String {
        switch self {
        case .deletingGitHubSecrets:
            return "Deleting GitHub Actions secrets..."
        case .cleaningUpProjects:
            return "Removing DNS records..."
        case .deletingCloudflare:
            return "Deleting Cloudflare tunnel..."
        case .deletingProvider:
            return "Deleting server from provider..."
        case .completed:
            return "Deletion completed"
        }
    }
}

enum ServerDeletionError: Error, LocalizedError, Sendable {
    case cloudflareFailed(details: String)
    case providerFailed(details: String)
    case networkError(details: String)
    case unauthorized(service: String)
    case unknown(details: String)

    var errorDescription: String? {
        switch self {
        case .cloudflareFailed(let details):
            return "Failed to delete Cloudflare tunnel: \(details)"
        case .providerFailed(let details):
            return "Failed to delete server from provider: \(details)"
        case .networkError(let details):
            return "Network error: \(details)"
        case .unauthorized(let service):
            return "Authentication failed for \(service). Please check your credentials."
        case .unknown(let details):
            return "An unexpected error occurred: \(details)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .cloudflareFailed:
            return "The tunnel will remain accessible in Integrations > Cloudflare for manual cleanup. You can delete the server anyway or retry after checking your API credentials."
        case .providerFailed:
            return "Check your provider API token and try again. The server may need to be deleted manually from the provider's control panel."
        case .networkError:
            return "Check your internet connection and try again."
        case .unauthorized:
            return "Update your API credentials in the provider settings and try again."
        case .unknown:
            return "Try again or contact support if the problem persists."
        }
    }
}
