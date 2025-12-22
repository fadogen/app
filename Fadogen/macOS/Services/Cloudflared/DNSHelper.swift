import Foundation
import Subprocess
import System
import OSLog

/// DNS resolution helper that bypasses system DNS cache.
/// Uses dig to prevent negative caching in mDNSResponder, which would cause
/// Firefox/Chrome to fail even after DNS propagates (Safari uses CFNetwork
/// which has different caching behavior).
enum DNSHelper {
    private static let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "dns-helper")

    /// Wait for DNS to resolve (prevents browser negative caching)
    static func waitForDNS(hostname: String, maxAttempts: Int = 20, intervalMs: Int = 250) async {
        for attempt in 1...maxAttempts {
            if await checkDNS(hostname: hostname) {
                logger.debug("DNS resolved for \(hostname) after \(attempt) attempts")
                return
            }
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }
        logger.warning("DNS not resolved for \(hostname) after \(maxAttempts) attempts")
    }

    /// Check if DNS resolves for a hostname using dig (bypasses system DNS cache).
    static func checkDNS(hostname: String) async -> Bool {
        do {
            let result = try await Subprocess.run(
                .path("/usr/bin/dig"),
                arguments: ["+short", hostname],
                output: .bytes(limit: 1024),
                error: .discarded
            )

            guard result.terminationStatus.isSuccess else {
                return false
            }

            let output = String(bytes: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // dig +short returns IP addresses or CNAME targets
            // Empty output means no record found
            return !output.isEmpty && output.contains(where: \.isNumber)
        } catch {
            return false
        }
    }
}
