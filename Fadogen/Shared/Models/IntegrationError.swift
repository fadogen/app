import Foundation

nonisolated enum IntegrationError: Error, LocalizedError {
    case invalidCredentials
    case capabilityNotSupported(IntegrationCapability)
    case notImplemented(String)
    case apiError(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid or missing credentials"
        case .capabilityNotSupported(let capability):
            return "This integration does not support \(capability.displayName)"
        case .notImplemented(let provider):
            return "\(provider) integration is not yet implemented"
        case .apiError(let message):
            return "API Error: \(message)"
        case .validationFailed(let reason):
            return "Validation failed: \(reason)"
        }
    }
}
