import Foundation

final class GitHubService {

    private let baseURL = "https://api.github.com"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Validation

    func validateToken(token: String) async throws -> GitHubUser {
        let endpoint = "/user"
        return try await makeRequest(
            endpoint: endpoint,
            method: "GET",
            token: token
        )
    }

    // MARK: - Secrets

    func getRepositoryPublicKey(owner: String, repo: String, token: String) async throws -> GitHubPublicKey {
        let endpoint = "/repos/\(owner)/\(repo)/actions/secrets/public-key"
        return try await makeRequest(
            endpoint: endpoint,
            method: "GET",
            token: token
        )
    }

    func createOrUpdateSecret(
        owner: String,
        repo: String,
        name: String,
        encryptedValue: String,
        keyId: String,
        token: String
    ) async throws {
        let endpoint = "/repos/\(owner)/\(repo)/actions/secrets/\(name)"

        let payload: [String: String] = [
            "encrypted_value": encryptedValue,
            "key_id": keyId
        ]

        let body = try JSONEncoder().encode(payload)

        try await makeRequestVoid(
            endpoint: endpoint,
            method: "PUT",
            body: body,
            token: token
        )
    }

    func deleteSecret(
        owner: String,
        repo: String,
        name: String,
        token: String
    ) async throws {
        let endpoint = "/repos/\(owner)/\(repo)/actions/secrets/\(name)"

        try await makeRequestVoid(
            endpoint: endpoint,
            method: "DELETE",
            token: token
        )
    }

    // MARK: - Variables

    func createOrUpdateVariable(
        owner: String,
        repo: String,
        name: String,
        value: String,
        token: String
    ) async throws {
        let payload: [String: String] = [
            "name": name,
            "value": value
        ]

        let body = try JSONEncoder().encode(payload)

        // Try PATCH first (update existing)
        let updateEndpoint = "/repos/\(owner)/\(repo)/actions/variables/\(name)"
        do {
            try await makeRequestVoid(
                endpoint: updateEndpoint,
                method: "PATCH",
                body: body,
                token: token
            )
        } catch GitHubError.notFound {
            // Variable doesn't exist, create it with POST
            let createEndpoint = "/repos/\(owner)/\(repo)/actions/variables"
            try await makeRequestVoid(
                endpoint: createEndpoint,
                method: "POST",
                body: body,
                token: token
            )
        }
    }

    func deleteVariable(
        owner: String,
        repo: String,
        name: String,
        token: String
    ) async throws {
        let endpoint = "/repos/\(owner)/\(repo)/actions/variables/\(name)"

        try await makeRequestVoid(
            endpoint: endpoint,
            method: "DELETE",
            token: token
        )
    }

    // MARK: - Repository Resolution

    /// Follows 301 redirect for renamed repos
    func resolveRepositoryByRedirect(
        owner: String,
        repo: String,
        token: String
    ) async throws -> String? {
        guard let url = URL(string: "\(baseURL)/repos/\(owner)/\(repo)") else {
            return nil
        }

        // Create a session that doesn't follow redirects automatically
        let config = URLSessionConfiguration.ephemeral
        let delegate = NoRedirectDelegate()
        let noRedirectSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { noRedirectSession.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30.0
        request.setValue("Fadogen/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await noRedirectSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        // Check for redirect (301 = renamed repo)
        if httpResponse.statusCode == 301,
           let location = httpResponse.value(forHTTPHeaderField: "Location"),
           let redirectURL = URL(string: location) {
            // Follow the redirect manually with our token
            var redirectRequest = URLRequest(url: redirectURL)
            redirectRequest.httpMethod = "GET"
            redirectRequest.timeoutInterval = 30.0
            redirectRequest.setValue("Fadogen/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            redirectRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, redirectResponse) = try await session.data(for: redirectRequest)

            guard let redirectHttpResponse = redirectResponse as? HTTPURLResponse,
                  redirectHttpResponse.statusCode == 200 else {
                return nil
            }

            let repoInfo = try JSONDecoder().decode(GitHubRepository.self, from: data)
            return repoInfo.name
        }

        return nil
    }

    private func listRepositories(owner: String, token: String) async throws -> [GitHubRepository] {
        let endpoint = "/user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator"
        let allRepos: [GitHubRepository] = try await makeRequest(
            endpoint: endpoint,
            method: "GET",
            token: token
        )

        return allRepos.filter { repo in
            repo.fullName.lowercased().hasPrefix(owner.lowercased() + "/")
        }
    }

    private func repositoryContainsCommit(
        owner: String,
        repo: String,
        commitSHA: String,
        token: String
    ) async throws -> Bool {
        let endpoint = "/repos/\(owner)/\(repo)/commits/\(commitSHA)"

        do {
            let _: GitHubCommit = try await makeRequest(
                endpoint: endpoint,
                method: "GET",
                token: token
            )
            return true
        } catch GitHubError.notFound {
            return false
        }
    }

    /// Fallback when redirect-based resolution fails (requires contents:read)
    func resolveRepositoryByCommit(
        owner: String,
        commitSHA: String,
        token: String
    ) async throws -> String? {
        let repos = try await listRepositories(owner: owner, token: token)

        for repo in repos {
            do {
                if try await repositoryContainsCommit(
                    owner: owner,
                    repo: repo.name,
                    commitSHA: commitSHA,
                    token: token
                ) {
                    return repo.name
                }
            } catch {
                // Skip repos we can't access (missing contents:read), continue searching
                continue
            }
        }

        return nil
    }

    // MARK: - Repository Management

    func checkRepositoryAvailability(owner: String, repoName: String, token: String) async throws -> Bool {
        let endpoint = "/repos/\(owner)/\(repoName)"

        do {
            let _: GitHubRepository = try await makeRequest(
                endpoint: endpoint,
                method: "GET",
                token: token
            )
            return false  // 200 = repo exists = taken
        } catch GitHubError.notFound {
            return true   // 404 = repo doesn't exist = available
        }
    }

    func createRepository(name: String, isPrivate: Bool, token: String) async throws -> GitHubRepository {
        let endpoint = "/user/repos"

        let payload: [String: Any] = [
            "name": name,
            "private": isPrivate
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        return try await makeRequest(
            endpoint: endpoint,
            method: "POST",
            body: body,
            token: token
        )
    }

    /// Get the commit SHA for a branch/ref
    func getCommitSHA(owner: String, repo: String, ref: String, token: String) async throws -> String {
        let endpoint = "/repos/\(owner)/\(repo)/commits/\(ref)"
        let commit: GitHubCommit = try await makeRequest(
            endpoint: endpoint,
            method: "GET",
            token: token
        )
        return commit.sha
    }

    func triggerWorkflowDispatch(
        owner: String,
        repo: String,
        workflow: String,
        ref: String,
        token: String
    ) async throws {
        let endpoint = "/repos/\(owner)/\(repo)/actions/workflows/\(workflow)/dispatches"
        let payload: [String: Any] = ["ref": ref]
        let body = try JSONSerialization.data(withJSONObject: payload)

        // POST returns 204 No Content on success
        _ = try await executeRequest(endpoint: endpoint, method: "POST", body: body, token: token)
    }

    // MARK: - Workflows

    /// List active workflows in a repository
    func listWorkflows(owner: String, repo: String, token: String) async throws -> [GitHubWorkflow] {
        let endpoint = "/repos/\(owner)/\(repo)/actions/workflows"
        let response: GitHubWorkflowsResponse = try await makeRequest(
            endpoint: endpoint,
            method: "GET",
            token: token
        )
        return response.workflows.filter { $0.state == "active" }
    }

    /// List recent workflow runs
    func listWorkflowRuns(owner: String, repo: String, perPage: Int = 10, token: String) async throws -> [GitHubWorkflowRun] {
        let endpoint = "/repos/\(owner)/\(repo)/actions/runs?per_page=\(perPage)"
        let data = try await executeRequest(endpoint: endpoint, method: "GET", token: token)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let response = try decoder.decode(GitHubWorkflowRunsResponse.self, from: data)
            return response.workflowRuns
        } catch {
            throw GitHubError.decodingFailed(error)
        }
    }

    // MARK: - Private

    private func executeRequest(
        endpoint: String,
        method: String,
        body: Data? = nil,
        token: String
    ) async throws -> Data {
        guard let url = URL(string: baseURL + endpoint) else {
            throw GitHubError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30.0
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Fadogen/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubError.invalidResponse
        }

        // Handle HTTP errors
        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401:
            throw GitHubError.unauthorized
        case 403:
            throw GitHubError.forbidden
        case 404:
            throw GitHubError.notFound
        default:
            throw GitHubError.apiError(statusCode: httpResponse.statusCode)
        }
    }

    private func makeRequest<T: Codable>(
        endpoint: String,
        method: String,
        body: Data? = nil,
        token: String
    ) async throws -> T {
        let data = try await executeRequest(endpoint: endpoint, method: method, body: body, token: token)

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.decodingFailed(error)
        }
    }

    private func makeRequestVoid(
        endpoint: String,
        method: String,
        body: Data? = nil,
        token: String
    ) async throws {
        _ = try await executeRequest(endpoint: endpoint, method: method, body: body, token: token)
    }
}

// MARK: - Errors

enum GitHubError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case apiError(statusCode: Int)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid GitHub API URL"
        case .invalidResponse:
            return "Invalid response from GitHub API"
        case .unauthorized:
            return "Unauthorized - Invalid or expired token"
        case .forbidden:
            return "Forbidden - Insufficient permissions"
        case .notFound:
            return "Resource not found"
        case .apiError(let statusCode):
            return "GitHub API error (HTTP \(statusCode))"
        case .decodingFailed(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}

// MARK: - URL Session Delegate

/// Prevents automatic redirect following to detect 301s for renamed repos
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Don't follow redirects - return nil to stop
        completionHandler(nil)
    }
}
