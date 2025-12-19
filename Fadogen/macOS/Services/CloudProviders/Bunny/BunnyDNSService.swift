import Foundation
import os

private let logger = Logger(subsystem: "app.fadogen", category: "BunnyDNSService")

// MARK: - API Provider

struct BunnyDNSAPIProvider: DNSAPIProvider {
    typealias ErrorType = BunnyDNSError

    let apiKey: String

    var baseURL: String {
        "https://api.bunny.net/"
    }

    func configureAuth(for request: inout URLRequest) {
        request.setValue(apiKey, forHTTPHeaderField: "AccessKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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

        let responseString = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("Bunny HTTP status: \(statusCode)")

        switch statusCode {
        case 200...299:
            return
        case HTTPStatusCode.unauthorized:
            logger.error("Bunny: Unauthorized (401) - \(responseString)")
            throw BunnyDNSError.unauthorized
        case HTTPStatusCode.forbidden:
            logger.error("Bunny: Forbidden (403) - \(responseString)")
            throw BunnyDNSError.forbidden
        case HTTPStatusCode.notFound:
            logger.error("Bunny: Not Found (404) - \(responseString)")
            throw BunnyDNSError.notFound
        case HTTPStatusCode.validation:
            logger.error("Bunny: Validation error (400) - \(responseString)")
            let decoder = JSONDecoder()
            if let errorResponse = try? decoder.decode(BunnyErrorResponse.self, from: data),
               let message = errorResponse.message {
                throw BunnyDNSError.validation(message)
            }
            throw BunnyDNSError.validation("Validation error")
        case HTTPStatusCode.rateLimited:
            logger.error("Bunny: Rate limited (429)")
            throw BunnyDNSError.rateLimited
        case HTTPStatusCode.badGateway,
             HTTPStatusCode.serviceUnavailable,
             HTTPStatusCode.gatewayTimeout:
            logger.error("Bunny: Server error (\(statusCode)) - \(responseString)")
            throw BunnyDNSError.serverError(statusCode, "Server error")
        default:
            logger.error("Bunny: Unexpected status (\(statusCode)) - \(responseString)")
            let decoder = JSONDecoder()
            if let errorResponse = try? decoder.decode(BunnyErrorResponse.self, from: data),
               let message = errorResponse.message {
                throw BunnyDNSError.apiError(message)
            }
            throw BunnyDNSError.serverError(statusCode, "HTTP \(statusCode)")
        }
    }

    func shouldRetry(_ error: BunnyDNSError) -> Bool {
        switch error {
        case .rateLimited, .serverError, .timeout, .networkError:
            return true
        case .unauthorized, .forbidden, .notFound, .validation, .apiError, .invalidResponse, .recordAlreadyExists, .unsupportedRecordType:
            return false
        }
    }
}

// MARK: - DNS Service

final class BunnyDNSService {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func createClient(apiKey: String) -> BaseDNSAPIClient<BunnyDNSAPIProvider> {
        let provider = BunnyDNSAPIProvider(apiKey: apiKey)
        return BaseDNSAPIClient(provider: provider, session: session)
    }

    // MARK: - Zones

    func listZones(apiKey: String) async throws -> [BunnyDNSZone] {
        logger.info("Listing Bunny DNS zones...")
        logger.debug("API Key length: \(apiKey.count) chars")

        let client = createClient(apiKey: apiKey)
        var allZones: [BunnyDNSZone] = []
        var currentPage = 1
        var hasMorePages = true

        while hasMorePages {
            do {
                logger.debug("Fetching page \(currentPage)...")
                let response: BunnyZonesResponse = try await client.request(
                    "dnszone?page=\(currentPage)&perPage=100",
                    method: "GET",
                    body: nil
                )
                logger.info("Page \(currentPage): \(response.items.count) zones, hasMore: \(response.hasMoreItems)")
                allZones.append(contentsOf: response.items)

                hasMorePages = response.hasMoreItems
                currentPage += 1
            } catch {
                logger.error("Error listing zones: \(error)")
                throw error
            }
        }

        logger.info("Total zones fetched: \(allZones.count)")
        return allZones
    }

    func getZone(zoneId: Int, apiKey: String) async throws -> BunnyZoneDetailResponse {
        let client = createClient(apiKey: apiKey)
        let response: BunnyZoneDetailResponse = try await client.request(
            "dnszone/\(zoneId)",
            method: "GET",
            body: nil
        )
        return response
    }

    // MARK: - Records

    func listDNSRecords(zoneId: Int, apiKey: String) async throws -> [BunnyDNSRecord] {
        let zone = try await getZone(zoneId: zoneId, apiKey: apiKey)
        return zone.records
    }

    func createDNSRecord(
        zoneId: Int,
        type: String,
        name: String,
        value: String,
        ttl: Int = 300,
        priority: Int? = nil,
        apiKey: String
    ) async throws -> BunnyDNSRecord {
        guard let recordType = BunnyRecordType.from(string: type) else {
            throw BunnyDNSError.unsupportedRecordType(type)
        }

        let client = createClient(apiKey: apiKey)

        // Bunny uses empty string for apex records
        let bunnyName = name == "@" ? "" : name

        let requestBody = BunnyCreateRecordRequest(
            type: recordType.rawValue,
            name: bunnyName,
            value: value,
            ttl: ttl,
            priority: priority
        )

        let encoder = JSONEncoder()
        guard let bodyData = try? encoder.encode(requestBody) else {
            throw BunnyDNSError.invalidResponse
        }

        let response: BunnyDNSRecord = try await client.request(
            "dnszone/\(zoneId)/records",
            method: "PUT",
            body: bodyData
        )

        return response
    }

    func deleteDNSRecord(
        zoneId: Int,
        recordId: Int,
        apiKey: String
    ) async throws {
        let client = createClient(apiKey: apiKey)
        let _: EmptyResponse = try await client.request(
            "dnszone/\(zoneId)/records/\(recordId)",
            method: "DELETE",
            body: nil
        )
    }
}
