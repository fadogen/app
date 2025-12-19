import Foundation
import SwiftData
import OSLog

/// Shared state management for install/update/remove operations
protocol OperationManager: AnyObject, Sendable {

    var installingVersions: Set<String> { get set }
    var removingVersions: Set<String> { get set }
    var updatingVersions: Set<String> { get set }
    var operationProgress: [String: Double] { get set }
    var operationErrors: [String: String] { get set }

    static var logger: Logger { get }
}

extension OperationManager {

    func isOperationActive(for identifier: String) -> Bool {
        installingVersions.contains(identifier) ||
        removingVersions.contains(identifier) ||
        updatingVersions.contains(identifier)
    }

    var isAnyOperationActive: Bool {
        !installingVersions.isEmpty ||
        !removingVersions.isEmpty ||
        !updatingVersions.isEmpty
    }

    nonisolated func wrapProgress(
        identifier: String,
        progress: @escaping @Sendable (Double) -> Void
    ) -> @Sendable (Double) -> Void {
        return { [weak self] p in
            Task { @MainActor [identifier] in
                guard let self else { return }
                self.operationProgress[identifier] = p
            }
            progress(p)
        }
    }

    func markOperationStarted(identifier: String, type: OperationType) {
        switch type {
        case .install:
            installingVersions.insert(identifier)
        case .remove:
            removingVersions.insert(identifier)
        case .update:
            updatingVersions.insert(identifier)
        }
        operationProgress[identifier] = 0.0
        operationErrors[identifier] = nil
    }

    func markOperationCompleted(identifier: String, type: OperationType) {
        switch type {
        case .install:
            installingVersions.remove(identifier)
        case .remove:
            removingVersions.remove(identifier)
        case .update:
            updatingVersions.remove(identifier)
        }
        operationProgress[identifier] = nil
    }

    func storeOperationError(identifier: String, error: Error) {
        operationErrors[identifier] = error.localizedDescription
    }
}

enum OperationType {
    case install
    case remove
    case update
}
