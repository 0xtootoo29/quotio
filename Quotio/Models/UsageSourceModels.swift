import Foundation

nonisolated enum UsageSourceKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case relayKeyQuery
    case relayAPIStats
    case genericJSON

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .relayKeyQuery:
            return "Relay Key Query"
        case .relayAPIStats:
            return "Relay API Stats"
        case .genericJSON:
            return "Generic JSON"
        }
    }

    static func inferred(from statsURL: String) -> UsageSourceKind {
        let lowered = statsURL.lowercased()
        if lowered.contains("/admin-next/api-stats") || lowered.contains("api-stats") || lowered.contains("/apistats/") {
            return .relayAPIStats
        }
        if lowered.contains("key-query") || lowered.contains("relay/key-query") {
            return .relayKeyQuery
        }
        return .genericJSON
    }
}

nonisolated struct UsageSource: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var statsURL: String
    var kind: UsageSourceKind
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        statsURL: String,
        kind: UsageSourceKind? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.statsURL = statsURL
        self.kind = kind ?? UsageSourceKind.inferred(from: statsURL)
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    mutating func refreshKind() {
        kind = UsageSourceKind.inferred(from: statsURL)
    }

    func validate() -> [String] {
        var errors: [String] = []

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Name is required")
        }

        let trimmedURL = statsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            errors.append("Stats URL is required")
        } else if URL(string: trimmedURL) == nil {
            errors.append("Stats URL is invalid")
        }

        return errors
    }
}

nonisolated struct SourceModelUsage: Identifiable, Hashable, Sendable {
    let id: String
    let model: String
    let tokenCount: Int
    let requestCount: Int

    init(model: String, tokenCount: Int, requestCount: Int = 0) {
        self.id = model
        self.model = model
        self.tokenCount = tokenCount
        self.requestCount = requestCount
    }
}

nonisolated struct UsageSourceSnapshot: Identifiable, Hashable, Sendable {
    let sourceID: UUID
    let sourceName: String
    let fetchedAt: Date
    let allTimeTokens: Int?
    let dayTokens: Int?
    let weekTokens: Int?
    let monthTokens: Int?
    let modelsByPeriod: [TokenUsagePeriod: [SourceModelUsage]]
    let statusMessage: String?

    var id: UUID { sourceID }

    func tokens(for period: TokenUsagePeriod) -> Int? {
        switch period {
        case .day:
            return dayTokens
        case .week:
            return weekTokens
        case .month:
            return monthTokens
        }
    }

    func models(for period: TokenUsagePeriod) -> [SourceModelUsage] {
        modelsByPeriod[period] ?? []
    }

    var isHealthy: Bool {
        statusMessage == nil
    }

    var headline: String {
        if let monthTokens {
            return "M: \(monthTokens.formatted())"
        }
        if let weekTokens {
            return "W: \(weekTokens.formatted())"
        }
        if let dayTokens {
            return "D: \(dayTokens.formatted())"
        }
        if let allTimeTokens {
            return "All: \(allTimeTokens.formatted())"
        }
        return "No token data"
    }
}

nonisolated struct DiscoveredModel: Identifiable, Hashable, Sendable {
    let id: String
    let provider: String?
}
