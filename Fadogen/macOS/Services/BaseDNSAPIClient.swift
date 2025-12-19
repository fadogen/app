import Foundation
import os

private let logger = Logger(subsystem: "app.fadogen", category: "BaseDNSAPIClient")

// MARK: - DNS API Provider Protocol

protocol DNSAPIProvider {
    associatedtype ErrorType: Error

    var baseURL: String { get }
    func configureAuth(for request: inout URLRequest)
    func handleHTTPStatus(_ statusCode: Int, data: Data) throws
    func shouldRetry(_ error: ErrorType) -> Bool
}

// MARK: - Retry Configuration

private enum RetryConfig {
    static let maxRetries = 3
    static let backoffDelays: [TimeInterval] = [2.0, 4.0, 8.0]
    static let jitterRange: ClosedRange<TimeInterval> = 0...1.0
}

// MARK: - Base DNS API Client

final class BaseDNSAPIClient<Provider: DNSAPIProvider> {

    private let provider: Provider
    private let session: URLSession

    init(provider: Provider, session: URLSession = .shared) {
        self.provider = provider
        self.session = session
    }

    // MARK: - Public

    func request<T: Codable>(
        _ endpoint: String,
        method: String,
        body: Data? = nil
    ) async throws -> T {
        var lastError: Provider.ErrorType?

        for attempt in 0...RetryConfig.maxRetries {
            do {
                try Task.checkCancellation()

                let result: T = try await performRequest(
                    endpoint: endpoint,
                    method: method,
                    body: body
                )

                return result

            } catch let error as Provider.ErrorType {
                lastError = error
                let shouldRetry = provider.shouldRetry(error) && attempt < RetryConfig.maxRetries

                if shouldRetry {
                    let delay = calculateBackoffDelay(attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
                    throw error
                }
            } catch {
                // Re-throw non-provider errors
                throw error
            }
        }

        // Should never reach here, but compiler needs it
        if let error = lastError {
            throw error
        }
        fatalError("Retry loop completed without result or error")
    }

    // MARK: - Private

    private func performRequest<T: Codable>(
        endpoint: String,
        method: String,
        body: Data?
    ) async throws -> T {
        let fullURL = provider.baseURL + endpoint

        guard let url = URL(string: fullURL) else {
            logger.error("Invalid URL: \(fullURL)")
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Fadogen/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        // Provider-specific auth configuration
        provider.configureAuth(for: &request)

        if let body = body {
            request.httpBody = body
            if let bodyString = String(data: body, encoding: .utf8) {
                logger.debug("[\(method)] \(fullURL) - Body: \(bodyString)")
            }
        } else {
            logger.debug("[\(method)] \(fullURL)")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type (not HTTPURLResponse)")
            throw URLError(.badServerResponse)
        }

        // Log response
        let responseString = String(data: data, encoding: .utf8) ?? "<binary data>"
        logger.debug("Response [\(httpResponse.statusCode)]: \(responseString)")

        // Provider-specific HTTP status handling
        try provider.handleHTTPStatus(httpResponse.statusCode, data: data)

        // Handle DELETE 204 No Content
        if method == "DELETE" && httpResponse.statusCode == 204 {
            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
        }

        // Decode response
        let decoder = JSONDecoder()
        do {
            let decoded = try decoder.decode(T.self, from: data)
            return decoded
        } catch {
            logger.error("JSON decode error for type \(String(describing: T.self)): \(error)")
            logger.error("Raw response: \(responseString)")
            throw error
        }
    }

    private func calculateBackoffDelay(attempt: Int) -> TimeInterval {
        let baseDelay = RetryConfig.backoffDelays[min(attempt, RetryConfig.backoffDelays.count - 1)]
        let jitter = TimeInterval.random(in: RetryConfig.jitterRange)
        return baseDelay + jitter
    }
}

// MARK: - Empty Response

struct EmptyResponse: Codable, Sendable {}
