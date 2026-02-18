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

        guard let url = modelsEndpoint(from: baseURL) else {
            throw ModelDiscoveryError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(normalizedToken)", forHTTPHeaderField: "Authorization")
        request.setValue(normalizedToken, forHTTPHeaderField: "x-api-key")
        request.setValue(normalizedToken, forHTTPHeaderField: "api-key")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ModelDiscoveryError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            if let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = message["error"] as? [String: Any],
               let detail = error["message"] as? String {
                throw ModelDiscoveryError.requestFailed(detail)
            }
            throw ModelDiscoveryError.requestFailed("HTTP \(http.statusCode)")
        }

        struct ModelsResponse: Decodable {
            struct Item: Decodable {
                let id: String
                let owned_by: String?
            }
            let data: [Item]
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        let models = decoded.data.map { DiscoveredModel(id: $0.id, provider: $0.owned_by) }

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

    private func modelsEndpoint(from baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }

        guard var components = URLComponents(string: trimmed), components.host != nil else {
            return nil
        }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            path = "v1"
        } else if !path.hasSuffix("v1") {
            path += "/v1"
        }
        components.path = "/" + path + "/models"

        return components.url
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
