import Foundation

actor ModelDiscoveryService {
    private var session: URLSession

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 12)
        self.session = URLSession(configuration: config)
    }

    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 12)
        self.session = URLSession(configuration: config)
    }

    func fetchModels(baseURL: String, token: String) async throws -> [DiscoveredModel] {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            throw ModelDiscoveryError.missingToken
        }

        let candidateEndpoints = modelsEndpoints(from: baseURL)
        guard !candidateEndpoints.isEmpty else {
            if let fallback = fallbackModelsForKnownProvider(baseURL: baseURL), !fallback.isEmpty {
                return fallback
            }
            throw ModelDiscoveryError.invalidURL
        }

        var lastError: ModelDiscoveryError?

        for endpoint in candidateEndpoints {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 12
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(normalizedToken)", forHTTPHeaderField: "Authorization")
            request.setValue(normalizedToken, forHTTPHeaderField: "x-api-key")
            request.setValue(normalizedToken, forHTTPHeaderField: "api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                lastError = .requestFailed(error.localizedDescription)
                continue
            }

            guard let http = response as? HTTPURLResponse else {
                lastError = .invalidResponse
                continue
            }

            guard (200...299).contains(http.statusCode) else {
                if let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = message["error"] as? [String: Any],
                   let detail = error["message"] as? String {
                    lastError = .requestFailed(detail)
                } else {
                    lastError = .requestFailed("HTTP \(http.statusCode)")
                }
                continue
            }

            do {
                return try parseModels(from: data)
            } catch {
                lastError = .invalidResponse
            }
        }

        if let lastError {
            if let fallback = fallbackModelsForKnownProvider(baseURL: baseURL), !fallback.isEmpty {
                return fallback
            }
            throw lastError
        }

        if let fallback = fallbackModelsForKnownProvider(baseURL: baseURL), !fallback.isEmpty {
            return fallback
        }
        throw ModelDiscoveryError.invalidResponse
    }

    private func modelsEndpoints(from baseURL: String) -> [URL] {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }

        guard let original = URL(string: trimmed), original.host != nil else {
            return []
        }

        // Aliyun CodingPlan anthropic endpoint does not expose /models directly.
        // Route discovery to DashScope compatible models endpoint.
        let host = original.host?.lowercased() ?? ""
        let path = original.path.lowercased()
        if host == "coding.dashscope.aliyuncs.com", path.contains("/apps/anthropic") {
            let preferred: [String] = [
                "https://dashscope.aliyuncs.com/compatible-mode/v1/models",
                "https://dashscope.aliyuncs.com/api/v1/models"
            ]

            let preferredURLs = preferred.compactMap(URL.init(string:))
            if !preferredURLs.isEmpty {
                return preferredURLs
            }
        }

        guard var v1Components = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            return []
        }

        var v1Path = v1Components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if v1Path.isEmpty {
            v1Path = "v1"
        } else if !v1Path.hasSuffix("v1") {
            v1Path += "/v1"
        }
        v1Components.path = "/" + v1Path + "/models"

        var endpoints: [URL] = []
        if let v1URL = v1Components.url {
            endpoints.append(v1URL)
        }

        if var baseComponents = URLComponents(url: original, resolvingAgainstBaseURL: false) {
            var basePath = baseComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if basePath.hasSuffix("v1") {
                basePath = String(basePath.dropLast(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            if basePath.isEmpty {
                baseComponents.path = "/models"
            } else {
                baseComponents.path = "/" + basePath + "/models"
            }
            if let fallbackURL = baseComponents.url, !endpoints.contains(fallbackURL) {
                endpoints.append(fallbackURL)
            }
        }

        return endpoints
    }

    private func fallbackModelsForKnownProvider(baseURL: String) -> [DiscoveredModel]? {
        guard isAliyunCodingAnthropicURL(baseURL) else {
            return nil
        }

        // Aliyun Coding Plan documented model set.
        // Source: Aliyun official docs for Coding Plan/Kilo CLI integration.
        let ids: [String] = [
            "qwen3.5-plus",
            "qwen3-max-2026-01-23",
            "qwen3-coder-next",
            "qwen3-coder-plus",
            "MiniMax-M2.5",
            "glm-5",
            "glm-4.7",
            "kimi-k2.5"
        ]

        return ids.map { DiscoveredModel(id: $0, provider: "aliyun-coding-plan") }
    }

    private func isAliyunCodingAnthropicURL(_ baseURL: String) -> Bool {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return false
        }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "coding.dashscope.aliyuncs.com"
            && url.path.lowercased().contains("/apps/anthropic")
    }

    private func parseModels(from data: Data) throws -> [DiscoveredModel] {
        struct ModelsResponse: Decodable {
            struct Item: Decodable {
                let id: String?
                let model: String?
                let name: String?
                let model_id: String?
                let owned_by: String?
                let provider: String?
                let vendor: String?
            }

            let data: [Item]?
            let models: [Item]?
            let items: [Item]?
            let result: [Item]?
        }

        if let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) {
            let candidates = (decoded.data ?? []) + (decoded.models ?? []) + (decoded.items ?? []) + (decoded.result ?? [])
            let mapped = candidates.compactMap { item -> DiscoveredModel? in
                guard let id = normalizeModelID(item.id ?? item.model ?? item.model_id ?? item.name) else {
                    return nil
                }
                let provider = normalizeString(item.owned_by ?? item.provider ?? item.vendor)
                return DiscoveredModel(id: id, provider: provider)
            }
            if !mapped.isEmpty {
                return deduplicateModels(mapped)
            }
        }

        let mapped = parseModelsFromRawJSON(data)
        guard !mapped.isEmpty else {
            throw ModelDiscoveryError.invalidResponse
        }
        return deduplicateModels(mapped)
    }

    private func parseModelsFromRawJSON(_ data: Data) -> [DiscoveredModel] {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        if let array = jsonObject as? [[String: Any]] {
            return parseModelDictionaries(array)
        }

        guard let dict = jsonObject as? [String: Any] else {
            return []
        }

        let candidateKeys = ["data", "models", "items", "result"]
        for key in candidateKeys {
            if let array = dict[key] as? [[String: Any]] {
                let parsed = parseModelDictionaries(array)
                if !parsed.isEmpty {
                    return parsed
                }
            }
        }

        return []
    }

    private func parseModelDictionaries(_ dictionaries: [[String: Any]]) -> [DiscoveredModel] {
        dictionaries.compactMap { item in
            let idValue = item["id"] ?? item["model"] ?? item["model_id"] ?? item["name"]
            guard let id = normalizeModelID(idValue as? String) else {
                return nil
            }

            let providerValue = (item["owned_by"] as? String)
                ?? (item["provider"] as? String)
                ?? (item["vendor"] as? String)
            let provider = normalizeString(providerValue)
            return DiscoveredModel(id: id, provider: provider)
        }
    }

    private func normalizeModelID(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeString(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func deduplicateModels(_ models: [DiscoveredModel]) -> [DiscoveredModel] {
        // Preserve original IDs while removing duplicates.
        var deduped: [DiscoveredModel] = []
        var seen = Set<String>()
        for model in models {
            if seen.insert(model.id).inserted {
                deduped.append(model)
            }
        }
        return deduped
    }
}

enum ModelDiscoveryError: LocalizedError {
    case invalidURL
    case invalidResponse
    case missingToken
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Base URL 无效"
        case .invalidResponse:
            return "模型列表响应格式无效"
        case .missingToken:
            return "Token 不能为空"
        case .requestFailed(let message):
            return message
        }
    }
}
