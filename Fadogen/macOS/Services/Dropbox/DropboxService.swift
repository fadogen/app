import Foundation

// MARK: - Dropbox Error

enum DropboxError: Error, LocalizedError {
    case invalidCredentials
    case tokenExpired
    case requestFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid Dropbox credentials"
        case .tokenExpired:
            return "Dropbox token expired"
        case .requestFailed(let statusCode, let message):
            return "Request failed (\(statusCode)): \(message)"
        }
    }
}

// MARK: - Dropbox Service

final class DropboxService {

    // MARK: - Public

    func authorizationURL(appKey: String) -> URL {
        URL(string: "https://www.dropbox.com/oauth2/authorize?client_id=\(appKey)&token_access_type=offline&response_type=code")!
    }

    func exchangeCodeForRefreshToken(code: String, appKey: String, appSecret: String) async throws -> String {
        guard let url = URL(string: "https://api.dropbox.com/oauth2/token") else {
            throw DropboxError.invalidCredentials
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=authorization_code&code=\(code)&client_id=\(appKey)&client_secret=\(appSecret)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DropboxError.requestFailed(statusCode: 0, message: "Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
                throw DropboxError.invalidCredentials
            }
            throw DropboxError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        struct TokenResponse: Decodable {
            let refresh_token: String
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        return tokenResponse.refresh_token
    }

    func validateCredentials(appKey: String, appSecret: String, refreshToken: String) async throws {
        // 1. Exchange refresh token for access token
        let accessToken = try await getAccessToken(
            appKey: appKey,
            appSecret: appSecret,
            refreshToken: refreshToken
        )

        // 2. Validate by calling /users/get_current_account
        try await getCurrentAccount(accessToken: accessToken)
    }

    // MARK: - Private

    private func getAccessToken(appKey: String, appSecret: String, refreshToken: String) async throws -> String {
        guard let url = URL(string: "https://api.dropbox.com/oauth2/token") else {
            throw DropboxError.invalidCredentials
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(appKey)&client_secret=\(appSecret)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DropboxError.requestFailed(statusCode: 0, message: "Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
                throw DropboxError.invalidCredentials
            }
            throw DropboxError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        struct TokenResponse: Decodable {
            let access_token: String
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        return tokenResponse.access_token
    }

    private func getCurrentAccount(accessToken: String) async throws {
        guard let url = URL(string: "https://api.dropboxapi.com/2/users/get_current_account") else {
            throw DropboxError.invalidCredentials
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DropboxError.requestFailed(statusCode: 0, message: "Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 401 {
                throw DropboxError.tokenExpired
            }
            throw DropboxError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }
    }
}
