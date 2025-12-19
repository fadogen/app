import Foundation
import SwiftData

enum ProjectDeploymentStatus: String, Codable {
    case notDeployed
    case deploying
    case deployed
    case failed
}

/// Production deployment data synced via CloudKit
@Model
final class DeployedProject {

    var id: UUID = UUID()
    var name: String = ""
    var gitRemoteURL: String?
    var gitBranch: String?

    // MARK: - Deployment Status

    var deploymentStatusRawValue: String = ProjectDeploymentStatus.notDeployed.rawValue

    var deploymentStatus: ProjectDeploymentStatus {
        get { ProjectDeploymentStatus(rawValue: deploymentStatusRawValue) ?? .notDeployed }
        set { deploymentStatusRawValue = newValue.rawValue }
    }

    var deploymentError: String?

    // MARK: - Server & DNS

    @Relationship(deleteRule: .nullify)
    var server: Server?

    /// FQDN (e.g., "app.example.com")
    var productionDomain: String?

    var dnsZoneName: String?
    var dnsZoneID: String?

    @Relationship(deleteRule: .nullify, inverse: \Integration.dnsZones)
    var dnsIntegration: Integration?

    /// For ACME DNS challenge
    @Relationship(deleteRule: .nullify, inverse: \Integration.traefikDNSZones)
    var traefikDNSIntegration: Integration?

    @Relationship(deleteRule: .nullify, inverse: \Integration.backupProjects)
    var backupIntegration: Integration?

    /// For cleanup on project deletion
    var createdDNSRecordIDs: [String] = []

    // MARK: - Secrets

    /// Backup to prevent loss on local deletion
    @Attribute(.allowsCloudEncryption)
    var envProductionContent: String?

    /// Docker Swarm stack name. Generated once, survives repo renames.
    var stackID: String?

    // MARK: - Cross-Store Linking

    /// Reference to LocalProject in local-only store
    var linkedLocalProjectID: UUID?

    // MARK: - Computed Properties

    var githubIdentifier: String? {
        gitRemoteURL?.githubIdentifier()
    }

    var githubOwner: String? {
        gitRemoteURL?.githubOwner
    }

    var githubRepo: String? {
        gitRemoteURL?.githubRepo
    }

    var gitHubURL: URL? {
        gitRemoteURL?.gitHubURL
    }

    // MARK: - Initialization

    init(name: String, gitRemoteURL: String? = nil, gitBranch: String? = nil) {
        self.id = UUID()
        self.name = name
        self.gitRemoteURL = gitRemoteURL
        self.gitBranch = gitBranch
    }

    func clearProductionConfiguration() {
        self.deploymentStatus = .notDeployed
        self.deploymentError = nil
        self.productionDomain = nil
        self.dnsZoneID = nil
        self.dnsZoneName = nil
        self.dnsIntegration = nil
        self.traefikDNSIntegration = nil
        self.backupIntegration = nil
        self.createdDNSRecordIDs = []
    }
}
