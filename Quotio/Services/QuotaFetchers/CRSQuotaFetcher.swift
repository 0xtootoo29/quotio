//
//  CRSQuotaFetcher.swift
//  Quotio
//
//  Fetches relay quota stats from relay admin APIs.
//

import Foundation

actor CRSQuotaFetcher {
    private struct RelayTarget: Sendable {
        let accountKey: String
        let apiKey: String
        let statsBaseURL: String
        let pathPrefixes: [String]
        let configuredEndpoint: String
        let groupHint: String?
    }

    private struct EndpointSignature: Equatable, Sendable {
        let host: String
        let path: String
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
                        pathPrefixes: statsConfig.pathPrefixes,
                        configuredEndpoint: statsConfig.configuredEndpoint,
                        groupHint: statsConfig.groupHint
                    )
                )
            }
        }
        return targets
    }

    private func resolveStatsBaseConfiguration(provider: CustomProvider, keyEntry: CustomAPIKeyEntry) -> (baseURL: String, pathPrefixes: [String], configuredEndpoint: String, groupHint: String?)? {
        let candidates: [String?] = [keyEntry.proxyURL, provider.baseURL]

        for candidate in candidates {
            guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty,
                  let url = normalizedURL(from: candidate),
                  let host = url.host?.lowercased(),
                  host.hasSuffix("itssx.com") else {
                continue
            }

            let scheme = (url.scheme?.lowercased().isEmpty == false) ? (url.scheme?.lowercased() ?? "https") : "https"
            var base = "\(scheme)://\(host)"
            if let port = url.port {
                base += ":\(port)"
            }

            let normalizedPath = normalizePath(url.path)
            let configuredEndpoint = normalizedPath.isEmpty ? base : base + normalizedPath
            let groupHint = endpointHint(from: normalizedPath)

            return (
                baseURL: base,
                pathPrefixes: endpointPathPrefixes(from: normalizedPath),
                configuredEndpoint: configuredEndpoint,
                groupHint: groupHint
            )
        }

        return nil
    }

    private func endpointPathPrefixes(from normalizedPath: String) -> [String] {
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

    private func normalizePath(_ rawPath: String) -> String {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.isEmpty || trimmedPath == "/" {
            return ""
        }
        return "/" + trimmedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func endpointHint(from normalizedPath: String) -> String? {
        guard !normalizedPath.isEmpty else { return nil }
        return normalizedPath.split(separator: "/").last.map(String.init)
    }

    private func normalizedURL(from raw: String) -> URL? {
        if let url = URL(string: raw), url.host != nil {
            return url
        }
        return URL(string: "https://" + raw)
    }

    private func fetchQuota(for target: RelayTarget) async -> ProviderQuotaData? {
        var reasons: [String] = []

        do {
            if let quota = try await fetchQuotaFromRelayKeyQuery(target: target) {
                return quota
            }
            reasons.append("relay key-query returned empty payload")
        } catch {
            reasons.append("relay key-query failed: \(error.localizedDescription)")
        }

        do {
            if let quota = try await fetchQuotaFromAPIStats(target: target) {
                return quota
            }
            reasons.append("apiStats returned empty payload")
        } catch {
            reasons.append("apiStats failed: \(error.localizedDescription)")
        }

        let reason = reasons.joined(separator: " | ")
        Log.quota("Relay quota fetch failed for \(target.accountKey): \(reason)")
        return unavailableQuotaData(reason: reason)
    }

    private func fetchQuotaFromAPIStats(target: RelayTarget) async throws -> ProviderQuotaData? {
        let apiID = try await fetchAPIID(target: target)
        let statsPayload = try await fetchUserStats(target: target, apiID: apiID)
        return quotaDataFromAPIStats(from: statsPayload)
    }

    private func fetchQuotaFromRelayKeyQuery(target: RelayTarget) async throws -> ProviderQuotaData? {
        let payload = try await fetchRelayKeyQuery(target: target)
        return quotaDataFromRelayKeyQuery(from: payload, target: target)
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

    private func fetchRelayKeyQuery(target: RelayTarget) async throws -> [String: Any] {
        var lastError: Error = QuotaFetchError.invalidResponse

        for prefix in prioritizedRelayQueryPrefixes(from: target.pathPrefixes) {
            guard var components = URLComponents(string: target.statsBaseURL + prefix + "/relay/key-query") else {
                continue
            }
            components.queryItems = [URLQueryItem(name: "key", value: target.apiKey)]
            guard let url = components.url else { continue }

            do {
                let payload = try await getJSON(url: url)
                let code = intValue(from: payload["code"]) ?? 0
                let message = (payload["msg"] as? String) ?? "relay key-query failed"

                if code != 200 {
                    throw QuotaFetchError.apiErrorMessage(message)
                }

                guard let data = payload["data"] as? [String: Any] else {
                    throw QuotaFetchError.apiErrorMessage("relay key-query has no data")
                }

                var mergedPayload = payload
                mergedPayload["data"] = data
                return mergedPayload
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError
    }

    private func prioritizedRelayQueryPrefixes(from prefixes: [String]) -> [String] {
        var ordered: [String] = []
        if prefixes.contains("/api") {
            ordered.append("/api")
        }
        for prefix in prefixes where prefix != "/api" {
            ordered.append(prefix)
        }
        if ordered.isEmpty {
            return ["/api", ""]
        }
        return ordered
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

    private func getJSON(url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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

    private func quotaDataFromAPIStats(from payload: [String: Any]) -> ProviderQuotaData? {
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

    private func quotaDataFromRelayKeyQuery(from payload: [String: Any], target: RelayTarget) -> ProviderQuotaData? {
        guard let data = payload["data"] as? [String: Any] else { return nil }

        let balance = doubleValue(from: data["balance"])
        let usedQuota = doubleValue(from: data["usedQuota"])
        let totalCostLimit = doubleValue(from: data["totalCostLimit"])
        let totalCostUsed = doubleValue(from: data["totalCostUsed"])
        let totalRequestLimit = intValue(from: data["totalRequestLimit"])
        let usedRequestCount = intValue(from: data["usedRequestCount"])
        let keyName = data["name"] as? String
        let expireAt = data["expireAt"] as? String

        let groups = data["allowedGroups"] as? [[String: Any]] ?? []
        let group = matchedRelayGroup(in: groups, target: target)
        let groupName = (group?["name"] as? String) ?? (group?["slug"] as? String)
        let groupUsage = group?["usage"] as? [String: Any]
        let groupSettings = group?["settings"] as? [String: Any]

        let groupBalanceUsedValue = groupUsage?["groupBalanceUsed"]
        let groupUsedQuotaValue = groupUsage?["usedQuota"]
        let groupTotalCostValue = groupUsage?["groupTotalCost"]
        let groupDailyCostValue = groupUsage?["groupDailyCost"]
        let groupDailyUsedQuotaValue = groupUsage?["dailyUsedQuota"]
        let groupRequestCountValue = groupUsage?["groupRequestCount"]
        let groupUsedRequestCountValue = groupUsage?["usedRequestCount"]
        let groupDailyQuotaValue = groupSettings?["dailyQuota"]
        let groupTotalCostLimitValue = groupSettings?["totalCostLimit"]

        let groupBalanceUsedPrimary = doubleValue(from: groupBalanceUsedValue)
        let groupBalanceUsedFallback = doubleValue(from: groupUsedQuotaValue)
        let groupBalanceUsed: Double?
        if let groupBalanceUsedPrimary {
            groupBalanceUsed = groupBalanceUsedPrimary
        } else {
            groupBalanceUsed = groupBalanceUsedFallback
        }

        let groupTotalCost = doubleValue(from: groupTotalCostValue)

        let groupDailyCostPrimary = doubleValue(from: groupDailyCostValue)
        let groupDailyCostFallback = doubleValue(from: groupDailyUsedQuotaValue)
        let groupDailyCost: Double?
        if let groupDailyCostPrimary {
            groupDailyCost = groupDailyCostPrimary
        } else {
            groupDailyCost = groupDailyCostFallback
        }

        let groupRequestCountPrimary = intValue(from: groupRequestCountValue)
        let groupRequestCountFallback = intValue(from: groupUsedRequestCountValue)
        let groupRequestCount: Int?
        if let groupRequestCountPrimary {
            groupRequestCount = groupRequestCountPrimary
        } else {
            groupRequestCount = groupRequestCountFallback
        }

        let groupDailyQuota = doubleValue(from: groupDailyQuotaValue)
        let groupTotalCostLimit = doubleValue(from: groupTotalCostLimitValue)

        var remainingPercent: Double = -1
        var usedValue: Int?
        var limitValue: Int?
        var remainingValue: Int?

        if let balance, balance > 0 {
            let used = max(0, groupBalanceUsed ?? usedQuota ?? 0)
            let remaining = max(0, balance - used)
            remainingPercent = min(100, max(0, (remaining / balance) * 100))
            usedValue = Int(used.rounded())
            limitValue = Int(balance.rounded())
            remainingValue = Int(remaining.rounded())
        } else if let groupTotalCostLimit, groupTotalCostLimit > 0 {
            let used = max(0, groupTotalCost ?? totalCostUsed ?? 0)
            let remaining = max(0, groupTotalCostLimit - used)
            remainingPercent = min(100, max(0, (remaining / groupTotalCostLimit) * 100))
            usedValue = Int(used.rounded())
            limitValue = Int(groupTotalCostLimit.rounded())
            remainingValue = Int(remaining.rounded())
        } else if let totalCostLimit, totalCostLimit > 0 {
            let used = max(0, totalCostUsed ?? 0)
            let remaining = max(0, totalCostLimit - used)
            remainingPercent = min(100, max(0, (remaining / totalCostLimit) * 100))
            usedValue = Int(used.rounded())
            limitValue = Int(totalCostLimit.rounded())
            remainingValue = Int(remaining.rounded())
        }

        let tooltip = buildRelayKeyQueryTooltip(
            keyName: keyName,
            groupName: groupName,
            balance: balance,
            usedQuota: usedQuota,
            totalRequestLimit: totalRequestLimit,
            usedRequestCount: usedRequestCount,
            groupBalanceUsed: groupBalanceUsed,
            groupRequestCount: groupRequestCount,
            groupDailyCost: groupDailyCost,
            groupTotalCost: groupTotalCost,
            groupDailyQuota: groupDailyQuota,
            groupTotalCostLimit: groupTotalCostLimit
        )

        return ProviderQuotaData(
            models: [
                ModelQuota(
                    name: "relay-budget",
                    percentage: remainingPercent,
                    resetTime: expireAt ?? "",
                    used: usedValue,
                    limit: limitValue,
                    remaining: remainingValue,
                    tooltip: tooltip
                )
            ],
            lastUpdated: Date()
        )
    }

    private func matchedRelayGroup(in groups: [[String: Any]], target: RelayTarget) -> [String: Any]? {
        guard !groups.isEmpty else { return nil }

        let configuredSignature = endpointSignature(from: target.configuredEndpoint)

        if let configuredSignature {
            if let exact = groups.first(where: { group in
                relayEndpoints(from: group).contains { endpoint in
                    endpointSignature(from: endpoint) == configuredSignature
                }
            }) {
                return exact
            }

            if let pathMatched = groups.first(where: { group in
                relayEndpoints(from: group).contains { endpoint in
                    endpointSignature(from: endpoint)?.path == configuredSignature.path
                }
            }) {
                return pathMatched
            }
        }

        if let groupHint = target.groupHint?.lowercased(), !groupHint.isEmpty {
            if let hinted = groups.first(where: { group in
                let slug = (group["slug"] as? String ?? "").lowercased()
                let name = (group["name"] as? String ?? "").lowercased()
                return slug == groupHint || name.contains(groupHint)
            }) {
                return hinted
            }
        }

        return groups.first
    }

    private func relayEndpoints(from group: [String: Any]) -> [String] {
        var endpoints: [String] = []
        if let endpointAcc = group["endpointAcc"] as? String, !endpointAcc.isEmpty {
            endpoints.append(endpointAcc)
        }
        if let endpoint = group["endpoint"] as? String, !endpoint.isEmpty {
            endpoints.append(endpoint)
        }
        return endpoints
    }

    private func endpointSignature(from raw: String) -> EndpointSignature? {
        guard let url = normalizedURL(from: raw), let host = url.host?.lowercased() else {
            return nil
        }
        return EndpointSignature(host: host, path: normalizePath(url.path))
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

    private func buildRelayKeyQueryTooltip(
        keyName: String?,
        groupName: String?,
        balance: Double?,
        usedQuota: Double?,
        totalRequestLimit: Int?,
        usedRequestCount: Int?,
        groupBalanceUsed: Double?,
        groupRequestCount: Int?,
        groupDailyCost: Double?,
        groupTotalCost: Double?,
        groupDailyQuota: Double?,
        groupTotalCostLimit: Double?
    ) -> String {
        var parts: [String] = []

        if let keyName, !keyName.isEmpty {
            parts.append("Key \(keyName)")
        }

        if let groupName, !groupName.isEmpty {
            parts.append("Group \(groupName)")
        }

        if let balance {
            if let usedQuota {
                parts.append("Shared balance \(formatNumber(usedQuota))/\(formatNumber(balance))")
            } else {
                parts.append("Shared balance \(formatNumber(balance))")
            }
        }

        if let groupBalanceUsed {
            parts.append("Group balance used \(formatNumber(groupBalanceUsed))")
        }

        if let groupDailyCost {
            if let groupDailyQuota, groupDailyQuota > 0 {
                parts.append("Daily cost \(formatNumber(groupDailyCost))/\(formatNumber(groupDailyQuota))")
            } else {
                parts.append("Daily cost \(formatNumber(groupDailyCost))")
            }
        }

        if let groupTotalCost {
            if let groupTotalCostLimit, groupTotalCostLimit > 0 {
                parts.append("Total cost \(formatNumber(groupTotalCost))/\(formatNumber(groupTotalCostLimit))")
            } else {
                parts.append("Total cost \(formatNumber(groupTotalCost))")
            }
        }

        if let groupRequestCount {
            parts.append("Group requests \(formatInteger(groupRequestCount))")
        }

        if let totalRequestLimit, totalRequestLimit > 0 {
            let used = usedRequestCount ?? 0
            parts.append("Key requests \(formatInteger(used))/\(formatInteger(totalRequestLimit))")
        }

        return parts.joined(separator: " • ")
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
