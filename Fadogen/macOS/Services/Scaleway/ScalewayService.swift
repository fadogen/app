import Foundation
import CryptoKit

// MARK: - Scaleway Region

enum ScalewayRegion: String, CaseIterable, Sendable {
    case paris = "fr-par"
    case amsterdam = "nl-ams"
    case warsaw = "pl-waw"

    var displayName: String {
        switch self {
        case .paris: return "Paris"
        case .amsterdam: return "Amsterdam"
        case .warsaw: return "Warsaw"
        }
    }

    var endpoint: String {
        "https://s3.\(rawValue).scw.cloud"
    }

    var host: String {
        "s3.\(rawValue).scw.cloud"
    }
}

// MARK: - Scaleway Error

enum ScalewayError: Error, LocalizedError {
    case invalidCredentials
    case invalidRegion
    case bucketNotFound
    case bucketAlreadyExists
    case accessDenied
    case requestFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid Scaleway credentials"
        case .invalidRegion:
            return "Invalid Scaleway region"
        case .bucketNotFound:
            return "Bucket not found"
        case .bucketAlreadyExists:
            return "Bucket already exists"
        case .accessDenied:
            return "Access denied"
        case .requestFailed(let statusCode, let message):
            return "Request failed (\(statusCode)): \(message)"
        }
    }
}

// MARK: - Scaleway Service

final class ScalewayService {

    // MARK: - Public

    func validateCredentials(accessKey: String, secretKey: String, region: ScalewayRegion) async throws {
        _ = try await listBuckets(accessKey: accessKey, secretKey: secretKey, region: region)
    }

    func listBuckets(accessKey: String, secretKey: String, region: ScalewayRegion) async throws -> [String] {
        let request = try signedRequest(
            method: "GET",
            path: "/",
            accessKey: accessKey,
            secretKey: secretKey,
            region: region
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScalewayError.requestFailed(statusCode: 0, message: "Invalid response")
        }

        if httpResponse.statusCode == 403 {
            throw ScalewayError.accessDenied
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ScalewayError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        // Parse XML response to get bucket names
        return parseBucketList(from: data)
    }

    /// Check if bucket exists
    func bucketExists(name: String, accessKey: String, secretKey: String, region: ScalewayRegion) async throws -> Bool {
        let request = try signedRequest(
            method: "HEAD",
            path: "/\(name)",
            accessKey: accessKey,
            secretKey: secretKey,
            region: region
        )

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScalewayError.requestFailed(statusCode: 0, message: "Invalid response")
        }

        if httpResponse.statusCode == 200 {
            return true
        } else if httpResponse.statusCode == 404 {
            return false
        } else if httpResponse.statusCode == 403 {
            throw ScalewayError.accessDenied
        } else {
            throw ScalewayError.requestFailed(statusCode: httpResponse.statusCode, message: "HeadBucket failed")
        }
    }

    /// Create S3 bucket
    func createBucket(name: String, accessKey: String, secretKey: String, region: ScalewayRegion) async throws {
        let request = try signedRequest(
            method: "PUT",
            path: "/\(name)",
            accessKey: accessKey,
            secretKey: secretKey,
            region: region
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScalewayError.requestFailed(statusCode: 0, message: "Invalid response")
        }

        if httpResponse.statusCode == 409 {
            throw ScalewayError.bucketAlreadyExists
        }

        if httpResponse.statusCode == 403 {
            throw ScalewayError.accessDenied
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ScalewayError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }
    }

    // MARK: - AWS Signature V4

    private func signedRequest(
        method: String,
        path: String,
        accessKey: String,
        secretKey: String,
        region: ScalewayRegion,
        body: Data? = nil
    ) throws -> URLRequest {
        let host = region.host
        let service = "s3"
        let awsRegion = region.rawValue

        guard let url = URL(string: "\(region.endpoint)\(path)") else {
            throw ScalewayError.invalidRegion
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        // Date headers
        let now = Date()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        let dateStamp = dateFormatter.string(from: now).replacingOccurrences(of: "-", with: "")

        let amzDateFormatter = DateFormatter()
        amzDateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        amzDateFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = amzDateFormatter.string(from: now)

        // Content hash
        let payloadHash = sha256Hex(body ?? Data())

        // Headers to sign
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Canonical request
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalHeaders = """
        host:\(host)
        x-amz-content-sha256:\(payloadHash)
        x-amz-date:\(amzDate)

        """

        let canonicalRequest = """
        \(method)
        \(path)

        \(canonicalHeaders)
        \(signedHeaders)
        \(payloadHash)
        """

        // String to sign
        let credentialScope = "\(dateStamp)/\(awsRegion)/\(service)/aws4_request"
        let stringToSign = """
        AWS4-HMAC-SHA256
        \(amzDate)
        \(credentialScope)
        \(sha256Hex(canonicalRequest.data(using: .utf8)!))
        """

        // Signing key
        let kDate = hmacSHA256(key: "AWS4\(secretKey)".data(using: .utf8)!, data: dateStamp.data(using: .utf8)!)
        let kRegion = hmacSHA256(key: kDate, data: awsRegion.data(using: .utf8)!)
        let kService = hmacSHA256(key: kRegion, data: service.data(using: .utf8)!)
        let kSigning = hmacSHA256(key: kService, data: "aws4_request".data(using: .utf8)!)

        // Signature
        let signature = hmacSHA256Hex(key: kSigning, data: stringToSign.data(using: .utf8)!)

        // Authorization header
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        return request
    }

    // MARK: - Crypto Helpers

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(signature)
    }

    private func hmacSHA256Hex(key: Data, data: Data) -> String {
        let signature = hmacSHA256(key: key, data: data)
        return signature.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - XML Parsing

    private func parseBucketList(from data: Data) -> [String] {
        // Simple XML parsing for bucket names
        guard let xmlString = String(data: data, encoding: .utf8) else {
            return []
        }

        var buckets: [String] = []
        let pattern = "<Name>([^<]+)</Name>"

        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(xmlString.startIndex..., in: xmlString)
            let matches = regex.matches(in: xmlString, range: range)

            for match in matches {
                if let nameRange = Range(match.range(at: 1), in: xmlString) {
                    buckets.append(String(xmlString[nameRange]))
                }
            }
        }

        return buckets
    }
}
