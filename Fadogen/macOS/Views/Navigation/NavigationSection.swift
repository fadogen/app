import Foundation

enum MenuCategory {
    case production
    case development
    case none

    var title: String {
        switch self {
        case .production: String(localized: "PRODUCTION")
        case .development: String(localized: "DEVELOPMENT")
        case .none: ""
        }
    }
}

enum NavigationSection: String, CaseIterable, Identifiable {
    case projects = "Projects"
    case servers = "Servers"
    case integrations = "Integrations"
    case php = "PHP"
    case nodeBun = "Node.js & Bun"
    case databases = "Databases"
    case caches = "Caches"
    case reverb = "Reverb"
    case mail = "Mail"
    case caddy = "Caddy"
    case settings = "Settings"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .projects: String(localized: "Projects")
        case .servers: String(localized: "Servers")
        case .integrations: String(localized: "Integrations")
        case .php: String(localized: "PHP")
        case .nodeBun: String(localized: "Node.js & Bun")
        case .databases: String(localized: "Databases")
        case .caches: String(localized: "Caches")
        case .reverb: String(localized: "Reverb")
        case .mail: String(localized: "Mail")
        case .caddy: String(localized: "Caddy")
        case .settings: String(localized: "Settings")
        }
    }

    var category: MenuCategory {
        switch self {
        case .servers, .integrations:
            return .production
        case .php, .nodeBun, .databases, .caches, .reverb, .mail, .caddy:
            return .development
        case .projects, .settings:
            return .none
        }
    }

    static var standaloneItems: [NavigationSection] {
        [.projects]
    }

    static func items(for category: MenuCategory) -> [NavigationSection] {
        allCases.filter { $0.category == category && category != .none }
    }

    var icon: String {
        switch self {
        case .projects: "globe"
        case .servers: "server.rack"
        case .integrations: "puzzlepiece.extension"
        case .php: "doc.text.fill"
        case .nodeBun: "terminal.fill"
        case .databases: "cylinder.split.1x2"
        case .caches: "speedometer"
        case .reverb: "waveform"
        case .mail: "envelope"
        case .caddy: "network"
        case .settings: "gear"
        }
    }

    var assetName: String? {
        switch self {
        case .php: "php"
        case .nodeBun: "javascript"
        case .caddy: "caddy"
        default: nil
        }
    }
}
