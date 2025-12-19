import Foundation
import OSLog
import CryptoKit

@Observable
final class HetznerService {

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "hetzner-service")
    private let apiBaseURL = "https://api.hetzner.cloud/v1"

    // MARK: - Locations

    func listLocations(apiToken: String) async throws -> [HetznerLocation] {
        logger.info("Fetching available locations")

        let url = URL(string: "\(apiBaseURL)/locations")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(HetznerLocationsResponse.self, from: data, endpoint: "GET /locations")

        logger.info("Fetched \(decoded.locations.count) locations")
        return decoded.locations
    }

    // MARK: - Server Types

    func listServerTypes(apiToken: String) async throws -> [HetznerServerType] {
        logger.info("Fetching available server types")

        let url = URL(string: "\(apiBaseURL)/server_types")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(HetznerServerTypesResponse.self, from: data, endpoint: "GET /server_types")

        logger.info("Fetched \(decoded.serverTypes.count) server types")
        return decoded.serverTypes
    }

    // MARK: - Images

    func listImages(apiToken: String) async throws -> [HetznerImage] {
        logger.info("Fetching available images")

        let url = URL(string: "\(apiBaseURL)/images?type=system")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(HetznerImagesResponse.self, from: data, endpoint: "GET /images")

        logger.info("Fetched \(decoded.images.count) images")
        return decoded.images
    }

    func getLatestDebianImage(apiToken: String) async throws -> String {
        logger.info("Getting latest Debian image")

        let images = try await listImages(apiToken: apiToken)

        // Filter for Debian system images
        let debianImages = images.filter {
            $0.osFlavor == "debian" && $0.type == "system"
        }

        // Sort by version number (descending) and take the latest
        guard let latestImage = debianImages
            .sorted(by: {
                (Int($0.osVersion) ?? 0) > (Int($1.osVersion) ?? 0)
            })
            .first else {
            logger.error("No Debian images found")
            throw HetznerError.apiError(String(localized: "No Debian image available"))
        }

        logger.info("Selected latest Debian image: \(latestImage.name)")
        return latestImage.name
    }

    // MARK: - SSH Keys

    func listSSHKeys(apiToken: String) async throws -> [HetznerSSHKey] {
        logger.info("Fetching SSH keys")

        let url = URL(string: "\(apiBaseURL)/ssh_keys")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(HetznerSSHKeysResponse.self, from: data, endpoint: "GET /ssh_keys")

        logger.info("Fetched \(decoded.sshKeys.count) SSH keys")
        return decoded.sshKeys
    }

    /// Returns existing key if fingerprint matches, otherwise uploads new key
    func uploadSSHKey(name: String, publicKey: String, apiToken: String) async throws -> HetznerSSHKey {
        logger.info("Checking SSH key: \(name)")

        // Calculate fingerprint of the key to check for duplicates
        guard let fingerprint = calculateSSHFingerprint(publicKey) else {
            logger.error("Failed to calculate SSH key fingerprint")
            throw HetznerError.apiError(String(localized: "Invalid SSH public key format"))
        }

        logger.debug("Calculated fingerprint: \(fingerprint)")

        // List existing SSH keys to check for duplicates
        let existingKeys = try await listSSHKeys(apiToken: apiToken)

        // Check if a key with the same fingerprint already exists
        if let existingKey = existingKeys.first(where: { $0.fingerprint == fingerprint }) {
            logger.info("SSH key already exists with ID: \(existingKey.id), reusing it")
            return existingKey
        }

        // Key doesn't exist, upload it
        logger.info("Uploading new SSH key: \(name)")

        let url = URL(string: "\(apiBaseURL)/ssh_keys")!
        let payload: [String: Any] = [
            "name": name,
            "public_key": publicKey
        ]

        var request = createRequest(url: url, method: "POST", apiToken: apiToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(HetznerSSHKeyResponse.self, from: data, endpoint: "POST /ssh_keys")

        logger.info("SSH key uploaded successfully with ID: \(decoded.sshKey.id)")
        return decoded.sshKey
    }

    // MARK: - Servers

    func createServer(
        name: String,
        location: String,
        serverType: String,
        image: String,
        sshKeyIDs: [Int],
        apiToken: String
    ) async throws -> HetznerServer {
        logger.info("Creating server: \(name) in \(location) with type \(serverType)")

        let url = URL(string: "\(apiBaseURL)/servers")!
        let payload: [String: Any] = [
            "name": name,
            "location": location,
            "server_type": serverType,
            "image": image,
            "ssh_keys": sshKeyIDs,
            "start_after_create": true
        ]

        var request = createRequest(url: url, method: "POST", apiToken: apiToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(HetznerServerCreateResponse.self, from: data, endpoint: "POST /servers")

        logger.info("Server created with ID: \(decoded.server.id), status: \(decoded.server.status)")
        return decoded.server
    }

    func getServer(serverID: Int, apiToken: String) async throws -> HetznerServer {
        logger.info("Fetching server: \(serverID)")

        let url = URL(string: "\(apiBaseURL)/servers/\(serverID)")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(HetznerServerResponse.self, from: data, endpoint: "GET /servers/\(serverID)")

        logger.info("Server fetched: ID \(decoded.server.id), status: \(decoded.server.status)")
        return decoded.server
    }

    func deleteServer(serverID: Int, apiToken: String) async throws {
        logger.info("Deleting server: \(serverID)")

        let url = URL(string: "\(apiBaseURL)/servers/\(serverID)")!
        let request = createRequest(url: url, method: "DELETE", apiToken: apiToken)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        logger.info("Server \(serverID) deleted successfully")
    }

    // MARK: - Private

    private func createRequest(url: URL, method: String, apiToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validateResponse(_ response: URLResponse, expectedStatus: Int = 200) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HetznerError.networkError(String(localized: "Invalid response type"))
        }

        // For DELETE requests, accept 204 No Content
        let validStatuses = expectedStatus == 200 ? [200, 201] : [expectedStatus]

        guard validStatuses.contains(httpResponse.statusCode) else {
            let errorMessage = String(localized: "HTTP \(httpResponse.statusCode)")
            switch httpResponse.statusCode {
            case 401:
                throw HetznerError.unauthorized
            case 403:
                throw HetznerError.forbidden
            case 404:
                throw HetznerError.notFound
            case 422:
                throw HetznerError.unprocessableEntity
            case 429:
                throw HetznerError.rateLimited
            case 500...599:
                throw HetznerError.serverError(errorMessage)
            default:
                throw HetznerError.apiError(errorMessage)
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Log raw JSON response on decoding failure
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.error("Failed to decode \(endpoint) response: \(error.localizedDescription)")
                logger.debug("Raw JSON: \(jsonString)")
            }
            throw HetznerError.apiError(String(localized: "Failed to decode response: \(error.localizedDescription)"))
        }
    }

    /// Returns MD5 fingerprint in "xx:xx:xx:..." format (Hetzner format)
    private func calculateSSHFingerprint(_ publicKey: String) -> String? {
        // Extract the base64 part from "ssh-rsa AAAAB3NzaC1... comment"
        let components = publicKey.components(separatedBy: " ")
        guard components.count >= 2 else { return nil }

        let base64Key = components[1]
        guard let keyData = Data(base64Encoded: base64Key) else { return nil }

        // Calculate MD5 hash
        let digest = Insecure.MD5.hash(data: keyData)

        // Format as colon-separated hex pairs (Hetzner format)
        return digest.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

// MARK: - Errors

enum HetznerError: LocalizedError {
    case unauthorized
    case forbidden
    case notFound
    case unprocessableEntity
    case rateLimited
    case networkError(String)
    case serverError(String)
    case apiError(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Unauthorized: Invalid API token")
        case .forbidden:
            return String(localized: "Forbidden: Insufficient permissions")
        case .notFound:
            return String(localized: "Resource not found")
        case .unprocessableEntity:
            return String(localized: "Unprocessable entity: Invalid data provided")
        case .rateLimited:
            return String(localized: "Rate limit exceeded")
        case .networkError(let message):
            return String(localized: "Network error: \(message)")
        case .serverError(let message):
            return String(localized: "Server error: \(message)")
        case .apiError(let message):
            return String(localized: "API error: \(message)")
        case .timeout(let message):
            return String(localized: "Timeout: \(message)")
        }
    }
}
