import Foundation

// MARK: - API Provider

struct HetznerDNSAPIProvider: DNSAPIProvider {
    typealias ErrorType = HetznerDNSError

    let apiToken: String

    var baseURL: String {
        "https://dns.hetzner.com/api/v1/"
    }

    func configureAuth(for request: inout URLRequest) {
        request.setValue(apiToken, forHTTPHeaderField: "Auth-API-Token")
    }

    func handleHTTPStatus(_ statusCode: Int, data: Data) throws {
        enum HTTPStatusCode {
            static let unauthorized = 401
            static let forbidden = 403
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
        case HTTPStatusCode.unauthorized, HTTPStatusCode.forbidden:
            throw HetznerDNSError.unauthorized
        case HTTPStatusCode.notFound:
            throw HetznerDNSError.notFound
        case HTTPStatusCode.unprocessableEntity:
            let decoder = JSONDecoder()
            if let errorResponse = try? decoder.decode(HetznerDNSErrorResponse.self, from: data) {
                throw HetznerDNSError.unprocessableEntity(errorResponse.message)
            }
            throw HetznerDNSError.unprocessableEntity("Validation error")
        case HTTPStatusCode.rateLimited:
            throw HetznerDNSError.rateLimited
        case HTTPStatusCode.badGateway,
             HTTPStatusCode.serviceUnavailable,
             HTTPStatusCode.gatewayTimeout:
            throw HetznerDNSError.serverError(statusCode, "Server error")
        default:
            let decoder = JSONDecoder()
            if let errorResponse = try? decoder.decode(HetznerDNSErrorResponse.self, from: data) {
                throw HetznerDNSError.apiError(errorResponse.message)
            }
            throw HetznerDNSError.serverError(statusCode, "HTTP \(statusCode)")
        }
    }

    func shouldRetry(_ error: HetznerDNSError) -> Bool {
        switch error {
        case .rateLimited, .serverError, .timeout, .networkError:
            return true
        case .unauthorized, .notFound, .unprocessableEntity, .apiError, .invalidResponse, .recordAlreadyExists:
            return false
        }
    }
}

// MARK: - DNS Service

final class HetznerDNSService {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func createClient(apiToken: String) -> BaseDNSAPIClient<HetznerDNSAPIProvider> {
        let provider = HetznerDNSAPIProvider(apiToken: apiToken)
        return BaseDNSAPIClient(provider: provider, session: session)
    }

    // MARK: - Zones

    func listZones(apiToken: String) async throws -> [HetznerDNSZone] {
        let client = createClient(apiToken: apiToken)
        var allZones: [HetznerDNSZone] = []
        var currentPage = 1
        var hasMorePages = true

        while hasMorePages {
            let endpoint = "zones?per_page=100&page=\(currentPage)"

            do {
                let response: HetznerDNSZonesResponse = try await client.request(
                    endpoint,
                    method: "GET",
                    body: nil
                )

                allZones.append(contentsOf: response.zones)

                // Check if there are more pages
                if let pagination = response.meta?.pagination, currentPage < pagination.lastPage {
                    currentPage += 1
                    hasMorePages = true
                } else {
                    hasMorePages = false
                }
            } catch HetznerDNSError.notFound {
                // Hetzner DNS returns 404 "zone not found" when account has no zones
                // This is valid - just return empty array
                return []
            }
        }

        return allZones
    }

    func getZone(zoneID: String, apiToken: String) async throws -> HetznerDNSZone {
        let client = createClient(apiToken: apiToken)
        let endpoint = "zones/\(zoneID)"
        let response: HetznerDNSZoneResponse = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        return response.zone
    }

    // MARK: - Records

    func listDNSRecords(
        zoneID: String,
        apiToken: String
    ) async throws -> [HetznerDNSRecord] {
        let client = createClient(apiToken: apiToken)
        var allRecords: [HetznerDNSRecord] = []
        var currentPage = 1
        var hasMorePages = true

        while hasMorePages {
            let endpoint = "records?zone_id=\(zoneID)&per_page=100&page=\(currentPage)"
            let response: HetznerDNSRecordsResponse = try await client.request(
                endpoint,
                method: "GET",
                body: nil
            )

            allRecords.append(contentsOf: response.records)

            // Check if there are more pages
            if let pagination = response.meta?.pagination, currentPage < pagination.lastPage {
                currentPage += 1
                hasMorePages = true
            } else {
                hasMorePages = false
            }
        }

        return allRecords
    }

    func getDNSRecord(
        recordID: String,
        apiToken: String
    ) async throws -> HetznerDNSRecord {
        let client = createClient(apiToken: apiToken)
        let endpoint = "records/\(recordID)"
        let response: HetznerDNSRecordResponse = try await client.request(
            endpoint,
            method: "GET",
            body: nil
        )

        return response.record
    }

    func createDNSRecord(
        zoneID: String,
        type: String,
        name: String,
        value: String,
        ttl: Int? = nil,
        apiToken: String
    ) async throws -> HetznerDNSRecord {
        let client = createClient(apiToken: apiToken)

        let requestBody = HetznerDNSCreateRecordRequest(
            name: name,
            type: type,
            value: value,
            zoneID: zoneID,
            ttl: ttl
        )

        let encoder = JSONEncoder()
        guard let bodyData = try? encoder.encode(requestBody) else {
            throw HetznerDNSError.invalidResponse
        }

        let endpoint = "records"
        let response: HetznerDNSRecordResponse = try await client.request(
            endpoint,
            method: "POST",
            body: bodyData
        )

        return response.record
    }

    func deleteDNSRecord(
        recordID: String,
        apiToken: String
    ) async throws {
        let client = createClient(apiToken: apiToken)
        let endpoint = "records/\(recordID)"
        let _: EmptyResponse = try await client.request(
            endpoint,
            method: "DELETE",
            body: nil
        )
    }
}
