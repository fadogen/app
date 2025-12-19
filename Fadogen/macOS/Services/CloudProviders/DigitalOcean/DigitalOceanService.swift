import Foundation
import OSLog
import CryptoKit
import System
import Subprocess

@Observable
final class DigitalOceanService {

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "digitalocean-service")
    private let apiBaseURL = "https://api.digitalocean.com/v2"

    // MARK: - Regions

    func listRegions(apiToken: String) async throws -> [DORegion] {
        logger.info("Fetching available regions")

        let url = URL(string: "\(apiBaseURL)/regions")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(DORegionsResponse.self, from: data, endpoint: "GET /regions")
        let availableRegions = decoded.regions.filter { $0.available }

        logger.info("Fetched \(availableRegions.count) available regions")
        return availableRegions
    }

    // MARK: - Sizes

    func listSizes(apiToken: String) async throws -> [DOSize] {
        logger.info("Fetching available sizes")

        let url = URL(string: "\(apiBaseURL)/sizes")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(DOSizesResponse.self, from: data, endpoint: "GET /sizes")
        let availableSizes = decoded.sizes.filter { $0.available }

        logger.info("Fetched \(availableSizes.count) available sizes")
        return availableSizes
    }

    // MARK: - Images

    func listImages(apiToken: String) async throws -> [DOImage] {
        logger.info("Fetching available images")

        let url = URL(string: "\(apiBaseURL)/images?type=distribution&per_page=100")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(DOImagesResponse.self, from: data, endpoint: "GET /images")

        logger.info("Fetched \(decoded.images.count) images")
        return decoded.images
    }

    func getLatestDebianImage(apiToken: String) async throws -> String {
        logger.info("Getting latest Debian image")

        let images = try await listImages(apiToken: apiToken)

        // Filter for Debian distribution images
        let debianImages = images.filter {
            $0.distribution.lowercased() == "debian" && $0.type == "base"
        }

        // Sort by slug (debian-13-x64 > debian-12-x64) and take the latest
        guard let latestImage = debianImages
            .sorted(by: { $0.slug > $1.slug })
            .first else {
            logger.error("No Debian images found")
            throw DOError.apiError(String(localized: "No Debian image available"))
        }

        logger.info("Selected latest Debian image: \(latestImage.slug)")
        return latestImage.slug
    }

    // MARK: - SSH Keys

    func listSSHKeys(apiToken: String) async throws -> [DOSSHKey] {
        logger.info("Fetching SSH keys")

        let url = URL(string: "\(apiBaseURL)/account/keys")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(DOSSHKeysResponse.self, from: data, endpoint: "GET /account/keys")

        logger.info("Fetched \(decoded.sshKeys.count) SSH keys")
        return decoded.sshKeys
    }

    /// Returns existing key if fingerprint matches, otherwise uploads new key
    func uploadSSHKey(name: String, publicKey: String, apiToken: String) async throws -> DOSSHKey {
        logger.info("Checking SSH key: \(name)")

        // Calculate fingerprint of the key to check for duplicates
        guard let fingerprint = calculateSSHFingerprint(publicKey) else {
            logger.error("Failed to calculate SSH key fingerprint")
            throw DOError.apiError(String(localized: "Invalid SSH public key format"))
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

        let url = URL(string: "\(apiBaseURL)/account/keys")!
        let payload: [String: Any] = [
            "name": name,
            "public_key": publicKey
        ]

        var request = createRequest(url: url, method: "POST", apiToken: apiToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(DOSSHKeyResponse.self, from: data, endpoint: "POST /account/keys")

        logger.info("SSH key uploaded successfully with ID: \(decoded.sshKey.id)")
        return decoded.sshKey
    }

    // MARK: - Droplets

    func createDroplet(
        name: String,
        region: String,
        size: String,
        image: String,
        sshKeyIDs: [Int],
        apiToken: String
    ) async throws -> DODroplet {
        logger.info("Creating droplet: \(name) in \(region) with size \(size)")

        let url = URL(string: "\(apiBaseURL)/droplets")!
        let payload: [String: Any] = [
            "name": name,
            "region": region,
            "size": size,
            "image": image,
            "ssh_keys": sshKeyIDs,
            "backups": false,
            "ipv6": true,
            "monitoring": true
        ]

        var request = createRequest(url: url, method: "POST", apiToken: apiToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(DODropletResponse.self, from: data, endpoint: "POST /droplets")

        logger.info("Droplet created with ID: \(decoded.droplet.id), status: \(decoded.droplet.status)")
        return decoded.droplet
    }

    func getDroplet(dropletID: Int, apiToken: String) async throws -> DODroplet {
        logger.info("Fetching droplet: \(dropletID)")

        let url = URL(string: "\(apiBaseURL)/droplets/\(dropletID)")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(DODropletResponse.self, from: data, endpoint: "GET /droplets/\(dropletID)")

        logger.info("Droplet fetched: ID \(decoded.droplet.id), status: \(decoded.droplet.status)")
        return decoded.droplet
    }

    func waitForDropletActive(
        dropletID: Int,
        apiToken: String,
        maxAttempts: Int = 60,
        delaySeconds: UInt64 = 5
    ) async throws -> DODroplet {
        logger.info("Waiting for droplet \(dropletID) to become active...")

        for attempt in 1...maxAttempts {
            let droplet = try await getDroplet(dropletID: dropletID, apiToken: apiToken)

            if droplet.isActive, droplet.publicIPv4 != nil {
                logger.info("Droplet \(dropletID) is active with IP: \(droplet.publicIPv4!)")
                return droplet
            }

            logger.info("Attempt \(attempt)/\(maxAttempts): Droplet status is '\(droplet.status)', waiting...")
            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }

        logger.error("Droplet \(dropletID) did not become active after \(maxAttempts) attempts")
        throw DOError.timeout(String(localized: "Droplet did not become active within the expected time"))
    }

    func deleteDroplet(dropletID: Int, apiToken: String) async throws {
        logger.info("Deleting droplet: \(dropletID)")

        let url = URL(string: "\(apiBaseURL)/droplets/\(dropletID)")!
        let request = createRequest(url: url, method: "DELETE", apiToken: apiToken)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, expectedStatus: 204)

        logger.info("Droplet \(dropletID) deleted successfully")
    }

    func waitForSSHReady(
        host: String,
        port: Int = 22,
        maxAttempts: Int = 30,
        delaySeconds: UInt64 = 2
    ) async throws {
        logger.info("Waiting for SSH to be ready on \(host):\(port)...")

        for attempt in 1...maxAttempts {
            do {
                let result = try await run(
                    .path(FilePath("/usr/bin/nc")),
                    arguments: .init(["-z", "-w", "2", host, String(port)]),
                    output: .discarded,
                    error: .discarded
                )

                if result.terminationStatus.isSuccess {
                    logger.info("SSH is ready on \(host):\(port) after \(attempt) attempts")
                    return
                }
            } catch {
                logger.debug("SSH connection attempt \(attempt) failed: \(error.localizedDescription)")
            }

            logger.info("Attempt \(attempt)/\(maxAttempts): SSH not ready, waiting...")
            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }

        logger.error("SSH on \(host):\(port) did not become ready after \(maxAttempts) attempts")
        throw DOError.timeout(String(localized: "SSH service did not become available within the expected time"))
    }

    // MARK: - Private

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Log raw JSON response on decoding failure
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.error("❌ Failed to decode \(String(describing: type)) from \(endpoint)")
                logger.error("Response JSON: \(jsonString)")
            }
            logger.error("Decoding error: \(error.localizedDescription)")
            throw error
        }
    }

    /// Returns MD5 fingerprint in "xx:xx:xx:..." format
    private func calculateSSHFingerprint(_ publicKey: String) -> String? {
        // Extract the base64 part from "ssh-rsa AAAAB3NzaC1... comment"
        let components = publicKey.components(separatedBy: " ")
        guard components.count >= 2 else { return nil }

        let base64Key = components[1]
        guard let keyData = Data(base64Encoded: base64Key) else { return nil }

        // Calculate MD5 hash
        let digest = Insecure.MD5.hash(data: keyData)

        // Format as colon-separated hex pairs (DigitalOcean format)
        return digest.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private func createRequest(url: URL, method: String, apiToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    private func validateResponse(_ response: URLResponse, expectedStatus: Int = 200) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type")
            throw DOError.networkError(String(localized: "Invalid server response"))
        }

        logger.debug("Response status code: \(httpResponse.statusCode)")

        // Allow 2xx status codes or specific expected status
        if (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == expectedStatus {
            return
        }

        switch httpResponse.statusCode {
        case 401:
            logger.error("Unauthorized - invalid API token")
            throw DOError.unauthorized

        case 404:
            logger.error("Resource not found")
            throw DOError.notFound

        case 422:
            logger.error("Unprocessable entity - validation error or duplicate resource")
            throw DOError.unprocessableEntity

        case 429:
            logger.warning("Rate limited")
            throw DOError.rateLimited

        case 500...599:
            logger.error("Server error: \(httpResponse.statusCode)")
            throw DOError.serverError(String(localized: "DigitalOcean server error (HTTP \(httpResponse.statusCode))"))

        default:
            logger.error("Unexpected status code: \(httpResponse.statusCode)")
            throw DOError.apiError(String(localized: "HTTP \(httpResponse.statusCode)"))
        }
    }
}

// MARK: - Errors

enum DOError: LocalizedError {
    case unauthorized
    case rateLimited
    case notFound
    case unprocessableEntity
    case networkError(String)
    case serverError(String)
    case apiError(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Invalid DigitalOcean API token. Please check your integration.")
        case .rateLimited:
            return String(localized: "Rate limited by DigitalOcean. Please wait a moment and try again.")
        case .notFound:
            return String(localized: "Resource not found on DigitalOcean.")
        case .unprocessableEntity:
            return String(localized: "Validation error or duplicate resource on DigitalOcean.")
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
