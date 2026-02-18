import Foundation

actor UsageSourceFetcher {
    private var session: URLSession

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    func fetchSnapshot(for source: UsageSource, token: String?) async -> UsageSourceSnapshot {
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            switch source.kind {
            case .relayKeyQuery:
                return try await fetchRelayKeyQuerySnapshot(source: source, token: trimmedToken)
            case .relayAPIStats:
                return try await fetchRelayAPIStatsSnapshot(source: source, token: trimmedToken)
            case .genericJSON:
                return try await fetchGenericSnapshot(source: source, token: trimmedToken)
            }
        } catch {
            return UsageSourceSnapshot(
                sourceID: source.id,
                sourceName: source.name,
                fetchedAt: Date(),
                allTimeTokens: nil,
                dayTokens: nil,
                weekTokens: nil,
                monthTokens: nil,
                modelsByPeriod: [:],
                statusMessage: error.localizedDescription
            )
        }
    }

    private func fetchRelayKeyQuerySnapshot(source: UsageSource, token: String?) async throws -> UsageSourceSnapshot {
        guard let token, !token.isEmpty else {
            throw UsageSourceError.missingToken
        }

        let candidateURLs = relayKeyQueryCandidates(from: source.statsURL)
        guard !candidateURLs.isEmpty else {
            throw UsageSourceError.invalidURL
        }

        var lastError: Error = UsageSourceError.invalidURL
        for url in candidateURLs {
            do {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                var queryItems = components?.queryItems ?? []
                queryItems.removeAll { $0.name.lowercased() == "key" }
                queryItems.append(URLQueryItem(name: "key", value: token))
                components?.queryItems = queryItems

                guard let finalURL = components?.url else { continue }
                let payload = try await getJSON(url: finalURL, token: token)
                if let code = intValue(from: payload["code"]), code != 200 {
                    let message = (payload["msg"] as? String) ?? "Request failed"
                    throw UsageSourceError.requestFailed(message)
                }

                let periodTokens = extractPeriodTokens(from: payload)
                let modelsByPeriod = extractModelUsageByPeriod(from: payload)
                let summaryMessage = summaryMessage(from: payload)

                return UsageSourceSnapshot(
                    sourceID: source.id,
                    sourceName: source.name,
                    fetchedAt: Date(),
                    allTimeTokens: periodTokens.allTime,
                    dayTokens: periodTokens.day,
                    weekTokens: periodTokens.week,
                    monthTokens: periodTokens.month,
                    modelsByPeriod: modelsByPeriod,
                    statusMessage: summaryMessage
                )
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func fetchRelayAPIStatsSnapshot(source: UsageSource, token: String?) async throws -> UsageSourceSnapshot {
        guard let base = normalizedBaseURL(from: source.statsURL) else {
            throw UsageSourceError.invalidURL
        }

        let apiID = try await resolveAPIID(statsURL: source.statsURL, baseURL: base, token: token)

        let statsEndpoints = [
            base + "/apiStats/api/user-stats",
            base + "/api/apiStats/api/user-stats"
        ]
        let modelEndpoints = [
            base + "/apiStats/api/user-model-stats",
            base + "/api/apiStats/api/user-model-stats"
        ]

        let statsPayload = try await fetchJSONWithFallback(endpoints: statsEndpoints, body: ["apiId": apiID], token: token) ?? [:]
        let modelPayload = try await fetchJSONWithFallback(endpoints: modelEndpoints, body: ["apiId": apiID], token: token, allowFailure: true)

        let periodTokens = extractPeriodTokens(from: statsPayload)
        var modelsByPeriod = extractModelUsageByPeriod(from: modelPayload ?? [:])

        // Fallback: if model payload has no model period data, try extracting from stats payload.
        if modelsByPeriod.isEmpty {
            modelsByPeriod = extractModelUsageByPeriod(from: statsPayload)
        }

        return UsageSourceSnapshot(
            sourceID: source.id,
            sourceName: source.name,
            fetchedAt: Date(),
            allTimeTokens: periodTokens.allTime,
            dayTokens: periodTokens.day,
            weekTokens: periodTokens.week,
            monthTokens: periodTokens.month,
            modelsByPeriod: modelsByPeriod,
            statusMessage: nil
        )
    }

    private func fetchGenericSnapshot(source: UsageSource, token: String?) async throws -> UsageSourceSnapshot {
        guard let url = normalizedURL(from: source.statsURL) else {
            throw UsageSourceError.invalidURL
        }

        let payload = try await getJSON(url: url, token: token)
        let periodTokens = extractPeriodTokens(from: payload)
        let modelsByPeriod = extractModelUsageByPeriod(from: payload)

        return UsageSourceSnapshot(
            sourceID: source.id,
            sourceName: source.name,
            fetchedAt: Date(),
            allTimeTokens: periodTokens.allTime,
            dayTokens: periodTokens.day,
            weekTokens: periodTokens.week,
            monthTokens: periodTokens.month,
            modelsByPeriod: modelsByPeriod,
            statusMessage: summaryMessage(from: payload)
        )
    }

    private func resolveAPIID(statsURL: String, baseURL: String, token: String?) async throws -> String {
        if let directAPIID = apiIDFromURL(statsURL), !directAPIID.isEmpty {
            return directAPIID
        }

        guard let token, !token.isEmpty else {
            throw UsageSourceError.missingAPIID
        }

        let endpoints = [
            baseURL + "/apiStats/api/get-key-id",
            baseURL + "/api/apiStats/api/get-key-id"
        ]

        guard let payload = try await fetchJSONWithFallback(
            endpoints: endpoints,
            body: ["apiKey": token],
            token: token,
            allowGETFallback: true
        ) else {
            throw UsageSourceError.missingAPIID
        }

        if let data = payload["data"] as? [String: Any] {
            if let apiID = data["apiId"] as? String, !apiID.isEmpty { return apiID }
            if let apiID = data["id"] as? String, !apiID.isEmpty { return apiID }
        }

        if let apiID = payload["apiId"] as? String, !apiID.isEmpty {
            return apiID
        }

        if let data = payload["data"] as? String, !data.isEmpty {
            return data
        }

        throw UsageSourceError.missingAPIID
    }

    private func fetchJSONWithFallback(
        endpoints: [String],
        body: [String: Any],
        token: String?,
        allowFailure: Bool = false,
        allowGETFallback: Bool = false
    ) async throws -> [String: Any]? {
        var lastError: Error = UsageSourceError.invalidResponse

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }

            do {
                let payload = try await postJSON(url: url, body: body, token: token)
                if let error = extractAPIError(from: payload) {
                    throw UsageSourceError.requestFailed(error)
                }
                return payload
            } catch {
                lastError = error

                if allowGETFallback {
                    do {
                        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        components?.queryItems = body.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
                        guard let getURL = components?.url else { continue }
                        let payload = try await getJSON(url: getURL, token: token)
                        if let error = extractAPIError(from: payload) {
                            throw UsageSourceError.requestFailed(error)
                        }
                        return payload
                    } catch {
                        lastError = error
                    }
                }
            }
        }

        if allowFailure {
            return nil
        }

        throw lastError
    }

    private func postJSON(url: URL, body: [String: Any], token: String?) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        attachAuthHeaders(to: &request, token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageSourceError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let message = httpErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw UsageSourceError.requestFailed(message)
        }

        return try decodeJSONDictionary(data)
    }

    private func getJSON(url: URL, token: String?) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        attachAuthHeaders(to: &request, token: token)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageSourceError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let message = httpErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw UsageSourceError.requestFailed(message)
        }

        return try decodeJSONDictionary(data)
    }

    private func decodeJSONDictionary(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        if let dictionary = object as? [String: Any] {
            return dictionary
        }
        throw UsageSourceError.invalidResponse
    }

    private func attachAuthHeaders(to request: inout URLRequest, token: String?) {
        guard let token, !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "x-api-key")
        request.setValue(token, forHTTPHeaderField: "api-key")
    }

    private func httpErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let message = extractAPIError(from: object) {
            return message
        }
        return nil
    }

    private func extractAPIError(from payload: [String: Any]) -> String? {
        if let message = payload["message"] as? String, !message.isEmpty {
            return message
        }
        if let msg = payload["msg"] as? String, !msg.isEmpty, msg.lowercased() != "ok" {
            return msg
        }
        if let error = payload["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let errorText = payload["error"] as? String, !errorText.isEmpty {
            return errorText
        }
        return nil
    }

    private func summaryMessage(from payload: [String: Any]) -> String? {
        if let msg = payload["msg"] as? String, !msg.isEmpty, msg.lowercased() != "ok" {
            return msg
        }
        return nil
    }

    private func extractPeriodTokens(from payload: [String: Any]) -> (allTime: Int?, day: Int?, week: Int?, month: Int?) {
        let data = (payload["data"] as? [String: Any]) ?? payload

        // Fast-path for common layouts.
        let usage = (data["usage"] as? [String: Any]) ?? payload["usage"] as? [String: Any]
        var allTime = intValue(from: nestedValue(in: usage, path: ["total", "tokens"]))
        if allTime == nil { allTime = intValue(from: data["totalTokens"]) }
        if allTime == nil { allTime = intValue(from: data["tokens"]) }

        var day = intValue(from: nestedValue(in: usage, path: ["day", "tokens"]))
        if day == nil { day = intValue(from: nestedValue(in: usage, path: ["daily", "tokens"])) }
        if day == nil { day = intValue(from: nestedValue(in: usage, path: ["today", "tokens"])) }
        if day == nil { day = intValue(from: data["dayTokens"]) }
        if day == nil { day = intValue(from: data["dailyTokens"]) }
        if day == nil { day = intValue(from: data["todayTokens"]) }

        var week = intValue(from: nestedValue(in: usage, path: ["week", "tokens"]))
        if week == nil { week = intValue(from: nestedValue(in: usage, path: ["weekly", "tokens"])) }
        if week == nil { week = intValue(from: data["weekTokens"]) }
        if week == nil { week = intValue(from: data["weeklyTokens"]) }

        var month = intValue(from: nestedValue(in: usage, path: ["month", "tokens"]))
        if month == nil { month = intValue(from: nestedValue(in: usage, path: ["monthly", "tokens"])) }
        if month == nil { month = intValue(from: data["monthTokens"]) }
        if month == nil { month = intValue(from: data["monthlyTokens"]) }

        // Flatten fallback for non-standard payloads.
        let flat = flattenJSON(data)
        var fallbackDay = day
        if fallbackDay == nil {
            fallbackDay = firstMatchingInt(from: flat, patterns: ["day.tokens", "daily.tokens", "today.tokens", "daytokens", "dailytokens", "todaytokens"])
        }
        var fallbackWeek = week
        if fallbackWeek == nil {
            fallbackWeek = firstMatchingInt(from: flat, patterns: ["week.tokens", "weekly.tokens", "weektokens", "weeklytokens"])
        }
        var fallbackMonth = month
        if fallbackMonth == nil {
            fallbackMonth = firstMatchingInt(from: flat, patterns: ["month.tokens", "monthly.tokens", "monthtokens", "monthlytokens"])
        }

        var fallbackAll = allTime
        if fallbackAll == nil {
            fallbackAll = firstMatchingInt(from: flat, patterns: ["total.tokens", "all.tokens", "alltime.tokens", "totaltokens", "alltokens", "alltimetokens"])
        }

        return (fallbackAll, fallbackDay, fallbackWeek, fallbackMonth)
    }

    private func extractModelUsageByPeriod(from payload: [String: Any]) -> [TokenUsagePeriod: [SourceModelUsage]] {
        var periodBuckets: [TokenUsagePeriod: [String: (tokens: Int, requests: Int)]] = [:]

        let arraysToCheck: [[Any]] = [
            payload["data"] as? [Any],
            payload["models"] as? [Any],
            (payload["data"] as? [String: Any])?["models"] as? [Any],
            (payload["data"] as? [String: Any])?["list"] as? [Any]
        ].compactMap { $0 }

        for array in arraysToCheck {
            for item in array {
                guard let dictionary = item as? [String: Any] else { continue }
                guard let modelName = modelName(from: dictionary), !modelName.isEmpty else { continue }

                let tokens = extractPeriodTokens(from: dictionary)
                var requests = intValue(from: dictionary["requests"])
                if requests == nil {
                    requests = intValue(from: dictionary["requestCount"])
                }
                let requestCount = requests ?? 0

                if let day = tokens.day, day > 0 {
                    mergeModelUsage(modelName: modelName, tokens: day, requests: requestCount, period: .day, buckets: &periodBuckets)
                }
                if let week = tokens.week, week > 0 {
                    mergeModelUsage(modelName: modelName, tokens: week, requests: requestCount, period: .week, buckets: &periodBuckets)
                }
                if let month = tokens.month, month > 0 {
                    mergeModelUsage(modelName: modelName, tokens: month, requests: requestCount, period: .month, buckets: &periodBuckets)
                }
            }
        }

        return periodBuckets.mapValues { bucket in
            bucket
                .map { SourceModelUsage(model: $0.key, tokenCount: $0.value.tokens, requestCount: $0.value.requests) }
                .sorted { lhs, rhs in
                    if lhs.tokenCount == rhs.tokenCount {
                        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
                    }
                    return lhs.tokenCount > rhs.tokenCount
                }
        }
    }

    private func mergeModelUsage(
        modelName: String,
        tokens: Int,
        requests: Int,
        period: TokenUsagePeriod,
        buckets: inout [TokenUsagePeriod: [String: (tokens: Int, requests: Int)]]
    ) {
        var bucket = buckets[period] ?? [:]
        let existing = bucket[modelName] ?? (tokens: 0, requests: 0)
        bucket[modelName] = (tokens: existing.tokens + tokens, requests: existing.requests + requests)
        buckets[period] = bucket
    }

    private func modelName(from dictionary: [String: Any]) -> String? {
        if let value = dictionary["model"] as? String { return value }
        if let value = dictionary["modelName"] as? String { return value }
        if let value = dictionary["name"] as? String { return value }
        if let value = dictionary["id"] as? String { return value }
        return nil
    }

    private func nestedValue(in dictionary: [String: Any]?, path: [String]) -> Any? {
        guard let dictionary else { return nil }
        guard !path.isEmpty else { return nil }
        var current: Any = dictionary

        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else {
                return nil
            }
            current = next
        }

        return current
    }

    private func flattenJSON(_ value: Any, prefix: String = "") -> [String: Any] {
        var output: [String: Any] = [:]

        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let childPrefix = prefix.isEmpty ? key : "\(prefix).\(key)"
                let childOutput = flattenJSON(child, prefix: childPrefix)
                for (nestedKey, nestedValue) in childOutput {
                    output[nestedKey] = nestedValue
                }
            }
            return output
        }

        if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                let childPrefix = prefix.isEmpty ? "\(index)" : "\(prefix).\(index)"
                let childOutput = flattenJSON(child, prefix: childPrefix)
                for (nestedKey, nestedValue) in childOutput {
                    output[nestedKey] = nestedValue
                }
            }
            return output
        }

        if !prefix.isEmpty {
            output[prefix] = value
        }

        return output
    }

    private func firstMatchingInt(from flattened: [String: Any], patterns: [String]) -> Int? {
        for pattern in patterns {
            if let match = flattened.first(where: { $0.key.lowercased().contains(pattern.lowercased()) }),
               let value = intValue(from: match.value) {
                return value
            }
        }
        return nil
    }

    private func intValue(from value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            if let int = Int(string) {
                return int
            }
            if let double = Double(string) {
                return Int(double.rounded())
            }
            return nil
        default:
            return nil
        }
    }

    private func apiIDFromURL(_ statsURL: String) -> String? {
        guard let components = URLComponents(string: statsURL) else { return nil }
        return components.queryItems?.first(where: { $0.name.lowercased() == "apiid" })?.value
    }

    private func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.host != nil {
            return url
        }
        return URL(string: "https://" + trimmed)
    }

    private func normalizedBaseURL(from raw: String) -> String? {
        guard let url = normalizedURL(from: raw), let host = url.host else {
            return nil
        }

        let scheme = url.scheme ?? "https"
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private func relayKeyQueryCandidates(from statsURL: String) -> [URL] {
        guard let url = normalizedURL(from: statsURL), let base = normalizedBaseURL(from: statsURL) else {
            return []
        }

        var candidates: [String] = []

        let loweredPath = url.path.lowercased()
        if loweredPath.contains("key-query") {
            candidates.append(url.absoluteString)
        }

        candidates.append(base + "/api/relay/key-query")
        candidates.append(base + "/relay/key-query")
        candidates.append(base + "/api/key-query")
        candidates.append(base + "/key-query")

        var deduped: [URL] = []
        var seen = Set<String>()

        for candidate in candidates {
            guard let candidateURL = URL(string: candidate) else { continue }
            let key = candidateURL.absoluteString
            if seen.insert(key).inserted {
                deduped.append(candidateURL)
            }
        }

        return deduped
    }
}

enum UsageSourceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case missingToken
    case missingAPIID
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid stats URL"
        case .invalidResponse:
            return "Invalid stats response"
        case .missingToken:
            return "Token is required"
        case .missingAPIID:
            return "Unable to resolve apiId"
        case .requestFailed(let message):
            return message
        }
    }
}
