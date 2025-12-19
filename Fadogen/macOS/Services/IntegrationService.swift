import Foundation
import SwiftData

@Observable
final class IntegrationService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func deduplicateIntegrations() {
        let allIntegrations = (try? modelContext.fetch(FetchDescriptor<Integration>())) ?? []

        // Group by integration type (typeRawValue)
        let grouped = Dictionary(grouping: allIntegrations, by: { $0.typeRawValue })

        var deletedCount = 0

        for (_, integrations) in grouped where integrations.count > 1 {
            // Sort by updatedAt descending (most recent first)
            let sorted = integrations.sorted { $0.updatedAt > $1.updatedAt }

            // Delete all duplicates, keeping the most recent
            for duplicate in sorted.dropFirst() {
                modelContext.delete(duplicate)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            try? modelContext.save()
        }
    }
}
