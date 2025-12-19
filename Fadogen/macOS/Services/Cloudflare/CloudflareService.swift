import Foundation

// MARK: - API Provider

struct CloudflareAPIProvider: DNSAPIProvider {
    typealias ErrorType = CloudflareError

    let email: String
    let apiKey: String

    var baseURL: String {
        "https://api.cloudflare.com/client/v4/"
    }

    func configureAuth(for request: inout URLRequest) {
        request.setValue(email, forHTTPHeaderField: "X-Auth-Email")
        request.setValue(apiKey, forHTTPHeaderField: "X-Auth-Key")
    }

    func handleHTTPStatus(_ statusCode: Int, data: Data) throws {
        // Cloudflare uses wrapped responses (CloudflareAPIResponse) with success/errors fields
        // HTTP status validation is minimal - actual errors are in the response body
        enum HTTPStatusCode {
            static let unauthorized = 401
            static let forbidden = 403
            static let rateLimited = 429
            static let badGateway = 502
            static let serviceUnavailable = 503
            static let gatewayTimeout = 504
        }

        switch statusCode {
        case 200...299:
            return
        case HTTPStatusCode.unauthorized, HTTPStatusCode.forbidden:
            throw CloudflareError.unauthorized
        case HTTPStatusCode.rateLimited:
            throw CloudflareError.rateLimited
        case HTTPStatusCode.badGateway,
             HTTPStatusCode.serviceUnavailable,
             HTTPStatusCode.gatewayTimeout:
            throw CloudflareError.serverError(code: statusCode)
        default:
            // Don't throw for 4xx errors - let the response decoder handle it
            if statusCode >= 500 {
                throw CloudflareError.serverError(code: statusCode)
            }
        }
    }

    func shouldRetry(_ error: CloudflareError) -> Bool {
        switch error {
        case .rateLimited, .serverError, .timeout, .networkError:
            return true
        case .unauthorized, .apiError, .invalidResponse, .noAccountFound,
             .recordConflict, .invalidRecordType, .dnssecError, .zoneLockedError:
            return false
        }
    }
}

// MARK: - Service

final class CloudflareService {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func createClient(email: String, apiKey: String) -> BaseDNSAPIClient<CloudflareAPIProvider> {
        let provider = CloudflareAPIProvider(email: email, apiKey: apiKey)
        return BaseDNSAPIClient(provider: provider, session: session)
    }

    // MARK: - Zones

    func listZones(integration: Integration) async throws -> [CloudflareZone] {
        guard let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey else {
            throw CloudflareError.unauthorized
        }
        let client = createClient(email: email, apiKey: apiKey)
        var allZones: [CloudflareZone] = []
        var currentPage = 1
        var hasMorePages = true

        while hasMorePages {
            let endpoint = "zones?status=active&per_page=50&page=\(currentPage)&order=name"
            let response: CloudflareAPIResponse<[CloudflareZone]> = try await client.request(
                endpoint,
                method: "GET",
                body: nil
            )

            guard response.success, let zones = response.result else {
                throw CloudflareError.apiError(
                    code: response.errors.first?.code ?? 0,
                    message: response.errorMessage()
                )
            }

            allZones.append(contentsOf: zones)

            if let resultInfo = response.resultInfo {
                hasMorePages = currentPage < resultInfo.totalPages
                currentPage += 1
            } else {
                hasMorePages = false
            }
        }

        return allZones
    }

    func getAccountID(integration: Integration) async throws -> String {
        guard let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey else {
            throw CloudflareError.unauthorized
        }
        let client = createClient(email: email, apiKey: apiKey)
        let endpoint = "accounts"
        let response: CloudflareAPIResponse<[CloudflareAccount]> = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        guard response.success, let accounts = response.result, !accounts.isEmpty else {
            throw CloudflareError.noAccountFound
        }

        return accounts[0].id
    }

    // MARK: - Tunnels

    func createTunnel(name: String, accountID: String, email: String, apiKey: String) async throws -> CloudflareTunnelInfo {
        let client = createClient(email: email, apiKey: apiKey)

        let requestBody: [String: Any] = [
            "name": name,
            "config_src": "cloudflare"
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw CloudflareError.invalidResponse
        }

        let endpoint = "accounts/\(accountID)/cfd_tunnel"
        let response: CloudflareAPIResponse<CloudflareTunnelInfo> = try await client.request(
            endpoint,
            method: "POST",
            body: bodyData
        )

        guard response.success, let tunnel = response.result else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }

        return tunnel
    }

    func configureTunnelIngress(
        tunnelID: String,
        sshHostname: String,
        accountID: String,
        email: String,
        apiKey: String
    ) async throws {
        let client = createClient(email: email, apiKey: apiKey)

        let ingressConfig: [String: Any] = [
            "config": [
                "ingress": [
                    [
                        "hostname": sshHostname,
                        "service": "ssh://localhost:22"
                    ],
                    [
                        "service": "http_status:404"
                    ]
                ]
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: ingressConfig) else {
            throw CloudflareError.invalidResponse
        }

        let endpoint = "accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations"
        let response: CloudflareAPIResponse<EmptyResult> = try await client.request(
            endpoint,
            method: "PUT",
            body: bodyData
        )

        guard response.success else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }
    }

    func getTunnelConfiguration(
        tunnelID: String,
        accountID: String,
        email: String,
        apiKey: String
    ) async throws -> TunnelConfiguration {
        let client = createClient(email: email, apiKey: apiKey)
        let endpoint = "accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations"
        let response: CloudflareAPIResponse<TunnelConfigurationResponse> = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        guard response.success, let config = response.result else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }

        return config.config
    }

    /// Idempotent: skips if route already exists
    func addHTTPRouteToTunnel(
        tunnelID: String,
        hostname: String,
        localPort: Int = 80,
        accountID: String,
        email: String,
        apiKey: String
    ) async throws {
        // 1. Get current configuration
        let currentConfig = try await getTunnelConfiguration(
            tunnelID: tunnelID,
            accountID: accountID,
            email: email,
            apiKey: apiKey
        )

        // 2. Check if route already exists (idempotence)
        if currentConfig.ingress.contains(where: { $0.hostname == hostname }) {
            return
        }

        // 3. Build new configuration
        var newIngress = currentConfig.ingress

        // Remove catch-all (last rule without hostname)
        if let lastRule = newIngress.last, lastRule.hostname == nil {
            newIngress.removeLast()
        }

        // Add new HTTP route
        let newRule = IngressRule(
            hostname: hostname,
            service: "http://localhost:\(localPort)"
        )
        newIngress.append(newRule)

        // Re-add catch-all at the end
        let catchAll = IngressRule(
            hostname: nil,
            service: "http_status:404"
        )
        newIngress.append(catchAll)

        // 4. Update configuration
        let ingressConfig: [String: Any] = [
            "config": [
                "ingress": newIngress.map { rule in
                    var dict: [String: Any] = ["service": rule.service]
                    if let hostname = rule.hostname {
                        dict["hostname"] = hostname
                    }
                    return dict
                }
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: ingressConfig) else {
            throw CloudflareError.invalidResponse
        }

        let client = createClient(email: email, apiKey: apiKey)
        let endpoint = "accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations"
        let response: CloudflareAPIResponse<EmptyResult> = try await client.request(
            endpoint,
            method: "PUT",
            body: bodyData
        )

        guard response.success else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }
    }

    /// Idempotent: skips if route doesn't exist
    func removeHTTPRouteFromTunnel(
        tunnelID: String,
        hostname: String,
        accountID: String,
        email: String,
        apiKey: String
    ) async throws {
        // 1. Get current configuration
        let currentConfig = try await getTunnelConfiguration(
            tunnelID: tunnelID,
            accountID: accountID,
            email: email,
            apiKey: apiKey
        )

        // 2. Check if route exists (idempotent)
        guard currentConfig.ingress.contains(where: { $0.hostname == hostname }) else {
            return
        }

        // 3. Filter out the route
        var newIngress = currentConfig.ingress.filter { $0.hostname != hostname }

        // 4. Ensure catch-all exists at the end
        if newIngress.last?.hostname != nil {
            newIngress.append(IngressRule(hostname: nil, service: "http_status:404"))
        }

        // 5. Update configuration
        let ingressConfig: [String: Any] = [
            "config": [
                "ingress": newIngress.map { rule in
                    var dict: [String: Any] = ["service": rule.service]
                    if let hostname = rule.hostname {
                        dict["hostname"] = hostname
                    }
                    return dict
                }
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: ingressConfig) else {
            throw CloudflareError.invalidResponse
        }

        let client = createClient(email: email, apiKey: apiKey)
        let endpoint = "accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations"
        let response: CloudflareAPIResponse<EmptyResult> = try await client.request(
            endpoint,
            method: "PUT",
            body: bodyData
        )

        guard response.success else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }
    }

    func getTunnel(tunnelID: String, accountID: String, email: String, apiKey: String) async throws -> CloudflareTunnelInfo {
        let client = createClient(email: email, apiKey: apiKey)
        let endpoint = "accounts/\(accountID)/cfd_tunnel/\(tunnelID)"
        let response: CloudflareAPIResponse<CloudflareTunnelInfo> = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        guard response.success, let tunnel = response.result else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }

        return tunnel
    }

    func listTunnels(accountID: String, email: String, apiKey: String) async throws -> [CloudflareTunnelInfo] {
        let client = createClient(email: email, apiKey: apiKey)
        var allTunnels: [CloudflareTunnelInfo] = []
        var currentPage = 1
        var hasMorePages = true

        while hasMorePages {
            let endpoint = "accounts/\(accountID)/cfd_tunnel?per_page=50&page=\(currentPage)"
            let response: CloudflareAPIResponse<[CloudflareTunnelInfo]> = try await client.request(
                endpoint,
                method: "GET",
                body: nil
            )

            guard response.success, let tunnels = response.result else {
                throw CloudflareError.apiError(
                    code: response.errors.first?.code ?? 0,
                    message: response.errorMessage()
                )
            }

            allTunnels.append(contentsOf: tunnels)

            if let resultInfo = response.resultInfo {
                hasMorePages = currentPage < resultInfo.totalPages
                currentPage += 1
            } else {
                hasMorePages = false
            }
        }

        return allTunnels
    }

    func deleteTunnel(tunnelID: String, accountID: String, email: String, apiKey: String) async throws {
        let client = createClient(email: email, apiKey: apiKey)
        let endpoint = "accounts/\(accountID)/cfd_tunnel/\(tunnelID)?cascade=true"
        let response: CloudflareAPIResponse<CloudflareTunnelInfo> = try await client.request(
            endpoint,
            method: "DELETE",
            body: nil
        )

        guard response.success else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }
    }

    // MARK: - DNS

    func createDNSRecord(
        zoneID: String,
        type: String,
        name: String,
        content: String,
        proxied: Bool,
        email: String,
        apiKey: String
    ) async throws -> CloudflareDNSRecord {
        let client = createClient(email: email, apiKey: apiKey)

        let requestBody: [String: Any] = [
            "type": type,
            "name": name,
            "content": content,
            "proxied": proxied
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw CloudflareError.invalidResponse
        }

        let endpoint = "zones/\(zoneID)/dns_records"
        let response: CloudflareAPIResponse<CloudflareDNSRecord> = try await client.request(
            endpoint,
            method: "POST",
            body: bodyData
        )

        guard response.success, let record = response.result else {
            let errorMessage = response.errorMessage()
            if errorMessage.localizedCaseInsensitiveContains("conflict") {
                throw CloudflareError.recordConflict(message: errorMessage)
            } else if errorMessage.localizedCaseInsensitiveContains("invalid") && errorMessage.localizedCaseInsensitiveContains("type") {
                throw CloudflareError.invalidRecordType(message: errorMessage)
            } else if errorMessage.localizedCaseInsensitiveContains("dnssec") {
                throw CloudflareError.dnssecError(message: errorMessage)
            } else if errorMessage.localizedCaseInsensitiveContains("locked") {
                throw CloudflareError.zoneLockedError(message: errorMessage)
            }

            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: errorMessage
            )
        }

        return record
    }

    func listDNSRecords(
        zoneID: String,
        type: String? = nil,
        name: String? = nil,
        content: String? = nil,
        email: String,
        apiKey: String
    ) async throws -> [CloudflareDNSRecord] {
        let client = createClient(email: email, apiKey: apiKey)
        var allRecords: [CloudflareDNSRecord] = []
        var currentPage = 1
        var hasMorePages = true

        while hasMorePages {
            var endpoint = "zones/\(zoneID)/dns_records?per_page=100&page=\(currentPage)"

            if let type = type {
                endpoint += "&type=\(type)"
            }
            if let name = name {
                endpoint += "&name=\(name)"
            }
            if let content = content {
                endpoint += "&content=\(content)"
            }

            let response: CloudflareAPIResponse<[CloudflareDNSRecord]> = try await client.request(
                endpoint,
                method: "GET",
                body: nil
            )

            guard response.success, let records = response.result else {
                throw CloudflareError.apiError(
                    code: response.errors.first?.code ?? 0,
                    message: response.errorMessage()
                )
            }

            allRecords.append(contentsOf: records)

            if let resultInfo = response.resultInfo {
                hasMorePages = currentPage < resultInfo.totalPages
                currentPage += 1
            } else {
                hasMorePages = false
            }
        }

        return allRecords
    }

    func deleteDNSRecord(recordID: String, zoneID: String, email: String, apiKey: String) async throws {
        let client = createClient(email: email, apiKey: apiKey)
        let endpoint = "zones/\(zoneID)/dns_records/\(recordID)"
        let response: CloudflareAPIResponse<CloudflareDeleteResponse> = try await client.request(
            endpoint,
            method: "DELETE",
            body: nil
        )

        guard response.success else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }
    }

    // MARK: - Orchestration

    func setupTunnelForServer(
        serverName: String,
        zoneName: String,
        zoneID: String,
        sshSubdomain: String,
        accountID: String,
        integration: Integration
    ) async throws -> TunnelSetupResult {
        guard let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey else {
            throw CloudflareError.unauthorized
        }
        let sanitizedServerName = serverName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        let tunnelName = "fadogen-\(sanitizedServerName)"

        guard tunnelName.count <= 63 else {
            throw CloudflareError.apiError(
                code: 0,
                message: "Tunnel name too long (max 63 characters): \(tunnelName)"
            )
        }

        let tunnel = try await createTunnel(
            name: tunnelName,
            accountID: accountID,
            email: email,
            apiKey: apiKey
        )

        let sshHostname = "\(sshSubdomain).\(zoneName)"
        try await configureTunnelIngress(
            tunnelID: tunnel.id,
            sshHostname: sshHostname,
            accountID: accountID,
            email: email,
            apiKey: apiKey
        )

        do {
            let existingRecords = try await listDNSRecords(
                zoneID: zoneID,
                name: "\(sshSubdomain).\(zoneName)",
                email: email,
                apiKey: apiKey
            )

            if !existingRecords.isEmpty {
                throw CloudflareError.recordConflict(
                    message: "DNS record \(sshSubdomain).\(zoneName) already exists"
                )
            }

            let dnsRecord = try await createDNSRecord(
                zoneID: zoneID,
                type: "CNAME",
                name: sshSubdomain,
                content: tunnel.cnameTarget,
                proxied: true,
                email: email,
                apiKey: apiKey
            )

            return TunnelSetupResult(tunnelInfo: tunnel, dnsRecord: dnsRecord)

        } catch {
            try? await deleteTunnel(
                tunnelID: tunnel.id,
                accountID: accountID,
                email: email,
                apiKey: apiKey
            )
            throw error
        }
    }

    func removeTunnelForServer(
        tunnelID: String,
        dnsRecordID: String,
        zoneID: String,
        accountID: String,
        integration: Integration
    ) async throws {
        guard let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey else {
            throw CloudflareError.unauthorized
        }
        var errors: [Error] = []

        do {
            try await deleteDNSRecord(
                recordID: dnsRecordID,
                zoneID: zoneID,
                email: email,
                apiKey: apiKey
            )
        } catch {
            errors.append(error)
        }

        do {
            try await deleteTunnel(
                tunnelID: tunnelID,
                accountID: accountID,
                email: email,
                apiKey: apiKey
            )
        } catch {
            errors.append(error)
        }

        if let firstError = errors.first {
            throw firstError
        }
    }

    // MARK: - R2 Storage

    func getR2PermissionGroupId(accountId: String, email: String, apiKey: String) async throws -> String {
        let client = createClient(email: email, apiKey: apiKey)
        let endpoint = "accounts/\(accountId)/tokens/permission_groups"
        let response: CloudflareAPIResponse<[CloudflarePermissionGroup]> = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        guard response.success, let groups = response.result else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }

        // Find "Workers R2 Storage Write" permission group
        guard let r2WriteGroup = groups.first(where: { $0.name == "Workers R2 Storage Write" }) else {
            throw CloudflareError.apiError(
                code: 0,
                message: "R2 Storage Write permission group not found"
            )
        }

        return r2WriteGroup.id
    }

    /// Returns S3-compatible credentials (Access Key ID = token ID, Secret = SHA256(token value))
    func createR2Token(
        accountId: String,
        email: String,
        apiKey: String
    ) async throws -> CloudflareR2Credentials {
        let client = createClient(email: email, apiKey: apiKey)

        // 1. Get R2 permission group ID
        let permissionGroupId = try await getR2PermissionGroupId(
            accountId: accountId,
            email: email,
            apiKey: apiKey
        )

        // 2. Create token request
        let requestBody: [String: Any] = [
            "name": "Fadogen Backups",
            "policies": [
                [
                    "effect": "allow",
                    "resources": [
                        "com.cloudflare.api.account.\(accountId)": "*"
                    ],
                    "permission_groups": [
                        ["id": permissionGroupId]
                    ]
                ]
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw CloudflareError.invalidResponse
        }

        // 3. Create token via user/tokens endpoint
        let endpoint = "user/tokens"
        let response: CloudflareAPIResponse<CloudflareTokenInfo> = try await client.request(
            endpoint,
            method: "POST",
            body: bodyData
        )

        guard response.success, let token = response.result, let tokenValue = token.value else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }

        // 4. Derive S3-compatible credentials
        // Access Key ID = token ID
        // Secret Access Key = SHA256(token value)
        let secretAccessKey = tokenValue.sha256Hash()

        return CloudflareR2Credentials(
            accessKeyId: token.id,
            secretAccessKey: secretAccessKey
        )
    }

    func listR2Buckets(
        accountId: String,
        email: String,
        apiKey: String
    ) async throws -> [CloudflareR2Bucket] {
        let client = createClient(email: email, apiKey: apiKey)
        let endpoint = "accounts/\(accountId)/r2/buckets"
        let response: CloudflareAPIResponse<CloudflareR2BucketListResult> = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        guard response.success, let result = response.result else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }

        return result.buckets
    }

    func createR2Bucket(
        accountId: String,
        name: String,
        email: String,
        apiKey: String
    ) async throws -> CloudflareR2Bucket {
        let client = createClient(email: email, apiKey: apiKey)

        let requestBody: [String: Any] = [
            "name": name
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw CloudflareError.invalidResponse
        }

        let endpoint = "accounts/\(accountId)/r2/buckets"
        let response: CloudflareAPIResponse<CloudflareR2Bucket> = try await client.request(
            endpoint,
            method: "POST",
            body: bodyData
        )

        guard response.success, let bucket = response.result else {
            throw CloudflareError.apiError(
                code: response.errors.first?.code ?? 0,
                message: response.errorMessage()
            )
        }

        return bucket
    }

}
