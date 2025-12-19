import Foundation
import OSLog
import CryptoKit

@Observable
final class VultrService {

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "vultr-service")
    private let apiBaseURL = "https://api.vultr.com/v2"

    // MARK: - Token Validation

    func validateToken(apiToken: String) async throws {
        logger.info("Validating API token permissions...")

        // Check VPS permissions by listing instances
        logger.debug("Checking VPS permissions (instances)...")
        let instancesURL = URL(string: "\(apiBaseURL)/instances?per_page=1")!
        let instancesRequest = createRequest(url: instancesURL, method: "GET", apiToken: apiToken)
        let (instancesData, instancesResponse) = try await URLSession.shared.data(for: instancesRequest)
        try validateResponseWithData(instancesResponse, data: instancesData, endpoint: "GET /instances")
        logger.info("VPS permissions validated")

        // Check DNS permissions by listing domains
        logger.debug("Checking DNS permissions (domains)...")
        let domainsURL = URL(string: "\(apiBaseURL)/domains?per_page=1")!
        let domainsRequest = createRequest(url: domainsURL, method: "GET", apiToken: apiToken)
        let (domainsData, domainsResponse) = try await URLSession.shared.data(for: domainsRequest)
        try validateResponseWithData(domainsResponse, data: domainsData, endpoint: "GET /domains")
        logger.info("DNS permissions validated")

        logger.info("API token is valid with required VPS and DNS permissions")
    }

    private func validateResponseWithData(_ response: URLResponse, data: Data, endpoint: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type for \(endpoint)")
            throw VultrError.networkError(String(localized: "Invalid server response"))
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
            throw VultrError.unauthorized
        case 403:
            throw VultrError.apiError(String(localized: "Insufficient permissions for this operation"))
        case 400:
            // Parse Vultr error response
            if let errorResponse = try? JSONDecoder().decode(VultrErrorResponse.self, from: data) {
                throw VultrError.validation(errorResponse.error)
            }
            throw VultrError.validation(String(localized: "Bad request"))
        case 429:
            throw VultrError.rateLimited
        default:
            throw VultrError.apiError(String(localized: "HTTP \(httpResponse.statusCode)"))
        }
    }

    // MARK: - Regions

    func listRegions(apiToken: String) async throws -> [VultrRegion] {
        logger.info("Fetching available regions")

        let url = URL(string: "\(apiBaseURL)/regions")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(VultrRegionsResponse.self, from: data, endpoint: "GET /regions")

        logger.info("Fetched \(decoded.regions.count) regions")
        return decoded.regions
    }

    // MARK: - Plans

    func listPlans(apiToken: String) async throws -> [VultrPlan] {
        logger.info("Fetching available plans")

        let url = URL(string: "\(apiBaseURL)/plans?type=vc2")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(VultrPlansResponse.self, from: data, endpoint: "GET /plans")

        logger.info("Fetched \(decoded.plans.count) plans")
        return decoded.plans
    }

    // MARK: - OS Images

    func listOS(apiToken: String) async throws -> [VultrOS] {
        logger.info("Fetching available OS images")

        let url = URL(string: "\(apiBaseURL)/os")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(VultrOSResponse.self, from: data, endpoint: "GET /os")

        logger.info("Fetched \(decoded.os.count) OS images")
        return decoded.os
    }

    func getLatestDebianOS(apiToken: String) async throws -> Int {
        logger.info("Getting latest Debian OS")

        let allOS = try await listOS(apiToken: apiToken)

        // Filter for Debian images
        let debianImages = allOS.filter {
            $0.family.lowercased() == "debian"
        }

        // Sort by ID descending (newer versions have higher IDs typically)
        // and prefer the one with highest version number in name
        guard let latestOS = debianImages.sorted(by: { $0.id > $1.id }).first else {
            logger.error("No Debian images found")
            throw VultrError.apiError(String(localized: "No Debian image available"))
        }

        logger.info("Selected latest Debian OS: \(latestOS.name) (ID: \(latestOS.id))")
        return latestOS.id
    }

    // MARK: - SSH Keys

    func listSSHKeys(apiToken: String) async throws -> [VultrSSHKey] {
        logger.info("Fetching SSH keys")

        let url = URL(string: "\(apiBaseURL)/ssh-keys")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(VultrSSHKeysResponse.self, from: data, endpoint: "GET /ssh-keys")

        logger.info("Fetched \(decoded.sshKeys.count) SSH keys")
        return decoded.sshKeys
    }

    /// Returns existing key if duplicate, otherwise uploads new key
    func uploadSSHKey(name: String, sshKey: String, apiToken: String) async throws -> String {
        logger.info("Checking SSH key: \(name)")

        // Calculate fingerprint of the key to check for duplicates
        guard let fingerprint = calculateSSHFingerprint(sshKey) else {
            logger.error("Failed to calculate SSH key fingerprint")
            throw VultrError.apiError(String(localized: "Invalid SSH public key format"))
        }

        logger.debug("Calculated fingerprint: \(fingerprint)")

        // List existing SSH keys to check for duplicates
        let existingKeys = try await listSSHKeys(apiToken: apiToken)

        // Check if a key with the same content already exists
        let normalizedKey = normalizeSSHKey(sshKey)
        if let existingKey = existingKeys.first(where: { normalizeSSHKey($0.sshKey) == normalizedKey }) {
            logger.info("SSH key already exists with ID: \(existingKey.id), reusing it")
            return existingKey.id
        }

        // Key doesn't exist, upload it
        logger.info("Uploading new SSH key: \(name)")

        let url = URL(string: "\(apiBaseURL)/ssh-keys")!
        let payload: [String: Any] = [
            "name": name,
            "ssh_key": sshKey
        ]

        var request = createRequest(url: url, method: "POST", apiToken: apiToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, expectedStatus: 201)

        let decoded = try decode(VultrSSHKeyResponse.self, from: data, endpoint: "POST /ssh-keys")

        logger.info("SSH key uploaded successfully with ID: \(decoded.sshKey.id)")
        return decoded.sshKey.id
    }

    // MARK: - Instances

    func createInstance(
        label: String,
        region: String,
        plan: String,
        osID: Int,
        sshKeyIDs: [String],
        apiToken: String
    ) async throws -> VultrInstance {
        logger.info("Creating instance: \(label) in \(region) with plan \(plan)")
        logger.debug("OS ID: \(osID), SSH key IDs: \(sshKeyIDs)")

        let url = URL(string: "\(apiBaseURL)/instances")!
        let payload: [String: Any] = [
            "label": label,
            "region": region,
            "plan": plan,
            "os_id": osID,
            "sshkey_id": sshKeyIDs,
            "backups": "disabled",
            "enable_ipv6": true
        ]

        var request = createRequest(url: url, method: "POST", apiToken: apiToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        // Use enhanced validation with error body logging
        try validateResponseWithData(response, data: data, endpoint: "POST /instances")

        let decoded = try decode(VultrInstanceResponse.self, from: data, endpoint: "POST /instances")

        logger.info("Instance created with ID: \(decoded.instance.id), status: \(decoded.instance.status)")
        return decoded.instance
    }

    func getInstance(instanceID: String, apiToken: String) async throws -> VultrInstance {
        logger.info("Fetching instance: \(instanceID)")

        let url = URL(string: "\(apiBaseURL)/instances/\(instanceID)")!
        let request = createRequest(url: url, method: "GET", apiToken: apiToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let decoded = try decode(VultrInstanceResponse.self, from: data, endpoint: "GET /instances/\(instanceID)")

        logger.info("Instance fetched: ID \(decoded.instance.id), status: \(decoded.instance.status)")
        return decoded.instance
    }

    func waitForInstanceActive(
        instanceID: String,
        apiToken: String,
        maxWaitTime: TimeInterval,
        logCallback: @Sendable (String) -> Void
    ) async throws -> VultrInstance {
        logger.info("Waiting for instance \(instanceID) to become active...")

        let startTime = Date()
        let delaySeconds: UInt64 = 5

        while Date().timeIntervalSince(startTime) < maxWaitTime {
            let instance = try await getInstance(instanceID: instanceID, apiToken: apiToken)

            if instance.isActive, instance.publicIPv4 != nil {
                logger.info("Instance \(instanceID) is active with IP: \(instance.publicIPv4!)")
                logCallback("Instance is active with IP: \(instance.publicIPv4!)")
                return instance
            }

            let elapsed = Int(Date().timeIntervalSince(startTime))
            logCallback("Instance status: \(instance.status) / \(instance.powerStatus) (waited \(elapsed)s)")
            logger.info("Instance status is '\(instance.status)', waiting...")

            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }

        logger.error("Instance \(instanceID) did not become active within \(maxWaitTime) seconds")
        throw VultrError.timeout(String(localized: "Instance did not become active within the expected time"))
    }

    func deleteInstance(instanceID: String, apiToken: String) async throws {
        logger.info("Deleting instance: \(instanceID)")

        let url = URL(string: "\(apiBaseURL)/instances/\(instanceID)")!
        let request = createRequest(url: url, method: "DELETE", apiToken: apiToken)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, expectedStatus: 204)

        logger.info("Instance \(instanceID) deleted successfully")
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
            throw VultrError.networkError(String(localized: "Invalid server response"))
        }

        logger.debug("Response status code: \(httpResponse.statusCode)")

        // Allow 2xx status codes or specific expected status
        if (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == expectedStatus {
            return
        }

        switch httpResponse.statusCode {
        case 401:
            logger.error("Unauthorized - invalid API token")
            throw VultrError.unauthorized

        case 404:
            logger.error("Resource not found")
            throw VultrError.notFound

        case 400:
            logger.error("Validation error")
            throw VultrError.validation(String(localized: "Invalid request parameters"))

        case 429:
            logger.warning("Rate limited")
            throw VultrError.rateLimited

        case 500...599:
            logger.error("Server error: \(httpResponse.statusCode)")
            throw VultrError.serverError(String(localized: "Vultr server error (HTTP \(httpResponse.statusCode))"))

        default:
            logger.error("Unexpected status code: \(httpResponse.statusCode)")
            throw VultrError.apiError(String(localized: "HTTP \(httpResponse.statusCode)"))
        }
    }
}
