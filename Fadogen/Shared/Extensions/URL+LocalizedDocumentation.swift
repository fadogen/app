import Foundation

extension URL {
    /// Retourne une URL de documentation localisée avec préfixe de langue
    /// Ex: https://docs.fadogen.app/integrations/... → https://docs.fadogen.app/fr/integrations/...
    func localizedDocumentationURL() -> URL {
        let prefix = Locale.current.documentationPathPrefix

        // Si pas de préfixe (anglais ou autre), retourner l'URL originale
        guard !prefix.isEmpty else { return self }

        // Insérer le préfixe après le domaine
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }

        components.path = prefix + components.path
        return components.url ?? self
    }
}
