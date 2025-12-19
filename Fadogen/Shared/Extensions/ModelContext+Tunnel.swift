import Foundation
import SwiftData

extension ModelContext {

    // MARK: - Tunnel Queries

    func fetchTunnel(for server: Server) throws -> CloudflareTunnel? {
        let serverID = server.id
        let predicate = #Predicate<CloudflareTunnel> { tunnel in
            tunnel.server?.id == serverID
        }

        let descriptor = FetchDescriptor<CloudflareTunnel>(predicate: predicate)
        let results = try fetch(descriptor)

        // Should only be one tunnel per server (one-to-one relationship)
        return results.first
    }

    func fetchTunnel(byTunnelID tunnelID: String) throws -> CloudflareTunnel? {
        let predicate = #Predicate<CloudflareTunnel> { tunnel in
            tunnel.tunnelID == tunnelID
        }

        let descriptor = FetchDescriptor<CloudflareTunnel>(predicate: predicate)
        let results = try fetch(descriptor)

        // Should only be one tunnel per Cloudflare tunnel ID (unique)
        return results.first
    }

    // MARK: - Statistics

    func tunnelCount() throws -> Int {
        let descriptor = FetchDescriptor<CloudflareTunnel>()
        return try fetchCount(descriptor)
    }

    func fetchTunnels(forZoneID zoneID: String) throws -> [CloudflareTunnel] {
        let predicate = #Predicate<CloudflareTunnel> { tunnel in
            tunnel.zoneID == zoneID
        }

        let descriptor = FetchDescriptor<CloudflareTunnel>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        return try fetch(descriptor)
    }
}
