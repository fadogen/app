import Foundation
import OSLog
import CryptoKit
import System
import Subprocess

@Observable
final class LinodeService {

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "linode-service")
    private let apiBaseURL = "https://api.linode.com/v4"

    // MARK: - Token Validation

    func validateToken(apiToken: String) async throws {
        logger.info("Validating API token permissions...")

        // Check VPS permissions by listing instances (requires linodes:read_only)
        // Note: Linode requires page_size between 25-500
        logger.debug("Checking VPS permissions (linodes:read_only)...")
        let instancesURL = URL(string: "\(apiBaseURL)/linode/instances?page_size=25")!
        let instancesRequest = createRequest(url: instancesURL, method: "GET", apiToken: apiToken)
        let (instancesData, instancesResponse) = try await URLSession.shared.data(for: instancesRequest)
        try validateResponseWithData(instancesResponse, data: instancesData, endpoint: "GET /linode/instances")
        logger.info("VPS permissions validated")

        // Check DNS permissions by listing domains (requires domains:read_only)
        logger.debug("Checking DNS permissions (domains:read_only)...")
        let domainsURL = URL(string: "\(apiBaseURL)/domains?page_size=25")!
        let domainsRequest = createRequest(url: domainsURL, method: "GET", apiToken: apiToken)
        let (domainsData, domainsResponse) = try await URLSession.shared.data(for: domainsRequest)
        try validateResponseWithData(domainsResponse, data: domainsData, endpoint: "GET /domains")
        logger.info("DNS permissions validated")

        logger.info("API token is valid with required VPS and DNS permissions")
    }

    private func validateResponseWithData(_ response: URLResponse, data: Data, endpoint: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type for \(endpoint)")
            throw LinodeError.networkError(String(localized: "Invalid server response"))
        }

        logger.debug("[\(endpoint)] Response status: \(httpResponse.statusCode)")

        if (200...299).contains(httpResponse.statusCode) {
            return
        }

        // Log error response body
        if let errorBody = String(data: data, encoding: .utf8) {
            logger.error("[\(endpoint)] Error response: \(errorBody)")
        }

        switch httpResponse.statusCode {
        case 401:
            throw LinodeError.unauthorized
        case 403:
            throw LinodeError.apiError(String(localized: "Insufficient permissions for this operation"))
        case 400:
            // Parse Linode error response
            if let errorResponse = try? JSONDecoder().decode(LinodeErrorResponse.self, from: data),
               let firstError = errorResponse.errors.first {
                throw LinodeError.validation(firstError.reason)
            }
            throw LinodeError.validation(String(localized: "Bad request"))
        default:
            throw LinodeError.apiError(String(localized: "HTTP \(httpResponse.statusCode)"))
        }
    }

    // MARK: - Regions

    func listRegions(apiToken: String) async throws -> [LinodeRegion] {
        logger.info("Fetching available regions")

        let url = URL(string: "\(apiBaseURL)/regions")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(LinodeRegionsResponse.self, from: data, endpoint: "GET /regions")

        logger.info("Fetched \(decoded.data.count) regions")
        return decoded.data
    }

    // MARK: - Types

    func listTypes(apiToken: String) async throws -> [LinodeType] {
        logger.info("Fetching available types")

        let url = URL(string: "\(apiBaseURL)/linode/types")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(LinodeTypesResponse.self, from: data, endpoint: "GET /linode/types")

        logger.info("Fetched \(decoded.data.count) types")
        return decoded.data
    }

    // MARK: - Images

    func listImages(apiToken: String) async throws -> [LinodeImage] {
        logger.info("Fetching available images")

        let url = URL(string: "\(apiBaseURL)/images?page_size=500")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(LinodeImagesResponse.self, from: data, endpoint: "GET /images")

        logger.info("Fetched \(decoded.data.count) images")
        return decoded.data
    }

    func getLatestDebianImage(apiToken: String) async throws -> String {
        logger.info("Getting latest Debian image")

        let images = try await listImages(apiToken: apiToken)

        // Filter for Debian images from Linode (not deprecated)
        let debianImages = images.filter {
            $0.id.hasPrefix("linode/debian") && !$0.deprecated
        }

        // Sort by ID (linode/debian13 > linode/debian12) and take the latest
        guard let latestImage = debianImages.sorted(by: { $0.id > $1.id }).first else {
            logger.error("No Debian images found")
            throw LinodeError.apiError(String(localized: "No Debian image available"))
        }

        logger.info("Selected latest Debian image: \(latestImage.id)")
        return latestImage.id
    }

    // MARK: - SSH Keys

    func listSSHKeys(apiToken: String) async throws -> [LinodeSSHKey] {
        logger.info("Fetching SSH keys")

        let url = URL(string: "\(apiBaseURL)/profile/sshkeys")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(LinodeSSHKeysResponse.self, from: data, endpoint: "GET /profile/sshkeys")

        logger.info("Fetched \(decoded.data.count) SSH keys")
        return decoded.data
    }

    /// Returns existing key if duplicate, otherwise uploads new key
    func uploadSSHKey(label: String, sshKey: String, apiToken: String) async throws -> LinodeSSHKey {
        logger.info("Checking SSH key: \(label)")

        // Calculate fingerprint of the key to check for duplicates
        guard let fingerprint = calculateSSHFingerprint(sshKey) else {
            logger.error("Failed to calculate SSH key fingerprint")
            throw LinodeError.apiError(String(localized: "Invalid SSH public key format"))
        }

        logger.debug("Calculated fingerprint: \(fingerprint)")

        // List existing SSH keys to check for duplicates
        let existingKeys = try await listSSHKeys(apiToken: apiToken)

        // Check if a key with the same content already exists
        // Linode doesn't expose fingerprint, so we compare the actual key
        let normalizedKey = normalizeSSHKey(sshKey)
        if let existingKey = existingKeys.first(where: { normalizeSSHKey($0.sshKey) == normalizedKey }) {
            logger.info("SSH key already exists with ID: \(existingKey.id), reusing it")
            return existingKey
        }

        // Key doesn't exist, upload it
        logger.info("Uploading new SSH key: \(label)")

        let url = URL(string: "\(apiBaseURL)/profile/sshkeys")!
        let payload: [String: Any] = [
            "label": label,
            "ssh_key": sshKey
        ]

        var request = createRequest(url: url, method: "POST", apiToken: apiToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(LinodeSSHKey.self, from: data, endpoint: "POST /profile/sshkeys")

        logger.info("SSH key uploaded successfully with ID: \(decoded.id)")
        return decoded
    }

    // MARK: - Instances

    func createInstance(
        label: String,
        region: String,
        type: String,
        image: String,
        authorizedKeys: [String],
        apiToken: String
    ) async throws -> LinodeInstance {
        logger.info("Creating instance: \(label) in \(region) with type \(type)")
        logger.debug("Image: \(image), authorized_keys count: \(authorizedKeys.count)")

        // Generate a secure random password (required by Linode API even with SSH keys)
        let rootPassword = SecretGenerator.generatePassword()

        let url = URL(string: "\(apiBaseURL)/linode/instances")!
        let payload: [String: Any] = [
            "label": label,
            "region": region,
            "type": type,
            "image": image,
            "root_pass": rootPassword,
            "authorized_keys": authorizedKeys,
            "backups_enabled": false
        ]

        var request = createRequest(url: url, method: "POST", apiToken: apiToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        // Use enhanced validation with error body logging
        try validateResponseWithData(response, data: data, endpoint: "POST /linode/instances")

        let decoded = try decode(LinodeInstance.self, from: data, endpoint: "POST /linode/instances")

        logger.info("Instance created with ID: \(decoded.id), status: \(decoded.status)")
        return decoded
    }

    func getInstance(instanceID: Int, apiToken: String) async throws -> LinodeInstance {
        logger.info("Fetching instance: \(instanceID)")

        let url = URL(string: "\(apiBaseURL)/linode/instances/\(instanceID)")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(LinodeInstance.self, from: data, endpoint: "GET /linode/instances/\(instanceID)")

        logger.info("Instance fetched: ID \(decoded.id), status: \(decoded.status)")
        return decoded
    }

    func waitForInstanceRunning(
        instanceID: Int,
        apiToken: String,
        maxWaitTime: TimeInterval,
        logCallback: @Sendable (String) -> Void
    ) async throws -> LinodeInstance {
        logger.info("Waiting for instance \(instanceID) to become running...")

        let startTime = Date()
        let delaySeconds: UInt64 = 5

        while Date().timeIntervalSince(startTime) < maxWaitTime {
            let instance = try await getInstance(instanceID: instanceID, apiToken: apiToken)

            if instance.isRunning, instance.publicIPv4 != nil {
                logger.info("Instance \(instanceID) is running with IP: \(instance.publicIPv4!)")
                logCallback("Instance is running with IP: \(instance.publicIPv4!)")
                return instance
            }

            let elapsed = Int(Date().timeIntervalSince(startTime))
            logCallback("Instance status: \(instance.status) (waited \(elapsed)s)")
            logger.info("Instance status is '\(instance.status)', waiting...")

            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }

        logger.error("Instance \(instanceID) did not become running within \(maxWaitTime) seconds")
        throw LinodeError.timeout(String(localized: "Instance did not become running within the expected time"))
    }

    func deleteInstance(instanceID: Int, apiToken: String) async throws {
        logger.info("Deleting instance: \(instanceID)")

        let url = URL(string: "\(apiBaseURL)/linode/instances/\(instanceID)")!
        let request = createRequest(url: url, method: "DELETE", apiToken: apiToken)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, expectedStatus: 200)

        logger.info("Instance \(instanceID) deleted successfully")
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
        throw LinodeError.timeout(String(localized: "SSH service did not become available within the expected time"))
    }

    // MARK: - Private

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.error("❌ Failed to decode \(String(describing: type)) from \(endpoint)")
                logger.error("Response JSON: \(jsonString)")
            }
            logger.error("Decoding error: \(error.localizedDescription)")
            throw error
        }
    }

    private func calculateSSHFingerprint(_ publicKey: String) -> String? {
        let components = publicKey.components(separatedBy: " ")
        guard components.count >= 2 else { return nil }

        let base64Key = components[1]
        guard let keyData = Data(base64Encoded: base64Key) else { return nil }

        let digest = Insecure.MD5.hash(data: keyData)
        return digest.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private func normalizeSSHKey(_ key: String) -> String {
        let components = key.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ")
        guard components.count >= 2 else { return key }
        return "\(components[0]) \(components[1])"
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
            throw LinodeError.networkError(String(localized: "Invalid server response"))
        }

        logger.debug("Response status code: \(httpResponse.statusCode)")

        // Allow 2xx status codes or specific expected status
        if (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == expectedStatus {
            return
        }

        switch httpResponse.statusCode {
        case 401:
            logger.error("Unauthorized - invalid API token")
            throw LinodeError.unauthorized

        case 404:
            logger.error("Resource not found")
            throw LinodeError.notFound

        case 400:
            logger.error("Validation error")
            throw LinodeError.validation(String(localized: "Invalid request parameters"))

        case 429:
            logger.warning("Rate limited")
            throw LinodeError.rateLimited

        case 500...599:
            logger.error("Server error: \(httpResponse.statusCode)")
            throw LinodeError.serverError(String(localized: "Linode server error (HTTP \(httpResponse.statusCode))"))

        default:
            logger.error("Unexpected status code: \(httpResponse.statusCode)")
            throw LinodeError.apiError(String(localized: "HTTP \(httpResponse.statusCode)"))
        }
    }
}
