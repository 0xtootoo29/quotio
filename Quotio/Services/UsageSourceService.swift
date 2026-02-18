import Foundation
import SwiftUI

@MainActor
@Observable
final class UsageSourceService {
    static let shared = UsageSourceService()

    private(set) var sources: [UsageSource] = []
    private(set) var lastError: String?

    private let storageKey = "usageSources.v1"

    private init() {
        loadSources()
    }

    var enabledSources: [UsageSource] {
        sources.filter(\.isEnabled)
    }

    func addSource(name: String, statsURL: String, token: String, isEnabled: Bool = true) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = statsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        var source = UsageSource(
            name: trimmedName,
            statsURL: trimmedURL,
            kind: UsageSourceKind.inferred(from: trimmedURL),
            isEnabled: isEnabled
        )
        source.refreshKind()

        let errors = source.validate()
        guard errors.isEmpty else {
            lastError = errors.joined(separator: "\n")
            return
        }

        guard !trimmedToken.isEmpty else {
            lastError = "Token 不能为空"
            return
        }

        sources.append(source)
        saveSources()
        _ = KeychainHelper.saveUsageSourceToken(trimmedToken, for: source.id)
        lastError = nil
    }

    func updateSource(_ source: UsageSource, token: String?) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else {
            lastError = "未找到该数据源"
            return
        }

        var updated = source
        updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.statsURL = updated.statsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.refreshKind()
        updated.updatedAt = Date()

        let errors = updated.validate()
        guard errors.isEmpty else {
            lastError = errors.joined(separator: "\n")
            return
        }

        if let token {
            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedToken.isEmpty {
                KeychainHelper.deleteUsageSourceToken(for: updated.id)
            } else {
                _ = KeychainHelper.saveUsageSourceToken(trimmedToken, for: updated.id)
            }
        }

        sources[index] = updated
        saveSources()
        lastError = nil
    }

    func deleteSource(id: UUID) {
        sources.removeAll { $0.id == id }
        saveSources()
        KeychainHelper.deleteUsageSourceToken(for: id)
    }

    func toggleSource(id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled.toggle()
        sources[index].updatedAt = Date()
        saveSources()
    }

    func token(for sourceID: UUID) -> String? {
        KeychainHelper.getUsageSourceToken(for: sourceID)
    }

    func setToken(_ token: String, for sourceID: UUID) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.deleteUsageSourceToken(for: sourceID)
            return
        }
        _ = KeychainHelper.saveUsageSourceToken(trimmed, for: sourceID)
    }

    private func loadSources() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            sources = []
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decodedSources = try decoder.decode([UsageSource].self, from: data)
            var migratedSources: [UsageSource] = []
            migratedSources.reserveCapacity(decodedSources.count)
            var hasMigrationChanges = false

            for source in decodedSources {
                var migrated = source
                let originalURL = source.statsURL
                let originalKind = source.kind
                let trimmedURL = originalURL.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmedURL != originalURL {
                    migrated.statsURL = trimmedURL
                    hasMigrationChanges = true
                }

                migrated.refreshKind()
                if migrated.kind != originalKind {
                    hasMigrationChanges = true
                }

                migratedSources.append(migrated)
            }

            sources = migratedSources
            if hasMigrationChanges {
                saveSources()
            }
        } catch {
            sources = []
            lastError = "加载数据源失败：\(error.localizedDescription)"
        }
    }

    private func saveSources() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(sources)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            lastError = "保存数据源失败：\(error.localizedDescription)"
        }
    }
}
