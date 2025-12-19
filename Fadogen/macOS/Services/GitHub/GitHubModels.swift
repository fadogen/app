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
