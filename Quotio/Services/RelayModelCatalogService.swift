import Foundation
import Observation

nonisolated struct RelayModelCatalogEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var providerName: String
    var baseURL: String
    var models: [String]
    var lastScannedAt: Date
    var lastError: String?
}

nonisolated struct RelayModelScanSummary: Sendable {
    let scannedProviders: Int
    let totalModels: Int
    let newModels: Int
    let failedProviders: Int

    static let empty = RelayModelScanSummary(scannedProviders: 0, totalModels: 0, newModels: 0, failedProviders: 0)
}

@MainActor
@Observable
final class RelayModelCatalogService {
    static let shared = RelayModelCatalogService()

    private(set) var entries: [UUID: RelayModelCatalogEntry] = [:]
    private(set) var lastScanAt: Date?
    private(set) var isScanning = false
    private(set) var lastError: String?

    private let storageKey = "relayModelCatalog.entries.v1"
    private let lastScanKey = "relayModelCatalog.lastScanAt.v1"
    private let autoScanInterval: TimeInterval = 24 * 60 * 60

    @ObservationIgnored private let discoveryService = ModelDiscoveryService()

    private init() {
        load()
    }

    func discoveredModelIDs(for providerID: UUID) -> [String] {
        entries[providerID]?.models ?? []
    }

    func scanConfiguredProviders(force: Bool = false) async -> RelayModelScanSummary {
        if isScanning {
            return .empty
        }

        if !force,
           let lastScanAt,
           Date().timeIntervalSince(lastScanAt) < autoScanInterval {
            return .empty
        }

        let configuredProviders = CustomProviderService.shared.providers.filter { provider in
            provider.isEnabled
                && !provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && provider.apiKeys.contains(where: { !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }

        guard !configuredProviders.isEmpty else {
            return .empty
        }

        isScanning = true
        defer { isScanning = false }

        var nextEntries = entries
        var scannedProviders = 0
        var totalModels = 0
        var newModels = 0
        var failedProviders = 0

        for provider in configuredProviders {
            let baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let token = provider.apiKeys.first(where: { !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.apiKey else {
                continue
            }

            scannedProviders += 1

            do {
                let models = try await discoveryService.fetchModels(baseURL: baseURL, token: token)
                let modelIDs = Array(Set(models.map { $0.id })).sorted()

                let previous = Set(nextEntries[provider.id]?.models ?? [])
                let current = Set(modelIDs)
                newModels += current.subtracting(previous).count
                totalModels += modelIDs.count

                nextEntries[provider.id] = RelayModelCatalogEntry(
                    id: provider.id,
                    providerName: provider.name,
                    baseURL: baseURL,
                    models: modelIDs,
                    lastScannedAt: Date(),
                    lastError: nil
                )
            } catch {
                failedProviders += 1
                nextEntries[provider.id] = RelayModelCatalogEntry(
                    id: provider.id,
                    providerName: provider.name,
                    baseURL: baseURL,
                    models: nextEntries[provider.id]?.models ?? [],
                    lastScannedAt: Date(),
                    lastError: error.localizedDescription
                )
                lastError = error.localizedDescription
            }
        }

        entries = nextEntries
        lastScanAt = Date()
        save()

        return RelayModelScanSummary(
            scannedProviders: scannedProviders,
            totalModels: totalModels,
            newModels: newModels,
            failedProviders: failedProviders
        )
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([RelayModelCatalogEntry].self, from: data) {
            entries = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } else {
            entries = [:]
        }

        lastScanAt = UserDefaults.standard.object(forKey: lastScanKey) as? Date
    }

    private func save() {
        let array = Array(entries.values)
        if let data = try? JSONEncoder().encode(array) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }

        UserDefaults.standard.set(lastScanAt, forKey: lastScanKey)
    }
}
