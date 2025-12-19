import Foundation
import SwiftData

/// Local-only store (not synced to CloudKit)
@Model
final class WatchedDirectory {

    /// Only one entry per path (enforced in service layer)
    var path: String = ""

    @Relationship(deleteRule: .nullify, inverse: \LocalProject.watchedDirectory)
    var projects: [LocalProject]? = []

    init(path: String) {
        self.path = path
    }

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }
}
