import Foundation

// MARK: - GitHub User

struct GitHubUser: Codable, Sendable {
    let login: String
    let id: Int
    let name: String?
    let email: String?
}

// MARK: - GitHub Repository

struct GitHubRepository: Codable, Sendable {
    let id: Int
    let name: String
    let fullName: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case fullName = "full_name"
    }
}

// MARK: - GitHub Commit

struct GitHubCommit: Codable, Sendable {
    let sha: String
}

// MARK: - GitHub Actions Secrets

struct GitHubPublicKey: Codable, Sendable {
    let keyId: String
    let key: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case key
    }
}

// MARK: - GitHub Workflow

struct GitHubWorkflow: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let name: String
    let path: String
    let state: String  // "active", "disabled_manually", etc.
}

struct GitHubWorkflowsResponse: Codable, Sendable {
    let workflows: [GitHubWorkflow]
}

// MARK: - GitHub Workflow Run

struct GitHubWorkflowRun: Codable, Sendable, Identifiable {
    let id: Int
    let name: String?
    let displayTitle: String?
    let workflowId: Int
    let headSha: String?     // Commit SHA that triggered this run
    let status: String       // "queued", "in_progress", "completed"
    let conclusion: String?  // "success", "failure", "cancelled", null
    let createdAt: Date
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case displayTitle = "display_title"
        case workflowId = "workflow_id"
        case headSha = "head_sha"
        case createdAt = "created_at"
        case htmlUrl = "html_url"
    }

    /// Returns display_title if available, otherwise falls back to name
    var title: String {
        displayTitle ?? name ?? "Workflow Run"
    }
}

struct GitHubWorkflowRunsResponse: Codable, Sendable {
    let workflowRuns: [GitHubWorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}
