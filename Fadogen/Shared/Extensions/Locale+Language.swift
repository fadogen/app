import Foundation

extension Locale {
    /// Retourne le code de langue système avec fallback sur "en"
    /// Utilisé pour la détection de langue dans toute l'app
    var safeLanguageCode: String {
        language.languageCode?.identifier ?? "en"
    }

    /// Retourne le préfixe de chemin pour les URLs de documentation
    /// - Returns: "/fr" pour français, "/de" pour allemand, "" pour anglais et autres
    var documentationPathPrefix: String {
        switch safeLanguageCode {
        case "fr": return "/fr"
        case "de": return "/de"
        default: return ""
        }
    }
}
