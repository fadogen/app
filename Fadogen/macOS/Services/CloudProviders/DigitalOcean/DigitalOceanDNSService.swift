import Foundation

// MARK: - API Provider

struct DigitalOceanAPIProvider: DNSAPIProvider {
    typealias ErrorType = DigitalOceanDNSError

    let apiToken: String

    var baseURL: String {
        "https://api.digitalocean.com/v2/"
    }

    func configureAuth(for request: inout URLRequest) {
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
    }

    func handleHTTPStatus(_ statusCode: Int, data: Data) throws {
        enum HTTPStatusCode {
            static let unauthorized = 401
            static let notFound = 404
            static let unprocessableEntity = 422
            static let rateLimited = 429
            static let badGateway = 502
            static let serviceUnavailable = 503
            static let gatewayTimeout = 504
        }

        switch statusCode {
        case 200...299:
            return
        case HTTPStatusCode.unauthorized:
            throw DigitalOceanDNSError.unauthorized
        case HTTPStatusCode.notFound:
            throw DigitalOceanDNSError.notFound
        case HTTPStatusCode.unprocessableEntity:
            let decoder = JSONDecoder()
            if let errorResponse = try? decoder.decode(DigitalOceanErrorResponse.self, from: data) {
                throw DigitalOceanDNSError.unprocessableEntity(errorResponse.message)
            }
            throw DigitalOceanDNSError.unprocessableEntity("Validation error")
        case HTTPStatusCode.rateLimited:
            throw DigitalOceanDNSError.rateLimited
        case HTTPStatusCode.badGateway,
             HTTPStatusCode.serviceUnavailable,
             HTTPStatusCode.gatewayTimeout:
            throw DigitalOceanDNSError.serverError(statusCode, "Server error")
        default:
            let decoder = JSONDecoder()
            if let errorResponse = try? decoder.decode(DigitalOceanErrorResponse.self, from: data) {
                throw DigitalOceanDNSError.apiError(errorResponse.message)
            }
            throw DigitalOceanDNSError.serverError(statusCode, "HTTP \(statusCode)")
        }
    }

    func shouldRetry(_ error: DigitalOceanDNSError) -> Bool {
        switch error {
        case .rateLimited, .serverError, .timeout, .networkError:
            return true
        case .unauthorized, .notFound, .unprocessableEntity, .apiError, .invalidResponse, .recordAlreadyExists:
            return false
        }
    }
}

// MARK: - DNS Service

final class DigitalOceanDNSService {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func createClient(apiToken: String) -> BaseDNSAPIClient<DigitalOceanAPIProvider> {
        let provider = DigitalOceanAPIProvider(apiToken: apiToken)
        return BaseDNSAPIClient(provider: provider, session: session)
    }

    // MARK: - Domains

    func listDomains(apiToken: String) async throws -> [DigitalOceanDomain] {
        let client = createClient(apiToken: apiToken)
        var allDomains: [DigitalOceanDomain] = []
        var currentPage = 1
        var hasMorePages = true

        while hasMorePages {
            let endpoint = "domains?per_page=100&page=\(currentPage)"
            let response: DigitalOceanDomainsResponse = try await client.request(
                endpoint,
                method: "GET",
                body: nil
            )

            allDomains.append(contentsOf: response.domains)

            // Check if there are more pages
            if response.links?.pages?.next != nil {
                currentPage += 1
                hasMorePages = true
            } else {
                hasMorePages = false
            }
        }

        return allDomains
    }

    func getDomain(domain: String, apiToken: String) async throws -> DigitalOceanDomain {
        let client = createClient(apiToken: apiToken)
        let endpoint = "domains/\(domain)"
        let response: DigitalOceanDomainResponse = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        return response.domain
    }

    // MARK: - Domain Records

    func listDNSRecords(
        domain: String,
        type: String? = nil,
        name: String? = nil,
        apiToken: String
    ) async throws -> [DigitalOceanDomainRecord] {
        let client = createClient(apiToken: apiToken)
        var allRecords: [DigitalOceanDomainRecord] = []
        var currentPage = 1
        var hasMorePages = true

        while hasMorePages {
            var endpoint = "domains/\(domain)/records?per_page=100&page=\(currentPage)"

            // Add optional filters
            if let type = type {
                endpoint += "&type=\(type)"
            }
            if let name = name {
                endpoint += "&name=\(name)"
            }

            let response: DigitalOceanDomainRecordsResponse = try await client.request(
                endpoint,
                method: "GET",
                body: nil
            )

            allRecords.append(contentsOf: response.domainRecords)

            // Check if there are more pages
            if response.links?.pages?.next != nil {
                currentPage += 1
                hasMorePages = true
            } else {
                hasMorePages = false
            }
        }

        return allRecords
    }

    func getDNSRecord(
        domain: String,
        recordID: Int,
        apiToken: String
    ) async throws -> DigitalOceanDomainRecord {
        let client = createClient(apiToken: apiToken)
        let endpoint = "domains/\(domain)/records/\(recordID)"
        let response: DigitalOceanDomainRecordResponse = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        return response.domainRecord
    }

    func createDNSRecord(
        domain: String,
        type: String,
        name: String,
        data: String,
        priority: Int? = nil,
        port: Int? = nil,
        weight: Int? = nil,
        flags: Int? = nil,
        tag: String? = nil,
        apiToken: String
    ) async throws -> DigitalOceanDomainRecord {
        let client = createClient(apiToken: apiToken)

        let requestBody = DigitalOceanCreateRecordRequest(
            type: type,
            name: name,
            data: data,
            priority: priority,
            port: port,
            weight: weight,
            flags: flags,
            tag: tag
        )

        let encoder = JSONEncoder()
        guard let bodyData = try? encoder.encode(requestBody) else {
            throw DigitalOceanDNSError.invalidResponse
        }

        let endpoint = "domains/\(domain)/records"
        let response: DigitalOceanDomainRecordResponse = try await client.request(
            endpoint,
            method: "POST",
            body: bodyData
        )

        return response.domainRecord
    }

    func deleteDNSRecord(
        domain: String,
        recordID: Int,
        apiToken: String
    ) async throws {
        let client = createClient(apiToken: apiToken)
        let endpoint = "domains/\(domain)/records/\(recordID)"
        let _: EmptyResponse = try await client.request(
            endpoint,
            method: "DELETE",
            body: nil
        )
    }

}
