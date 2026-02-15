//
//  CRSQuotaFetcher.swift
//  Quotio
//
//  Fetches relay quota stats from CRS admin APIs.
//

import Foundation

actor CRSQuotaFetcher {
    private struct RelayTarget: Sendable {
        let accountKey: String
        let apiKey: String
        let statsBaseURL: String
        let pathPrefixes: [String]
    }

    private var session: URLSession

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        let targets = await relayTargets()
        guard !targets.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, ProviderQuotaData?).self) { group in
            for target in targets {
                group.addTask { [weak self] in
                    guard let self else { return (target.accountKey, nil) }
                    let quota = await self.fetchQuota(for: target)
                    return (target.accountKey, quota)
                }
            }

            var results: [String: ProviderQuotaData] = [:]
            for await (accountKey, quotaData) in group {
                if let quotaData {
                    results[accountKey] = quotaData
                }
            }
            return results
        }
    }

    private func relayTargets() async -> [RelayTarget] {
        let providers = await MainActor.run {
            CustomProviderService.shared.providers.filter { $0.type == .claudeCompatibility && $0.isEnabled }
        }

        var targets: [RelayTarget] = []
        for provider in providers {
            let trimmedName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let providerDisplayName = trimmedName.isEmpty ? "Claude Relay" : trimmedName

            for (index, keyEntry) in provider.apiKeys.enumerated() {
                let apiKey = keyEntry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !apiKey.isEmpty else { continue }

                guard let statsConfig = resolveStatsBaseConfiguration(provider: provider, keyEntry: keyEntry) else {
                    continue
                }

                let accountKey: String
                if provider.apiKeys.count > 1 {
                    accountKey = "\(providerDisplayName) #\(index + 1)"
                } else {
                    accountKey = providerDisplayName
                }

                targets.append(
                    RelayTarget(
                        accountKey: accountKey,
                        apiKey: apiKey,
                        statsBaseURL: statsConfig.baseURL,
                        pathPrefixes: statsConfig.pathPrefixes
                    )
                )
            }
        }
        return targets
    }

    private func resolveStatsBaseConfiguration(provider: CustomProvider, keyEntry: CustomAPIKeyEntry) -> (baseURL: String, pathPrefixes: [String])? {
        let candidates: [String?] = [keyEntry.proxyURL, provider.baseURL]

        for candidate in candidates {
            guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty,
                  let url = normalizedURL(from: candidate),
                  let host = url.host?.lowercased() else {
                continue
            }

            let scheme = (url.scheme?.lowercased().isEmpty == false) ? (url.scheme?.lowercased() ?? "https") : "https"
            var base = "\(scheme)://\(host)"
            if let port = url.port {
                base += ":\(port)"
            }
            return (baseURL: base, pathPrefixes: endpointPathPrefixes(from: url.path))
        }

        return nil
    }

    private func endpointPathPrefixes(from rawPath: String) -> [String] {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath: String

        if trimmedPath.isEmpty || trimmedPath == "/" {
            normalizedPath = ""
        } else {
            normalizedPath = "/" + trimmedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        var prefixes: [String] = [""]

        if !normalizedPath.isEmpty {
            prefixes.append(normalizedPath)

            if normalizedPath.hasSuffix("/v1") {
                let dropped = String(normalizedPath.dropLast(3))
                let maybeBasePath = dropped.isEmpty ? "" : dropped
                prefixes.append(maybeBasePath)
            }
        }

        if !prefixes.contains("/api") {
            prefixes.append("/api")
        }

        var deduped: [String] = []
        var seen = Set<String>()
        for prefix in prefixes {
            if seen.insert(prefix).inserted {
                deduped.append(prefix)
            }
        }
        return deduped
    }

    private func normalizedURL(from raw: String) -> URL? {
        if let url = URL(string: raw), url.host != nil {
            return url
        }
        return URL(string: "https://" + raw)
    }

    private func fetchQuota(for target: RelayTarget) async -> ProviderQuotaData? {
        do {
            let apiID = try await fetchAPIID(target: target)
            let statsPayload = try await fetchUserStats(target: target, apiID: apiID)
            return quotaData(from: statsPayload)
        } catch {
            Log.quota("CRS quota fetch failed for \(target.accountKey): \(error.localizedDescription)")
            return unavailableQuotaData(reason: error.localizedDescription)
        }
    }

    private func fetchAPIID(target: RelayTarget) async throws -> String {
        var lastError: Error = QuotaFetchError.invalidResponse

        for prefix in target.pathPrefixes {
            guard let url = URL(string: target.statsBaseURL + prefix + "/apiStats/api/get-key-id") else {
                continue
            }

            do {
                let payload = try await postJSON(url: url, body: ["apiKey": target.apiKey])
                if let success = payload["success"] as? Bool, !success {
                    let message = (payload["message"] as? String) ?? "Failed to resolve apiId"
                    throw QuotaFetchError.apiErrorMessage(message)
                }

                if let apiID = extractAPIID(from: payload) {
                    return apiID
                }
                throw QuotaFetchError.invalidResponse
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError
    }

    private func fetchUserStats(target: RelayTarget, apiID: String) async throws -> [String: Any] {
        var lastError: Error = QuotaFetchError.invalidResponse

        for prefix in target.pathPrefixes {
            guard let url = URL(string: target.statsBaseURL + prefix + "/apiStats/api/user-stats") else {
                continue
            }

            do {
                let payload = try await postJSON(url: url, body: ["apiId": apiID])
                if let success = payload["success"] as? Bool, !success {
                    let message = (payload["message"] as? String) ?? "Failed to fetch user stats"
                    throw QuotaFetchError.apiErrorMessage(message)
                }
                return payload
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError
    }

    private func postJSON(url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuotaFetchError.invalidResponse
        }
        guard 200...299 ~= httpResponse.statusCode else {
            throw QuotaFetchError.httpError(httpResponse.statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data)
        guard let payload = json as? [String: Any] else {
            throw QuotaFetchError.invalidResponse
        }
        return payload
    }

    private func extractAPIID(from payload: [String: Any]) -> String? {
        if let value = payload["apiId"] as? String, !value.isEmpty {
            return value
        }
        if let value = payload["id"] as? String, !value.isEmpty {
            return value
        }

        if let data = payload["data"] as? String, !data.isEmpty {
            return data
        }

        if let data = payload["data"] as? [String: Any] {
            if let value = data["apiId"] as? String, !value.isEmpty {
                return value
            }
            if let value = data["id"] as? String, !value.isEmpty {
                return value
            }
        }

        if let data = payload["data"] as? [[String: Any]] {
            for item in data {
                if let value = item["apiId"] as? String, !value.isEmpty {
                    return value
                }
                if let value = item["id"] as? String, !value.isEmpty {
                    return value
                }
            }
        }

        return nil
    }

    private func quotaData(from payload: [String: Any]) -> ProviderQuotaData? {
        guard let data = payload["data"] as? [String: Any] else { return nil }

        let usage = data["usage"] as? [String: Any]
        let total = usage?["total"] as? [String: Any]
        let limits = data["limits"] as? [String: Any]

        let totalCostLimit = doubleValue(from: limits?["totalCostLimit"])
        let currentTotalCostFromLimits = doubleValue(from: limits?["currentTotalCost"])
        let currentTotalCost: Double?
        if let currentTotalCostFromLimits {
            currentTotalCost = currentTotalCostFromLimits
        } else {
            currentTotalCost = doubleValue(from: total?["cost"])
        }
        let totalTokens = intValue(from: total?["tokens"])
        let totalRequests = intValue(from: total?["requests"])
        let weeklyOpusCost = doubleValue(from: limits?["weeklyOpusCost"])
        let expiresAt = data["expiresAt"] as? String

        var models: [ModelQuota] = []

        if let limit = totalCostLimit,
           limit > 0,
           let usedCost = currentTotalCost {
            let remainingCost = max(0, limit - usedCost)
            let remainingPercent = min(100, max(0, (remainingCost / limit) * 100))

            models.append(
                ModelQuota(
                    name: "relay-budget",
                    percentage: remainingPercent,
                    resetTime: expiresAt ?? "",
                    used: Int(usedCost.rounded()),
                    limit: Int(limit.rounded()),
                    remaining: Int(remainingCost.rounded()),
                    tooltip: buildTooltip(
                        usedCost: usedCost,
                        totalCostLimit: limit,
                        totalRequests: totalRequests,
                        totalTokens: totalTokens,
                        weeklyOpusCost: weeklyOpusCost
                    )
                )
            )
        } else if let usedCost = currentTotalCost {
            models.append(
                ModelQuota(
                    name: "relay-budget",
                    percentage: -1,
                    resetTime: expiresAt ?? "",
                    used: Int(usedCost.rounded()),
                    limit: nil,
                    remaining: nil,
                    tooltip: buildTooltip(
                        usedCost: usedCost,
                        totalCostLimit: totalCostLimit,
                        totalRequests: totalRequests,
                        totalTokens: totalTokens,
                        weeklyOpusCost: weeklyOpusCost
                    )
                )
            )
        } else {
            return nil
        }

        return ProviderQuotaData(models: models, lastUpdated: Date())
    }

    private func unavailableQuotaData(reason: String) -> ProviderQuotaData {
        ProviderQuotaData(
            models: [
                ModelQuota(
                    name: "relay-budget",
                    percentage: -1,
                    resetTime: "",
                    used: nil,
                    limit: nil,
                    remaining: nil,
                    tooltip: "Relay stats unavailable: " + reason
                )
            ],
            lastUpdated: Date()
        )
    }

    private func buildTooltip(
        usedCost: Double,
        totalCostLimit: Double?,
        totalRequests: Int?,
        totalTokens: Int?,
        weeklyOpusCost: Double?
    ) -> String {
        var parts: [String] = []

        if let totalCostLimit, totalCostLimit > 0 {
            parts.append("Cost \(formatNumber(usedCost))/\(formatNumber(totalCostLimit))")
        } else {
            parts.append("Cost \(formatNumber(usedCost))")
        }

        if let totalRequests {
            parts.append("Requests \(formatInteger(totalRequests))")
        }

        if let totalTokens {
            parts.append("Tokens \(formatInteger(totalTokens))")
        }

        if let weeklyOpusCost {
            parts.append("Weekly Opus \(formatNumber(weeklyOpusCost))")
        }

        return parts.joined(separator: " • ")
    }

    private func doubleValue(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private func intValue(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func formatNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private func formatInteger(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
