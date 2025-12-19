import SwiftUI

/// Navigation destinations for the Sites section
/// Uses path-based navigation for top-level navigation only
enum ProjectDestination: Hashable {
    case newProject
    case projectDetail(localProject: LocalProject?, deployedProject: DeployedProject?)

    // MARK: - Factory Methods

    /// Create destination for a local project (with optional linked deployed project)
    static func local(_ project: LocalProject, linkedSite: DeployedProject? = nil) -> ProjectDestination {
        .projectDetail(localProject: project, deployedProject: linkedSite)
    }

    /// Create destination for a remote-only deployed project
    static func remote(_ deployedProject: DeployedProject) -> ProjectDestination {
        .projectDetail(localProject: nil, deployedProject: deployedProject)
    }
}
