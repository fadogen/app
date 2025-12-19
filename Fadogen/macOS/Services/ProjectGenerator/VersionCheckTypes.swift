import Foundation

struct ServiceVersionStatus: Identifiable {
    let id = UUID()
    let serviceType: ServiceType
    let displayName: String
    let installedMajor: String?
    let recommendedMajor: String
    var shouldUpgrade: Bool

    var needsUpgrade: Bool {
        guard let installedMajor else { return false }
        return installedMajor != recommendedMajor
    }

    var isNewInstall: Bool {
        installedMajor == nil
    }
}

struct NodeVersionStatus: Identifiable {
    let id = UUID()
    let installedMajor: String?
    let recommendedMajor: String
    var shouldUpgrade: Bool

    var needsUpgrade: Bool {
        guard let installedMajor else { return false }
        return installedMajor != recommendedMajor
    }

    var isNewInstall: Bool {
        installedMajor == nil
    }
}

struct VersionCheckResult {
    var databaseStatus: ServiceVersionStatus?
    var cacheStatus: ServiceVersionStatus?
    var nodeStatus: NodeVersionStatus?

    var hasUpgradesNeeded: Bool {
        (databaseStatus?.needsUpgrade ?? false) ||
        (cacheStatus?.needsUpgrade ?? false) ||
        (nodeStatus?.needsUpgrade ?? false)
    }

    var servicesToUpgrade: [ServiceType] {
        var result: [ServiceType] = []
        if let db = databaseStatus, db.shouldUpgrade && db.needsUpgrade {
            result.append(db.serviceType)
        }
        if let cache = cacheStatus, cache.shouldUpgrade && cache.needsUpgrade {
            result.append(cache.serviceType)
        }
        return result
    }

    var shouldUpgradeNode: Bool {
        guard let nodeStatus else { return false }
        return nodeStatus.shouldUpgrade && nodeStatus.needsUpgrade
    }
}
