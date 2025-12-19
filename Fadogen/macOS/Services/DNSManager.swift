import Foundation
import SwiftData
import Observation

/// Supports: Cloudflare, DigitalOcean, Hetzner, Linode, Vultr, Bunny
@Observable
final class DNSManager {
    private let modelContext: ModelContext
    private let cloudflareService: CloudflareService
    private let digitalOceanDNSService: DigitalOceanDNSService
    private let hetznerDNSService: HetznerDNSService
    private let linodeDNSService: LinodeDNSService
    private let vultrDNSService: VultrDNSService
    private let bunnyDNSService: BunnyDNSService

    var isLoading = false
    var error: Error?

    init(
        modelContext: ModelContext,
        cloudflareService: CloudflareService = CloudflareService(),
        digitalOceanDNSService: DigitalOceanDNSService = DigitalOceanDNSService(),
        hetznerDNSService: HetznerDNSService = HetznerDNSService(),
        linodeDNSService: LinodeDNSService = LinodeDNSService(),
        vultrDNSService: VultrDNSService = VultrDNSService(),
        bunnyDNSService: BunnyDNSService = BunnyDNSService()
    ) {
        self.modelContext = modelContext
        self.cloudflareService = cloudflareService
        self.digitalOceanDNSService = digitalOceanDNSService
        self.hetznerDNSService = hetznerDNSService
        self.linodeDNSService = linodeDNSService
        self.vultrDNSService = vultrDNSService
        self.bunnyDNSService = bunnyDNSService
    }

    // MARK: - Zones

    func listZones(for integration: Integration) async throws -> [DNSZone] {
        guard integration.supports(.dns) else {
            throw DNSError.capabilityNotSupported
        }

        guard integration.isConfigured else {
            throw DNSError.integrationNotConfigured
        }

        isLoading = true
        defer { isLoading = false }

        switch integration.type {
        case .cloudflare:
            return try await listZonesCloudflare(integration)

        case .digitalocean:
            return try await listZonesDigitalOcean(integration)

        case .hetzner, .hetznerDNS:
            return try await listZonesHetzner(integration)

        case .linode:
            return try await listZonesLinode(integration)

        case .vultr:
            return try await listZonesVultr(integration)

        case .bunny:
            return try await listZonesBunny(integration)

        case .github, .scaleway, .dropbox:
            throw DNSError.notImplemented(integration.type.metadata.displayName)
        }
    }

    private func listZonesCloudflare(_ integration: Integration) async throws -> [DNSZone] {
        let zones = try await cloudflareService.listZones(integration: integration)

        return zones.map { zone in
            DNSZone(
                name: zone.name,
                id: zone.id,
                integration: integration
            )
        }
    }

    // MARK: - Records

    func listRecords(
        in zone: DNSZone,
        type: String? = nil,
        name: String? = nil,
        content: String? = nil
    ) async throws -> [DNSRecord] {
        let integration = zone.integration

        guard integration.supports(.dns) else {
            throw DNSError.capabilityNotSupported
        }

        isLoading = true
        defer { isLoading = false }

        switch integration.type {
        case .cloudflare:
            return try await listRecordsCloudflare(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content
            )

        case .digitalocean:
            return try await listRecordsDigitalOcean(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content
            )

        case .hetzner, .hetznerDNS:
            return try await listRecordsHetzner(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content
            )

        case .linode:
            return try await listRecordsLinode(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content
            )

        case .vultr:
            return try await listRecordsVultr(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content
            )

        case .bunny:
            return try await listRecordsBunny(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content
            )

        case .github, .scaleway, .dropbox:
            throw DNSError.notImplemented(integration.type.metadata.displayName)
        }
    }

    func createRecord(
        in zone: DNSZone,
        type: String,
        name: String,
        content: String,
        priority: Int? = nil,
        proxied: Bool? = nil
    ) async throws -> DNSRecord {
        let integration = zone.integration

        guard integration.supports(.dns) else {
            throw DNSError.capabilityNotSupported
        }

        isLoading = true
        defer { isLoading = false }

        switch integration.type {
        case .cloudflare:
            return try await createRecordCloudflare(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content,
                proxied: proxied
            )

        case .digitalocean:
            return try await createRecordDigitalOcean(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content,
                priority: priority
            )

        case .hetzner, .hetznerDNS:
            return try await createRecordHetzner(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content,
                priority: priority
            )

        case .linode:
            return try await createRecordLinode(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content,
                priority: priority
            )

        case .vultr:
            return try await createRecordVultr(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content,
                priority: priority
            )

        case .bunny:
            return try await createRecordBunny(
                integration,
                zone: zone,
                type: type,
                name: name,
                content: content,
                priority: priority
            )

        case .github, .scaleway, .dropbox:
            throw DNSError.notImplemented(integration.type.metadata.displayName)
        }
    }

    private func listRecordsCloudflare(
        _ integration: Integration,
        zone: DNSZone,
        type: String?,
        name: String?,
        content: String?
    ) async throws -> [DNSRecord] {
        guard let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey else {
            throw DNSError.integrationNotConfigured
        }

        let records = try await cloudflareService.listDNSRecords(
            zoneID: zone.id,
            type: type,
            name: name,
            content: content,
            email: email,
            apiKey: apiKey
        )

        return records.map { record in
            DNSRecord(
                id: record.id,
                type: record.type,
                name: record.name,
                content: record.content,
                priority: nil,
                proxied: record.proxied
            )
        }
    }

    private func createRecordCloudflare(
        _ integration: Integration,
        zone: DNSZone,
        type: String,
        name: String,
        content: String,
        proxied: Bool?
    ) async throws -> DNSRecord {
        guard let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey else {
            throw DNSError.integrationNotConfigured
        }

        // Normalize content for CNAME records (remove trailing dot from DNS canonical form)
        let normalizedContent = type == "CNAME"
            ? content.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            : content

        // Check if record already exists (idempotency)
        // Build FQDN for comparison (Cloudflare API returns full domain)
        let fqdn = name == "@" ? zone.name : "\(name).\(zone.name)"

        let existingRecords = try await cloudflareService.listDNSRecords(
            zoneID: zone.id,
            type: type,
            name: fqdn,
            content: nil,
            email: email,
            apiKey: apiKey
        )

        // If record exists with same content, return it (idempotent success)
        // Normalize existing content too for comparison
        if let existing = existingRecords.first(where: {
            $0.content.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == normalizedContent
        }) {
            return DNSRecord(
                id: existing.id,
                type: existing.type,
                name: existing.name,
                content: existing.content,
                priority: nil,
                proxied: existing.proxied
            )
        }

        // If record exists with different content, throw error
        if let existing = existingRecords.first {
            throw DNSError.recordAlreadyExists(
                type: existing.type,
                name: existing.name,
                existingContent: existing.content,
                requestedContent: normalizedContent
            )
        }

        // Record doesn't exist, create it
        let record = try await cloudflareService.createDNSRecord(
            zoneID: zone.id,
            type: type,
            name: name,
            content: normalizedContent,
            proxied: proxied ?? false,
            email: email,
            apiKey: apiKey
        )

        return DNSRecord(
            id: record.id,
            type: record.type,
            name: record.name,
            content: record.content,
            priority: nil,
            proxied: record.proxied
        )
    }

    func deleteRecord(_ record: DNSRecord, in zone: DNSZone) async throws {
        let integration = zone.integration

        guard integration.supports(.dns) else {
            throw DNSError.capabilityNotSupported
        }

        isLoading = true
        defer { isLoading = false }

        switch integration.type {
        case .cloudflare:
            try await deleteRecordCloudflare(integration, recordID: record.id, zoneID: zone.id)

        case .digitalocean:
            try await deleteRecordDigitalOcean(integration, domain: zone.name, recordID: record.id)

        case .hetzner, .hetznerDNS:
            try await deleteRecordHetzner(integration, recordID: record.id)

        case .linode:
            try await deleteRecordLinode(integration, zone: zone, recordID: record.id)

        case .vultr:
            try await deleteRecordVultr(integration, zone: zone, recordID: record.id)

        case .bunny:
            try await deleteRecordBunny(integration, zone: zone, recordID: record.id)

        case .github, .scaleway, .dropbox:
            throw DNSError.notImplemented(integration.type.metadata.displayName)
        }
    }

    private func deleteRecordCloudflare(_ integration: Integration, recordID: String, zoneID: String) async throws {
        guard let email = integration.credentials.email,
              let apiKey = integration.credentials.globalAPIKey else {
            throw DNSError.integrationNotConfigured
        }

        try await cloudflareService.deleteDNSRecord(
            recordID: recordID,
            zoneID: zoneID,
            email: email,
            apiKey: apiKey
        )
    }

    // MARK: - DigitalOcean Private Methods

    private func listZonesDigitalOcean(_ integration: Integration) async throws -> [DNSZone] {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        let domains = try await digitalOceanDNSService.listDomains(apiToken: token)

        return domains.map { domain in
            DNSZone(
                name: domain.name,
                id: domain.name, // DigitalOcean uses domain name as ID
                integration: integration
            )
        }
    }

    private func listRecordsDigitalOcean(
        _ integration: Integration,
        zone: DNSZone,
        type: String?,
        name: String?,
        content: String?
    ) async throws -> [DNSRecord] {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        // Get all records for the domain
        let records = try await digitalOceanDNSService.listDNSRecords(
            domain: zone.name,
            type: type,
            name: name,
            apiToken: token
        )

        // Filter by content if needed (DigitalOcean API doesn't support content filter)
        var filteredRecords = records
        if let content = content {
            filteredRecords = records.filter { $0.data == content }
        }

        return filteredRecords.map { record in
            DNSRecord(
                id: String(record.id),
                type: record.type,
                name: record.name,
                content: record.data,
                priority: record.priority,
                proxied: nil // DigitalOcean doesn't support proxying
            )
        }
    }

    private func createRecordDigitalOcean(
        _ integration: Integration,
        zone: DNSZone,
        type: String,
        name: String,
        content: String,
        priority: Int?
    ) async throws -> DNSRecord {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        // Check if record already exists (idempotency)
        // DigitalOcean uses the subdomain part for name, not FQDN
        let existingRecords = try await digitalOceanDNSService.listDNSRecords(
            domain: zone.name,
            type: type,
            name: name,
            apiToken: token
        )

        // If record exists with same content, return it (idempotent success)
        if let existing = existingRecords.first(where: { $0.data == content }) {
            return DNSRecord(
                id: String(existing.id),
                type: existing.type,
                name: existing.name,
                content: existing.data,
                priority: existing.priority,
                proxied: nil
            )
        }

        // If record exists with different content, throw error
        if let existing = existingRecords.first {
            throw DNSError.recordAlreadyExists(
                type: existing.type,
                name: existing.name,
                existingContent: existing.data,
                requestedContent: content
            )
        }

        // Record doesn't exist, create it
        let record = try await digitalOceanDNSService.createDNSRecord(
            domain: zone.name,
            type: type,
            name: name,
            data: content,
            priority: priority,
            apiToken: token
        )

        return DNSRecord(
            id: String(record.id),
            type: record.type,
            name: record.name,
            content: record.data,
            priority: record.priority,
            proxied: nil
        )
    }

    private func deleteRecordDigitalOcean(
        _ integration: Integration,
        domain: String,
        recordID: String
    ) async throws {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        guard let recordIDInt = Int(recordID) else {
            throw DNSError.apiError("Invalid record ID format")
        }

        try await digitalOceanDNSService.deleteDNSRecord(
            domain: domain,
            recordID: recordIDInt,
            apiToken: token
        )
    }

    // MARK: - Hetzner Private Methods

    private func listZonesHetzner(_ integration: Integration) async throws -> [DNSZone] {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        let zones = try await hetznerDNSService.listZones(apiToken: token)

        return zones.map { zone in
            DNSZone(
                name: zone.name,
                id: zone.id,
                integration: integration
            )
        }
    }

    private func listRecordsHetzner(
        _ integration: Integration,
        zone: DNSZone,
        type: String?,
        name: String?,
        content: String?
    ) async throws -> [DNSRecord] {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        // Get all records for the zone
        let records = try await hetznerDNSService.listDNSRecords(
            zoneID: zone.id,
            apiToken: token
        )

        // Filter by type, name, and content (Hetzner API doesn't support filtering)
        var filteredRecords = records
        if let type = type {
            filteredRecords = filteredRecords.filter { $0.type == type }
        }
        if let name = name {
            filteredRecords = filteredRecords.filter { $0.name == name }
        }
        if let content = content {
            filteredRecords = filteredRecords.filter { $0.value == content }
        }

        return filteredRecords.map { record in
            DNSRecord(
                id: record.id,
                type: record.type,
                name: record.name,
                content: record.value,
                priority: nil,
                proxied: nil
            )
        }
    }

    private func createRecordHetzner(
        _ integration: Integration,
        zone: DNSZone,
        type: String,
        name: String,
        content: String,
        priority: Int?
    ) async throws -> DNSRecord {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        // Check if record already exists (idempotency)
        let existingRecords = try await hetznerDNSService.listDNSRecords(
            zoneID: zone.id,
            apiToken: token
        )

        // Filter by type and name
        let matchingRecords = existingRecords.filter { $0.type == type && $0.name == name }

        // If record exists with same content, return it (idempotent success)
        if let existing = matchingRecords.first(where: { $0.value == content }) {
            return DNSRecord(
                id: existing.id,
                type: existing.type,
                name: existing.name,
                content: existing.value,
                priority: nil,
                proxied: nil
            )
        }

        // If record exists with different content, throw error
        if let existing = matchingRecords.first {
            throw DNSError.recordAlreadyExists(
                type: existing.type,
                name: existing.name,
                existingContent: existing.value,
                requestedContent: content
            )
        }

        // Record doesn't exist, create it
        let record = try await hetznerDNSService.createDNSRecord(
            zoneID: zone.id,
            type: type,
            name: name,
            value: content,
            apiToken: token
        )

        return DNSRecord(
            id: record.id,
            type: record.type,
            name: record.name,
            content: record.value,
            priority: nil,
            proxied: nil
        )
    }

    private func deleteRecordHetzner(
        _ integration: Integration,
        recordID: String
    ) async throws {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        try await hetznerDNSService.deleteDNSRecord(
            recordID: recordID,
            apiToken: token
        )
    }

    // MARK: - Linode Private Methods

    private func listZonesLinode(_ integration: Integration) async throws -> [DNSZone] {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        let domains = try await linodeDNSService.listDomains(apiToken: token)

        return domains.map { domain in
            DNSZone(
                name: domain.domain,
                id: String(domain.id),
                integration: integration
            )
        }
    }

    private func listRecordsLinode(
        _ integration: Integration,
        zone: DNSZone,
        type: String?,
        name: String?,
        content: String?
    ) async throws -> [DNSRecord] {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        guard let domainId = Int(zone.id) else {
            throw DNSError.apiError("Invalid zone ID format")
        }

        // Get all records for the domain
        let records = try await linodeDNSService.listDNSRecords(
            domainId: domainId,
            apiToken: token
        )

        // Filter by type, name, and content (Linode API doesn't support filtering)
        var filteredRecords = records
        if let type = type {
            filteredRecords = filteredRecords.filter { $0.type == type }
        }
        if let name = name {
            let normalizedName = normalizeRecordName(name, zone: zone)
            filteredRecords = filteredRecords.filter { $0.name == normalizedName }
        }
        if let content = content {
            filteredRecords = filteredRecords.filter { $0.target == content }
        }

        return filteredRecords.map { record in
            DNSRecord(
                id: String(record.id),
                type: record.type,
                // Convert "" back to "@" for apex records
                name: record.name.isEmpty ? "@" : record.name,
                content: record.target,
                priority: record.priority,
                proxied: nil
            )
        }
    }

    private func createRecordLinode(
        _ integration: Integration,
        zone: DNSZone,
        type: String,
        name: String,
        content: String,
        priority: Int?
    ) async throws -> DNSRecord {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        guard let domainId = Int(zone.id) else {
            throw DNSError.apiError("Invalid zone ID format")
        }

        // Linode uses "" for apex, not "@"
        let linodeName = name == "@" ? "" : name

        // Check if record already exists (idempotency)
        let existingRecords = try await linodeDNSService.listDNSRecords(
            domainId: domainId,
            apiToken: token
        )

        // Filter by type and name
        let matchingRecords = existingRecords.filter { $0.type == type && $0.name == linodeName }

        // If record exists with same content, return it (idempotent success)
        if let existing = matchingRecords.first(where: { $0.target == content }) {
            return DNSRecord(
                id: String(existing.id),
                type: existing.type,
                name: existing.name.isEmpty ? "@" : existing.name,
                content: existing.target,
                priority: existing.priority,
                proxied: nil
            )
        }

        // If record exists with different content, throw error
        if let existing = matchingRecords.first {
            throw DNSError.recordAlreadyExists(
                type: existing.type,
                name: existing.name.isEmpty ? "@" : existing.name,
                existingContent: existing.target,
                requestedContent: content
            )
        }

        // Record doesn't exist, create it
        let record = try await linodeDNSService.createDNSRecord(
            domainId: domainId,
            type: type,
            name: linodeName,
            target: content,
            priority: priority,
            apiToken: token
        )

        return DNSRecord(
            id: String(record.id),
            type: record.type,
            name: record.name.isEmpty ? "@" : record.name,
            content: record.target,
            priority: record.priority,
            proxied: nil
        )
    }

    private func deleteRecordLinode(
        _ integration: Integration,
        zone: DNSZone,
        recordID: String
    ) async throws {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        guard let domainId = Int(zone.id) else {
            throw DNSError.apiError("Invalid zone ID format")
        }

        guard let recordIdInt = Int(recordID) else {
            throw DNSError.apiError("Invalid record ID format")
        }

        try await linodeDNSService.deleteDNSRecord(
            domainId: domainId,
            recordId: recordIdInt,
            apiToken: token
        )
    }

    // MARK: - Vultr Private Methods

    private func listZonesVultr(_ integration: Integration) async throws -> [DNSZone] {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        let domains = try await vultrDNSService.listDomains(apiToken: token)

        return domains.map { domain in
            DNSZone(
                name: domain.domain,
                id: domain.domain, // Vultr uses domain name as ID
                integration: integration
            )
        }
    }

    private func listRecordsVultr(
        _ integration: Integration,
        zone: DNSZone,
        type: String?,
        name: String?,
        content: String?
    ) async throws -> [DNSRecord] {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        // Get all records for the domain
        let records = try await vultrDNSService.listDNSRecords(
            domain: zone.name,
            apiToken: token
        )

        // Filter by type, name, and content (Vultr API doesn't support filtering)
        var filteredRecords = records
        if let type = type {
            filteredRecords = filteredRecords.filter { $0.type == type }
        }
        if let name = name {
            let normalizedName = normalizeRecordName(name, zone: zone)
            filteredRecords = filteredRecords.filter { $0.name == normalizedName }
        }
        if let content = content {
            filteredRecords = filteredRecords.filter { $0.data == content }
        }

        return filteredRecords.map { record in
            DNSRecord(
                id: record.id,
                type: record.type,
                // Convert "" back to "@" for apex records
                name: record.name.isEmpty ? "@" : record.name,
                content: record.data,
                priority: record.priority,
                proxied: nil
            )
        }
    }

    private func createRecordVultr(
        _ integration: Integration,
        zone: DNSZone,
        type: String,
        name: String,
        content: String,
        priority: Int?
    ) async throws -> DNSRecord {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        // Vultr uses "" for apex, not "@"
        let vultrName = name == "@" ? "" : name

        // Check if record already exists (idempotency)
        let existingRecords = try await vultrDNSService.listDNSRecords(
            domain: zone.name,
            apiToken: token
        )

        // Filter by type and name
        let matchingRecords = existingRecords.filter { $0.type == type && $0.name == vultrName }

        // If record exists with same content, return it (idempotent success)
        if let existing = matchingRecords.first(where: { $0.data == content }) {
            return DNSRecord(
                id: existing.id,
                type: existing.type,
                name: existing.name.isEmpty ? "@" : existing.name,
                content: existing.data,
                priority: existing.priority,
                proxied: nil
            )
        }

        // If record exists with different content, throw error
        if let existing = matchingRecords.first {
            throw DNSError.recordAlreadyExists(
                type: existing.type,
                name: existing.name.isEmpty ? "@" : existing.name,
                existingContent: existing.data,
                requestedContent: content
            )
        }

        // Record doesn't exist, create it
        let record = try await vultrDNSService.createDNSRecord(
            domain: zone.name,
            type: type,
            name: vultrName,
            data: content,
            priority: priority,
            apiToken: token
        )

        return DNSRecord(
            id: record.id,
            type: record.type,
            name: record.name.isEmpty ? "@" : record.name,
            content: record.data,
            priority: record.priority,
            proxied: nil
        )
    }

    private func deleteRecordVultr(
        _ integration: Integration,
        zone: DNSZone,
        recordID: String
    ) async throws {
        guard let token = integration.credentials.token else {
            throw DNSError.integrationNotConfigured
        }

        try await vultrDNSService.deleteDNSRecord(
            domain: zone.name,
            recordId: recordID,
            apiToken: token
        )
    }

    // MARK: - Bunny Private Methods

    private func listZonesBunny(_ integration: Integration) async throws -> [DNSZone] {
        guard let apiKey = integration.credentials.apiKey else {
            throw DNSError.integrationNotConfigured
        }

        let zones = try await bunnyDNSService.listZones(apiKey: apiKey)

        return zones.map { zone in
            DNSZone(
                name: zone.domain,
                id: String(zone.id),
                integration: integration
            )
        }
    }

    private func listRecordsBunny(
        _ integration: Integration,
        zone: DNSZone,
        type: String?,
        name: String?,
        content: String?
    ) async throws -> [DNSRecord] {
        guard let apiKey = integration.credentials.apiKey else {
            throw DNSError.integrationNotConfigured
        }

        guard let zoneId = Int(zone.id) else {
            throw DNSError.apiError("Invalid zone ID format")
        }

        // Get all records for the zone
        let records = try await bunnyDNSService.listDNSRecords(
            zoneId: zoneId,
            apiKey: apiKey
        )

        // Filter by type, name, and content (Bunny API doesn't support filtering)
        var filteredRecords = records
        if let type = type {
            filteredRecords = filteredRecords.filter { $0.typeString == type }
        }
        if let name = name {
            let normalizedName = normalizeRecordName(name, zone: zone)
            filteredRecords = filteredRecords.filter { $0.name == normalizedName }
        }
        if let content = content {
            filteredRecords = filteredRecords.filter { $0.value == content }
        }

        return filteredRecords.map { record in
            DNSRecord(
                id: String(record.id),
                type: record.typeString,
                // Convert "" back to "@" for apex records
                name: record.name.isEmpty ? "@" : record.name,
                content: record.value,
                priority: record.priority,
                proxied: nil
            )
        }
    }

    private func createRecordBunny(
        _ integration: Integration,
        zone: DNSZone,
        type: String,
        name: String,
        content: String,
        priority: Int?
    ) async throws -> DNSRecord {
        guard let apiKey = integration.credentials.apiKey else {
            throw DNSError.integrationNotConfigured
        }

        guard let zoneId = Int(zone.id) else {
            throw DNSError.apiError("Invalid zone ID format")
        }

        // Bunny uses "" for apex, not "@"
        let bunnyName = name == "@" ? "" : name

        // Check if record already exists (idempotency)
        let existingRecords = try await bunnyDNSService.listDNSRecords(
            zoneId: zoneId,
            apiKey: apiKey
        )

        // Filter by type and name
        let matchingRecords = existingRecords.filter {
            $0.typeString == type && $0.name == bunnyName
        }

        // If record exists with same content, return it (idempotent success)
        if let existing = matchingRecords.first(where: { $0.value == content }) {
            return DNSRecord(
                id: String(existing.id),
                type: existing.typeString,
                name: existing.name.isEmpty ? "@" : existing.name,
                content: existing.value,
                priority: existing.priority,
                proxied: nil
            )
        }

        // If record exists with different content, throw error
        if let existing = matchingRecords.first {
            throw DNSError.recordAlreadyExists(
                type: existing.typeString,
                name: existing.name.isEmpty ? "@" : existing.name,
                existingContent: existing.value,
                requestedContent: content
            )
        }

        // Record doesn't exist, create it
        let record = try await bunnyDNSService.createDNSRecord(
            zoneId: zoneId,
            type: type,
            name: bunnyName,
            value: content,
            priority: priority,
            apiKey: apiKey
        )

        return DNSRecord(
            id: String(record.id),
            type: record.typeString,
            name: record.name.isEmpty ? "@" : record.name,
            content: record.value,
            priority: record.priority,
            proxied: nil
        )
    }

    private func deleteRecordBunny(
        _ integration: Integration,
        zone: DNSZone,
        recordID: String
    ) async throws {
        guard let apiKey = integration.credentials.apiKey else {
            throw DNSError.integrationNotConfigured
        }

        guard let zoneId = Int(zone.id) else {
            throw DNSError.apiError("Invalid zone ID format")
        }

        guard let recordIdInt = Int(recordID) else {
            throw DNSError.apiError("Invalid record ID format")
        }

        try await bunnyDNSService.deleteDNSRecord(
            zoneId: zoneId,
            recordId: recordIdInt,
            apiKey: apiKey
        )
    }

    // MARK: - Helpers

    /// Vultr/Linode/Bunny use "" for apex instead of "@"
    private func normalizeRecordName(_ name: String, zone: DNSZone) -> String {
        if name == "@" || name == zone.name {
            return ""
        } else if name.hasSuffix(".\(zone.name)") {
            return String(name.dropLast(zone.name.count + 1))
        } else {
            return name
        }
    }

    // MARK: - Cleanup

    @discardableResult
    func deleteProjectDNSRecords(for deployedProject: DeployedProject) async -> Bool {
        guard !deployedProject.createdDNSRecordIDs.isEmpty,
              let dnsZoneID = deployedProject.dnsZoneID,
              let dnsZoneName = deployedProject.dnsZoneName,
              let dnsIntegration = deployedProject.dnsIntegration else {
            return true // Nothing to delete
        }

        let zone = DNSZone(name: dnsZoneName, id: dnsZoneID, integration: dnsIntegration)

        guard let allRecords = try? await listRecords(in: zone) else {
            return false
        }

        // Protected record types that should NEVER be deleted
        let protectedTypes = ["NS", "SOA"]

        // Delete only records created by Fadogen (tracked IDs)
        for record in allRecords where deployedProject.createdDNSRecordIDs.contains(record.id) {
            // Additional safety check: never delete NS/SOA records
            guard !protectedTypes.contains(record.type) else { continue }
            try? await deleteRecord(record, in: zone)
        }

        return true
    }
}
