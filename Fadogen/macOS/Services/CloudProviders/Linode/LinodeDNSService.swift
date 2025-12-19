import Foundation

// MARK: - API Provider

struct LinodeDNSAPIProvider: DNSAPIProvider {
    typealias ErrorType = LinodeDNSError

    let apiToken: String

    var baseURL: String {
        "https://api.linode.com/v4/"
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
            throw LinodeDNSError.unauthorized
        case HTTPStatusCode.forbidden:
            throw LinodeDNSError.forbidden
        case HTTPStatusCode.notFound:
            throw LinodeDNSError.notFound
        case HTTPStatusCode.validation:
            let decoder = JSONDecoder()
            if let errorResponse = try? decoder.decode(LinodeDNSErrorResponse.self, from: data),
               let firstError = errorResponse.errors.first {
                throw LinodeDNSError.validation(firstError.reason)
            }
            throw LinodeDNSError.validation("Validation error")
        case HTTPStatusCode.rateLimited:
            throw LinodeDNSError.rateLimited
        case HTTPStatusCode.badGateway,
             HTTPStatusCode.serviceUnavailable,
             HTTPStatusCode.gatewayTimeout:
            throw LinodeDNSError.serverError(statusCode, "Server error")
        default:
            let decoder = JSONDecoder()
            if let errorResponse = try? decoder.decode(LinodeDNSErrorResponse.self, from: data),
               let firstError = errorResponse.errors.first {
                throw LinodeDNSError.apiError(firstError.reason)
            }
            throw LinodeDNSError.serverError(statusCode, "HTTP \(statusCode)")
        }
    }

    func shouldRetry(_ error: LinodeDNSError) -> Bool {
        switch error {
        case .rateLimited, .serverError, .timeout, .networkError:
            return true
        case .unauthorized, .forbidden, .notFound, .validation, .apiError, .invalidResponse, .recordAlreadyExists:
            return false
        }
    }
}

// MARK: - DNS Service

final class LinodeDNSService {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func createClient(apiToken: String) -> BaseDNSAPIClient<LinodeDNSAPIProvider> {
        let provider = LinodeDNSAPIProvider(apiToken: apiToken)
        return BaseDNSAPIClient(provider: provider, session: session)
    }

    // MARK: - Domains

    func listDomains(apiToken: String) async throws -> [LinodeDomain] {
        let client = createClient(apiToken: apiToken)
        var allDomains: [LinodeDomain] = []
        var currentPage = 1
        var hasMorePages = true

        while hasMorePages {
            let endpoint = "domains?page_size=100&page=\(currentPage)"
            let response: LinodeDomainsResponse = try await client.request(
                endpoint,
                method: "GET",
                body: nil
            )

            allDomains.append(contentsOf: response.data)

            // Check if there are more pages
            if currentPage < response.pages {
                currentPage += 1
                hasMorePages = true
            } else {
                hasMorePages = false
            }
        }

        return allDomains
    }

    func getDomain(domainId: Int, apiToken: String) async throws -> LinodeDomain {
        let client = createClient(apiToken: apiToken)
        let endpoint = "domains/\(domainId)"
        let response: LinodeDomain = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        return response
    }

    // MARK: - Records

    func listDNSRecords(
        domainId: Int,
        apiToken: String
    ) async throws -> [LinodeDomainRecord] {
        let client = createClient(apiToken: apiToken)
        var allRecords: [LinodeDomainRecord] = []
        var currentPage = 1
        var hasMorePages = true

        while hasMorePages {
            let endpoint = "domains/\(domainId)/records?page_size=100&page=\(currentPage)"
            let response: LinodeDomainRecordsResponse = try await client.request(
                endpoint,
                method: "GET",
                body: nil
            )

            allRecords.append(contentsOf: response.data)

            // Check if there are more pages
            if currentPage < response.pages {
                currentPage += 1
                hasMorePages = true
            } else {
                hasMorePages = false
            }
        }

        return allRecords
    }

    func getDNSRecord(
        domainId: Int,
        recordId: Int,
        apiToken: String
    ) async throws -> LinodeDomainRecord {
        let client = createClient(apiToken: apiToken)
        let endpoint = "domains/\(domainId)/records/\(recordId)"
        let response: LinodeDomainRecord = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        return response
    }

    func createDNSRecord(
        domainId: Int,
        type: String,
        name: String,
        target: String,
        priority: Int? = nil,
        weight: Int? = nil,
        port: Int? = nil,
        ttlSec: Int? = nil,
        apiToken: String
    ) async throws -> LinodeDomainRecord {
        let client = createClient(apiToken: apiToken)

        let requestBody = LinodeCreateRecordRequest(
            type: type,
            name: name,
            target: target,
            ttlSec: ttlSec,
            priority: priority,
            weight: weight,
            port: port
        )

        let encoder = JSONEncoder()
        guard let bodyData = try? encoder.encode(requestBody) else {
            throw LinodeDNSError.invalidResponse
        }

        let endpoint = "domains/\(domainId)/records"
        let response: LinodeDomainRecord = try await client.request(
            endpoint,
            method: "POST",
            body: bodyData
        )

        return response
    }

    func deleteDNSRecord(
        domainId: Int,
        recordId: Int,
        apiToken: String
    ) async throws {
        let client = createClient(apiToken: apiToken)
        let endpoint = "domains/\(domainId)/records/\(recordId)"
        let _: EmptyResponse = try await client.request(
            endpoint,
            method: "DELETE",
            body: nil
        )
    }
}
