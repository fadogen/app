import Foundation

// MARK: - API Provider

struct VultrDNSAPIProvider: DNSAPIProvider {
    typealias ErrorType = VultrDNSError

    let apiToken: String

    var baseURL: String {
        "https://api.vultr.com/v2/"
    }

    func configureAuth(for request: inout URLRequest) {
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
    }

    func handleHTTPStatus(_ statusCode: Int, data: Data) throws {
        enum HTTPStatusCode {
            static let unauthorized = 401
            static let forbidden = 403
            static let notFound = 404
            static let validation = 400
            static let rateLimited = 429
            static let badGateway = 502
            static let serviceUnavailable = 503
            static let gatewayTimeout = 504
        }

        switch statusCode {
        case 200...299:
            return
        case HTTPStatusCode.unauthorized:
            throw VultrDNSError.unauthorized
        case HTTPStatusCode.forbidden:
            throw VultrDNSError.forbidden
        case HTTPStatusCode.notFound:
            throw VultrDNSError.notFound
        case HTTPStatusCode.validation:
            let decoder = JSONDecoder()
            if let errorResponse = try? decoder.decode(VultrErrorResponse.self, from: data) {
                throw VultrDNSError.validation(errorResponse.error)
            }
            throw VultrDNSError.validation("Validation error")
        case HTTPStatusCode.rateLimited:
            throw VultrDNSError.rateLimited
        case HTTPStatusCode.badGateway,
             HTTPStatusCode.serviceUnavailable,
             HTTPStatusCode.gatewayTimeout:
            throw VultrDNSError.serverError(statusCode, "Server error")
        default:
            let decoder = JSONDecoder()
            if let errorResponse = try? decoder.decode(VultrErrorResponse.self, from: data) {
                throw VultrDNSError.apiError(errorResponse.error)
            }
            throw VultrDNSError.serverError(statusCode, "HTTP \(statusCode)")
        }
    }

    func shouldRetry(_ error: VultrDNSError) -> Bool {
        switch error {
        case .rateLimited, .serverError, .timeout, .networkError:
            return true
        case .unauthorized, .forbidden, .notFound, .validation, .apiError, .invalidResponse, .recordAlreadyExists:
            return false
        }
    }
}

// MARK: - DNS Service

final class VultrDNSService {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func createClient(apiToken: String) -> BaseDNSAPIClient<VultrDNSAPIProvider> {
        let provider = VultrDNSAPIProvider(apiToken: apiToken)
        return BaseDNSAPIClient(provider: provider, session: session)
    }

    // MARK: - Domains

    func listDomains(apiToken: String) async throws -> [VultrDomain] {
        let client = createClient(apiToken: apiToken)
        let response: VultrDomainsResponse = try await client.request(
            "domains?per_page=100",
            method: "GET",
            body: nil
        )
        return response.domains
    }

    func getDomain(domain: String, apiToken: String) async throws -> VultrDomain {
        let client = createClient(apiToken: apiToken)
        let endpoint = "domains/\(domain)"
        let response: VultrDomainResponse = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        return response.domain
    }

    // MARK: - Records

    func listDNSRecords(
        domain: String,
        apiToken: String
    ) async throws -> [VultrDNSRecord] {
        let client = createClient(apiToken: apiToken)
        let response: VultrDNSRecordsResponse = try await client.request(
            "domains/\(domain)/records?per_page=100",
            method: "GET",
            body: nil
        )
        return response.records
    }

    func getDNSRecord(
        domain: String,
        recordId: String,
        apiToken: String
    ) async throws -> VultrDNSRecord {
        let client = createClient(apiToken: apiToken)
        let endpoint = "domains/\(domain)/records/\(recordId)"
        let response: VultrDNSRecordResponse = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        return response.record
    }

    func createDNSRecord(
        domain: String,
        type: String,
        name: String,
        data: String,
        priority: Int? = nil,
        ttl: Int? = nil,
        apiToken: String
    ) async throws -> VultrDNSRecord {
        let client = createClient(apiToken: apiToken)

        let requestBody = VultrCreateRecordRequest(
            type: type,
            name: name,
            data: data,
            ttl: ttl,
            priority: priority
        )

        let encoder = JSONEncoder()
        guard let bodyData = try? encoder.encode(requestBody) else {
            throw VultrDNSError.invalidResponse
        }

        let endpoint = "domains/\(domain)/records"
        let response: VultrDNSRecordResponse = try await client.request(
            endpoint,
            method: "POST",
            body: bodyData
        )

        return response.record
    }

    func deleteDNSRecord(
        domain: String,
        recordId: String,
        apiToken: String
    ) async throws {
        let client = createClient(apiToken: apiToken)
        let endpoint = "domains/\(domain)/records/\(recordId)"
        let _: EmptyResponse = try await client.request(
            endpoint,
            method: "DELETE",
            body: nil
        )
    }
}
