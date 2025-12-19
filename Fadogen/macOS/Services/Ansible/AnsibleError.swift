import Foundation

enum AnsibleError: LocalizedError {
    case playbookNotFound(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .playbookNotFound(let path):
            return String(localized: "Playbook not found: \(path)")
        case .executionFailed(let message):
            return String(localized: "Ansible execution failed: \(message)")
        }
    }
}
