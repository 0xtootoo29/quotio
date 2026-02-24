//
//  ProxyBridge.swift
//  Quotio - TCP Proxy Bridge for Connection Management
//
//  This proxy sits between CLI tools and CLIProxyAPI to solve the stale
//  connection issue. By forcing "Connection: close" on every request,
//  we prevent HTTP keep-alive connections from becoming stale after idle periods.
//
//  Additionally handles Model Fallback: when a virtual model is detected,
//  resolves it to real models and automatically retries on quota exhaustion.
//
//  Architecture:
//    CLI Tools → ProxyBridge (user port) → CLIProxyAPI (internal port)
//

import Foundation
import Network

// MARK: - Fallback Context

/// Context for tracking fallback state during request processing
struct FallbackContext: Sendable {
    let virtualModelName: String?
    let fallbackEntries: [FallbackEntry]
    let currentIndex: Int
    let originalBody: String
    let wasLoadedFromCache: Bool
    let attempts: [FallbackAttempt]
    let triedSanitization: Bool

    /// Whether this request has fallback enabled
    nonisolated var hasFallback: Bool { !fallbackEntries.isEmpty }

    /// Whether there are more fallbacks to try
    nonisolated var hasMoreFallbacks: Bool { currentIndex + 1 < fallbackEntries.count }

    /// Get next fallback context
    nonisolated func next() -> FallbackContext {
        FallbackContext(
            virtualModelName: virtualModelName,
            fallbackEntries: fallbackEntries,
            currentIndex: currentIndex + 1,
            originalBody: originalBody,
            wasLoadedFromCache: false,
            attempts: attempts,
            triedSanitization: false
        )
    }

    /// Append a new attempt entry
    nonisolated func appendingAttempt(_ attempt: FallbackAttempt) -> FallbackContext {
        FallbackContext(
            virtualModelName: virtualModelName,
            fallbackEntries: fallbackEntries,
            currentIndex: currentIndex,
            originalBody: originalBody,
            wasLoadedFromCache: wasLoadedFromCache,
            attempts: attempts + [attempt],
            triedSanitization: triedSanitization
        )
    }

    /// Mark that sanitization has been attempted for this context
    nonisolated func withSanitizationAttempted() -> FallbackContext {
        FallbackContext(
            virtualModelName: virtualModelName,
            fallbackEntries: fallbackEntries,
            currentIndex: currentIndex,
            originalBody: originalBody,
            wasLoadedFromCache: wasLoadedFromCache,
            attempts: attempts,
            triedSanitization: true
        )
    }

    /// Current fallback entry
    nonisolated var currentEntry: FallbackEntry? {
        guard currentIndex < fallbackEntries.count else { return nil }
        return fallbackEntries[currentIndex]
    }

    /// Empty context for non-fallback requests
    nonisolated static let empty = FallbackContext(
        virtualModelName: nil,
        fallbackEntries: [],
        currentIndex: 0,
        originalBody: "",
        wasLoadedFromCache: false,
        attempts: [],
        triedSanitization: false
    )
}

// MARK: - Backpressure / Circuit Breaker

private enum MessageRequestAdmission: Sendable {
    case accepted
    case rejected(message: String, retryAfterSeconds: Int)
}

private enum MessageRequestOutcome: Sendable {
    case success
    case transientFailure
    case permanentFailure
}

private final class MessageRequestLifecycle: @unchecked Sendable {
    nonisolated(unsafe) private let lock = NSLock()
    nonisolated(unsafe) private var completed = false

    nonisolated func completeOnce(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        action()
    }
}

private final class MessageFlowController: @unchecked Sendable {
    nonisolated(unsafe) private let lock = NSLock()
    nonisolated(unsafe) private var activeMessageRequests = 0
    nonisolated(unsafe) private var consecutiveTransientFailures = 0
    nonisolated(unsafe) private var circuitOpenUntil: Date?

    nonisolated(unsafe) private let maxConcurrentMessages: Int
    nonisolated(unsafe) private let failureThreshold: Int
    nonisolated(unsafe) private let cooldownSeconds: Int

    init(maxConcurrentMessages: Int, failureThreshold: Int, cooldownSeconds: Int) {
        self.maxConcurrentMessages = max(1, maxConcurrentMessages)
        self.failureThreshold = max(2, failureThreshold)
        self.cooldownSeconds = max(5, cooldownSeconds)
    }

    nonisolated func admit(now: Date = Date()) -> MessageRequestAdmission {
        lock.lock()
        defer { lock.unlock() }

        if let openUntil = circuitOpenUntil {
            if now < openUntil {
                let remaining = max(1, Int(ceil(openUntil.timeIntervalSince(now))))
                return .rejected(
                    message: "Upstream relay is temporarily overloaded. Please retry shortly.",
                    retryAfterSeconds: remaining
                )
            }
            // Cooldown window ended; close breaker.
            circuitOpenUntil = nil
            consecutiveTransientFailures = 0
        }

        if activeMessageRequests >= maxConcurrentMessages {
            return .rejected(
                message: "Proxy bridge is busy with in-flight model requests. Please retry.",
                retryAfterSeconds: 1
            )
        }

        activeMessageRequests += 1
        return .accepted
    }

    nonisolated func complete(outcome: MessageRequestOutcome, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        if activeMessageRequests > 0 {
            activeMessageRequests -= 1
        }

        switch outcome {
        case .success:
            consecutiveTransientFailures = 0
            circuitOpenUntil = nil

        case .transientFailure:
            if let openUntil = circuitOpenUntil, now < openUntil {
                return
            }

            consecutiveTransientFailures += 1
            if consecutiveTransientFailures >= failureThreshold {
                circuitOpenUntil = now.addingTimeInterval(TimeInterval(cooldownSeconds))
                consecutiveTransientFailures = 0
            }

        case .permanentFailure:
            // Keep breaker state; these are not usually overload-related.
            break
        }
    }
}

/// A lightweight TCP proxy that forwards requests to CLIProxyAPI while
/// ensuring fresh connections by forcing "Connection: close" on all requests.
@MainActor
@Observable
final class ProxyBridge {
    
    // MARK: - Properties
    
    private var listener: NWListener?
    private let stateQueue = DispatchQueue(label: "dev.quotio.desktop.proxy-bridge-state")
    
    /// The port this proxy listens on (user-facing port)
    private(set) var listenPort: UInt16 = 8080
    
    /// The port CLIProxyAPI runs on (internal port)
    private(set) var targetPort: UInt16 = 18080
    
    /// Target host (always localhost)
    private let targetHost = "127.0.0.1"
    
    /// Whether the proxy bridge is currently running
    private(set) var isRunning = false
    
    /// Last error message
    private(set) var lastError: String?
    
    /// Statistics: total requests forwarded
    private(set) var totalRequests: Int = 0
    
    /// Statistics: active connections count
    private(set) var activeConnections: Int = 0
    
    /// Maximum concurrent connections to prevent resource exhaustion
    private let maxActiveConnections = 100

    /// Message traffic concurrency and transient failure protection.
    /// Hidden overrides can be provided via UserDefaults:
    /// - proxyBridge.maxConcurrentMessages (default 6)
    /// - proxyBridge.circuitFailureThreshold (default 3)
    /// - proxyBridge.circuitCooldownSeconds (default 20)
    private let messageFlowController: MessageFlowController = {
        let defaults = UserDefaults.standard

        let configuredMaxConcurrent = defaults.integer(forKey: "proxyBridge.maxConcurrentMessages")
        let maxConcurrent = configuredMaxConcurrent > 0 ? min(configuredMaxConcurrent, 32) : 6

        let configuredFailureThreshold = defaults.integer(forKey: "proxyBridge.circuitFailureThreshold")
        let failureThreshold = configuredFailureThreshold > 0 ? min(configuredFailureThreshold, 10) : 3

        let configuredCooldown = defaults.integer(forKey: "proxyBridge.circuitCooldownSeconds")
        let cooldownSeconds = configuredCooldown > 0 ? min(configuredCooldown, 300) : 20

        return MessageFlowController(
            maxConcurrentMessages: maxConcurrent,
            failureThreshold: failureThreshold,
            cooldownSeconds: cooldownSeconds
        )
    }()
    
    /// Connection timeout in seconds (for target connection setup)
    private let connectionTimeoutSeconds: UInt64 = 10
    
    /// Callback for request metadata extraction (for RequestTracker)
    var onRequestCompleted: ((RequestMetadata) -> Void)?
    
    // MARK: - Request Metadata

    /// Metadata extracted from proxied requests
    struct RequestMetadata: Sendable {
        let timestamp: Date
        let method: String
        let path: String
        let provider: String?
        let model: String?
        let resolvedModel: String?  // Actual model used after fallback resolution
        let resolvedProvider: String?  // Actual provider used after fallback resolution
        let inputTokens: Int?
        let outputTokens: Int?
        let statusCode: Int?
        let durationMs: Int
        let requestSize: Int
        let responseSize: Int
        let fallbackAttempts: [FallbackAttempt]
        let fallbackStartedFromCache: Bool
        let responseSnippet: String?
    }
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Configuration
    
    /// Configure the proxy ports
    /// - Parameters:
    ///   - listenPort: The port to listen on (user-facing)
    ///   - targetPort: The port CLIProxyAPI runs on
    func configure(listenPort: UInt16, targetPort: UInt16) {
        self.listenPort = listenPort
        self.targetPort = targetPort
    }
    
    /// Calculate internal port from user port (offset by 10000)
    /// This is nonisolated so it can be called from static contexts
    nonisolated static func internalPort(from userPort: UInt16) -> UInt16 {
        // Use offset of 10000, but cap at valid port range
        // For high ports (55536+), use a smaller offset to stay within valid range
        let preferredPort = UInt32(userPort) + 10000
        if preferredPort <= 65535 {
            return UInt16(preferredPort)
        }
        // Fallback: use modular offset within high port range (49152-65535)
        let highPortBase: UInt16 = 49152
        let offset = userPort % 1000
        return highPortBase + offset
    }
    
    // MARK: - Lifecycle
    
    /// Starts the proxy bridge
    func start() {
        guard !isRunning else {
            return
        }

        lastError = nil

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            guard let port = NWEndpoint.Port(rawValue: listenPort) else {
                lastError = "Invalid port: \(listenPort)"
                return
            }

            listener = try NWListener(using: parameters, on: port)

            listener?.stateUpdateHandler = { [weak self] state in
                guard let weakSelf = self else { return }
                Task { @MainActor in
                    weakSelf.handleListenerState(state)
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                guard let weakSelf = self else { return }
                Task { @MainActor in
                    weakSelf.handleNewConnection(connection)
                }
            }

            listener?.start(queue: .global(qos: .userInitiated))

        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Stops the proxy bridge
    func stop() {
        stateQueue.sync {
            listener?.cancel()
            listener = nil
        }

        isRunning = false
    }
    
    // MARK: - State Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
        case .failed(let error):
            isRunning = false
            lastError = error.localizedDescription
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        if activeConnections >= maxActiveConnections {
            connection.start(queue: .global(qos: .userInitiated))
            sendError(
                to: connection,
                statusCode: 503,
                message: "Proxy bridge is busy. Please retry in a moment.",
                additionalHeaders: [("Retry-After", "1")]
            )
            return
        }

        activeConnections += 1
        totalRequests += 1

        let connectionId = totalRequests
        let startTime = Date()

        connection.stateUpdateHandler = { [weak self] state in
            guard let weakSelf = self else { return }
            if case .cancelled = state {
                Task { @MainActor in
                    weakSelf.activeConnections -= 1
                }
            } else if case .failed = state {
                Task { @MainActor in
                    weakSelf.activeConnections -= 1
                }
            }
        }
        
        connection.start(queue: .global(qos: .userInitiated))
        
        // Start receiving request
        receiveRequest(
            from: connection,
            connectionId: connectionId,
            startTime: startTime,
            accumulatedData: Data()
        )
    }
    
    // MARK: - Request Receiving (Iterative)
    
    /// Receives HTTP request data iteratively to avoid stack overflow
    private nonisolated func receiveRequest(
        from connection: NWConnection,
        connectionId: Int,
        startTime: Date,
        accumulatedData: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil {
                connection.cancel()
                return
            }
            
            guard let data = data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }
            
            var newData = accumulatedData
            newData.append(data)
            
            // Check if we have a complete HTTP request
            if let requestString = String(data: newData, encoding: .utf8),
               let headerEndRange = requestString.range(of: "\r\n\r\n") {
                
                let headerEndIndex = requestString.distance(from: requestString.startIndex, to: headerEndRange.upperBound)
                let headerPart = String(requestString.prefix(headerEndIndex))
                
                // Check Content-Length to determine if we have full body
                if let contentLengthLine = headerPart
                    .components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") }) {
                    
                    let headerParts = contentLengthLine.components(separatedBy: ":")
                    guard headerParts.count > 1 else { return }
                    
                    let lengthStr = headerParts[1].trimmingCharacters(in: .whitespaces)
                    if let contentLength = Int(lengthStr) {
                        let currentBodyLength = newData.count - headerEndIndex
                        
                        // Need more data
                        if currentBodyLength < contentLength {
                            let nextData = newData
                            // Use async dispatch to break recursion stack
                            DispatchQueue.global(qos: .userInitiated).async {
                                self.receiveRequest(
                                    from: connection,
                                    connectionId: connectionId,
                                    startTime: startTime,
                                    accumulatedData: nextData
                                )
                            }
                            return
                        }
                    }
                }
                
                // Complete request - process it
                self.processRequest(
                    data: newData,
                    connection: connection,
                    connectionId: connectionId,
                    startTime: startTime
                )
                
            } else if !isComplete {
                // Haven't found header end yet, continue receiving
                // Use async dispatch to break recursion stack
                let nextData = newData
                DispatchQueue.global(qos: .userInitiated).async {
                    self.receiveRequest(
                        from: connection,
                        connectionId: connectionId,
                        startTime: startTime,
                        accumulatedData: nextData
                    )
                }
            } else {
                // Complete but malformed
                self.processRequest(
                    data: newData,
                    connection: connection,
                    connectionId: connectionId,
                    startTime: startTime
                )
            }
        }
    }
    
    // MARK: - Request Processing

    private nonisolated func processRequest(
        data: Data,
        connection: NWConnection,
        connectionId: Int,
        startTime: Date
    ) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendError(to: connection, statusCode: 400, message: "Invalid request encoding")
            return
        }

        // Parse HTTP request line
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(to: connection, statusCode: 400, message: "Missing request line")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 3 else {
            sendError(to: connection, statusCode: 400, message: "Invalid request format")
            return
        }

        let method = parts[0]
        let path = parts[1]
        let httpVersion = parts[2]

        // Collect headers
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        // Extract body
        var body = ""
        if let bodyRange = requestString.range(of: "\r\n\r\n") {
            body = String(requestString[bodyRange.upperBound...])
        }

        let modelID = extractModelID(fromRequestBody: body)
        let shouldSanitizeBeta = shouldSanitizeAnthropicBeta(forModelID: modelID)
        let forwardedPath = shouldSanitizeBeta ? removingBetaQueryFromPath(path) : path
        var forwardedHeaders = headers
        if shouldSanitizeBeta {
            forwardedHeaders.removeAll { header in
                header.0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "anthropic-beta"
            }
        }

        let metadata = extractMetadata(method: method, path: forwardedPath, body: body)
        let isMessageRequest = isClaudeMessagesRequest(method: method, path: forwardedPath)

        var messageLifecycle: MessageRequestLifecycle?
        if isMessageRequest {
            switch messageFlowController.admit() {
            case .accepted:
                messageLifecycle = MessageRequestLifecycle()
            case .rejected(let message, let retryAfterSeconds):
                sendError(
                    to: connection,
                    statusCode: 503,
                    message: message,
                    additionalHeaders: [("Retry-After", "\(retryAfterSeconds)")]
                )
                return
            }
        }

        // Check for virtual model and create fallback context
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            let fallbackContext = self.createFallbackContext(body: body)
            let resolvedBody: String

            if fallbackContext.hasFallback, let entry = fallbackContext.currentEntry {
                // Replace model in body with resolved model
                resolvedBody = self.replaceModelInBody(body, with: entry.modelId)
            } else {
                resolvedBody = body
            }

            let targetPortValue = self.targetPort
            let targetHostValue = self.targetHost

            self.forwardRequest(
                method: method,
                path: forwardedPath,
                version: httpVersion,
                headers: forwardedHeaders,
                body: resolvedBody,
                originalConnection: connection,
                connectionId: connectionId,
                startTime: startTime,
                requestSize: data.count,
                metadata: metadata,
                targetPort: targetPortValue,
                targetHost: targetHostValue,
                fallbackContext: fallbackContext,
                isMessageRequest: isMessageRequest,
                messageLifecycle: messageLifecycle
            )
        }
    }

    // MARK: - Fallback Support

    /// Create fallback context if the request uses a virtual model
    private func createFallbackContext(body: String) -> FallbackContext {
        let settings = FallbackSettingsManager.shared

        // Check if fallback is enabled
        guard settings.isEnabled else {
            return .empty
        }

        // Extract model from body
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let model = json["model"] as? String else {
            return .empty
        }

        // Check if this is a virtual model
        guard settings.isVirtualModel(model) else {
            return .empty
        }

        guard let virtualModel = settings.findVirtualModel(name: model) else {
            return .empty
        }

        let entries = virtualModel.sortedEntries
        guard !entries.isEmpty else {
            return .empty
        }

        // Get cached entry ID and find its current index (handles reordering correctly)
        var startIndex = 0
        var wasLoadedFromCache = false
        if let cachedEntryId = settings.getCachedEntryId(for: model) {
            if let cachedIndex = entries.firstIndex(where: { $0.id == cachedEntryId }) {
                startIndex = cachedIndex
                wasLoadedFromCache = true
            }
        }

        var attempts: [FallbackAttempt] = []
        if wasLoadedFromCache, startIndex < entries.count {
            let cachedEntry = entries[startIndex]
            attempts.append(FallbackAttempt(entry: cachedEntry, outcome: .skipped, reason: .cachedRoute))
        }

        return FallbackContext(
            virtualModelName: model,
            fallbackEntries: entries,
            currentIndex: startIndex,
            originalBody: body,
            wasLoadedFromCache: wasLoadedFromCache,
            attempts: attempts,
            triedSanitization: false
        )
    }

    // MARK: - Request Body Transformation

    private nonisolated func replaceModelInBody(
        _ body: String,
        with newModel: String
    ) -> String {
        guard let bodyData = body.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              json["model"] != nil else {
            return body
        }

        json["model"] = newModel

        guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let newBody = String(data: newData, encoding: .utf8) else {
            return body
        }

        return newBody
    }

    private nonisolated func sanitizeThinkingBlocks(_ body: String, targetModelId: String) -> String {
        guard let bodyData = body.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              var messages = json["messages"] as? [[String: Any]] else {
            return body
        }

        var modified = false

        for i in messages.indices {
            guard let content = messages[i]["content"] as? [[String: Any]] else { continue }

            let filteredContent = content.filter { block in
                guard let blockType = block["type"] as? String else { return true }
                if blockType == "thinking" || blockType == "redacted_thinking" {
                    modified = true
                    return false
                }
                return true
            }

            if filteredContent.count != content.count {
                if filteredContent.isEmpty {
                    messages[i]["content"] = [["type": "text", "text": "[reasoning omitted]"]]
                } else {
                    messages[i]["content"] = filteredContent
                }
            }
        }

        guard modified else { return body }

        json["messages"] = messages
        json["model"] = targetModelId

        guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let newBody = String(data: newData, encoding: .utf8) else {
            return body
        }

        return newBody
    }

    /// Check why a response should trigger fallback (if any)
    private nonisolated func fallbackReason(responseData: Data) -> FallbackTriggerReason? {
        return FallbackFormatConverter.fallbackReason(responseData: responseData)
    }

    private nonisolated func responseBodySnippet(from responseData: Data, limit: Int = 512) -> String? {
        guard let responseString = String(data: responseData.prefix(4096), encoding: .utf8) else {
            return nil
        }
        let parts = responseString.components(separatedBy: "\r\n\r\n")
        let body = parts.dropFirst().joined(separator: "\r\n\r\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return nil
        }
        return String(body.prefix(limit))
    }

    private nonisolated func extractModelID(fromRequestBody body: String) -> String? {
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let modelID = json["model"] as? String else {
            return nil
        }
        return modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Certain third-party relay routes are unstable when Anthropic beta query/headers are forwarded as-is.
    /// We sanitize those fields for relay aliases configured in Quotio's config file,
    /// and keep a conservative fallback for MiniMax/GLM pattern-based aliases.
    private nonisolated func shouldSanitizeAnthropicBeta(forModelID modelID: String?) -> Bool {
        guard let modelID = modelID?.lowercased(), !modelID.isEmpty else { return false }

        if configuredRelayAliases().contains(modelID) {
            return true
        }

        return modelID.contains("minimax") || modelID.contains("glm")
    }

    /// Parse configured relay aliases from `~/Library/Application Support/Quotio/config.yaml`.
    /// We only read aliases inside the `claude-api-key:` section to avoid touching unrelated mappings.
    private nonisolated func configuredRelayAliases() -> Set<String> {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }

        let configPath = appSupport.appendingPathComponent("Quotio/config.yaml").path
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return []
        }

        let aliasRegex: NSRegularExpression
        do {
            aliasRegex = try NSRegularExpression(pattern: #"alias:\s*"([^"]+)""#)
        } catch {
            return []
        }

        var aliases = Set<String>()
        var inClaudeSection = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "claude-api-key:" {
                inClaudeSection = true
                continue
            }

            if inClaudeSection {
                // Exit when a new top-level YAML key starts.
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty {
                    break
                }

                let nsLine = line as NSString
                let fullRange = NSRange(location: 0, length: nsLine.length)
                if let match = aliasRegex.firstMatch(in: line, range: fullRange), match.numberOfRanges > 1 {
                    let alias = nsLine.substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if !alias.isEmpty {
                        aliases.insert(alias)
                    }
                }
            }
        }

        return aliases
    }

    private nonisolated func removingBetaQueryFromPath(_ path: String) -> String {
        guard let questionMark = path.firstIndex(of: "?") else { return path }

        let basePath = String(path[..<questionMark])
        let query = String(path[path.index(after: questionMark)...])
        if query.isEmpty { return basePath }

        let filteredPairs = query
            .split(separator: "&")
            .map(String.init)
            .filter { pair in
                let lower = pair.lowercased()
                if lower == "beta=true" || lower == "beta=1" || lower == "beta" {
                    return false
                }
                return true
            }

        guard !filteredPairs.isEmpty else { return basePath }
        return basePath + "?" + filteredPairs.joined(separator: "&")
    }

    private nonisolated func isClaudeMessagesRequest(method: String, path: String) -> Bool {
        guard method.uppercased() == "POST" else { return false }
        let normalizedPath = path.lowercased()
        return normalizedPath.contains("/v1/messages")
            || normalizedPath.hasSuffix("/messages")
            || normalizedPath.contains("/messages?")
    }

    private nonisolated func messageRequestOutcome(statusCode: Int?, responseData: Data) -> MessageRequestOutcome {
        if let statusCode {
            if (200..<300).contains(statusCode) {
                return .success
            }

            if [408, 429, 500, 502, 503, 504].contains(statusCode) {
                return .transientFailure
            }

            return .permanentFailure
        }

        let snippet = (responseBodySnippet(from: responseData, limit: 512) ?? "").lowercased()
        if snippet.contains("unexpected eof")
            || snippet.contains("internal_server_error")
            || snippet.contains("timeout")
            || snippet.contains("temporarily unavailable")
            || snippet.contains("connection reset") {
            return .transientFailure
        }

        return .permanentFailure
    }

    private nonisolated func completeMessageFlowIfNeeded(
        isMessageRequest: Bool,
        lifecycle: MessageRequestLifecycle?,
        outcome: MessageRequestOutcome
    ) {
        guard isMessageRequest, let lifecycle else { return }
        lifecycle.completeOnce { [messageFlowController] in
            messageFlowController.complete(outcome: outcome)
        }
    }
    
    // MARK: - Metadata Extraction
    
    private nonisolated func extractMetadata(method: String, path: String, body: String) -> (provider: String?, model: String?, method: String, path: String) {
        // Detect provider from path
        var provider: String?
        if path.contains("/anthropic/") || path.contains("/claude") {
            provider = "claude"
        } else if path.contains("/gemini/") || path.contains("/google/") {
            provider = "gemini"
        } else if path.contains("/openai/") || path.contains("/chat/completions") {
            provider = "openai"
        } else if path.contains("/copilot/") {
            provider = "copilot"
        } else if path.contains("codewhisperer") || path.contains("kiro") {
            provider = "kiro"
        }
        
        // Extract model from JSON body
        var model: String?
        if let bodyData = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let modelValue = json["model"] as? String {
            model = modelValue
            
            // Infer provider from model name if not already detected
            if provider == nil {
                if FallbackFormatConverter.isClaudeModel(modelValue) {
                    provider = "claude"
                } else if modelValue.hasPrefix("gemini") || modelValue.hasPrefix("models/gemini") {
                    provider = "gemini"
                } else if modelValue.hasPrefix("gpt") || modelValue.hasPrefix("o1") || modelValue.hasPrefix("o3") {
                    provider = "openai"
                } else if modelValue.contains("kiro") || modelValue.contains("codewhisperer") {
                    provider = "kiro"
                }
            }
        }
        
        return (provider, model, method, path)
    }
    
    // MARK: - Request Forwarding

    private nonisolated func forwardRequest(
        method: String,
        path: String,
        version: String,
        headers: [(String, String)],
        body: String,
        originalConnection: NWConnection,
        connectionId: Int,
        startTime: Date,
        requestSize: Int,
        metadata: (provider: String?, model: String?, method: String, path: String),
        targetPort: UInt16,
        targetHost: String,
        fallbackContext: FallbackContext,
        isMessageRequest: Bool,
        messageLifecycle: MessageRequestLifecycle?
    ) {
        // Create connection to CLIProxyAPI
        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            completeMessageFlowIfNeeded(
                isMessageRequest: isMessageRequest,
                lifecycle: messageLifecycle,
                outcome: .transientFailure
            )
            sendError(to: originalConnection, statusCode: 500, message: "Invalid target port")
            return
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetHost), port: port)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)

        let targetConnection = NWConnection(to: endpoint, using: parameters)

        let timeoutSeconds = self.connectionTimeoutSeconds

        // Use class-based wrapper for thread-safe cancellation flag
        final class TimeoutState: @unchecked Sendable {
            var cancelled = false
        }
        let timeoutState = TimeoutState()

        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(timeoutSeconds))) { [weak targetConnection] in
            guard !timeoutState.cancelled else { return }
            guard let conn = targetConnection, conn.state != .ready else { return }
            conn.cancel()
        }

        // Capture for closure
        let capturedFallbackContext = fallbackContext
        let capturedHeaders = headers
        let capturedMethod = method
        let capturedPath = path
        let capturedVersion = version

        targetConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:
                timeoutState.cancelled = true
                // Build forwarded request with Connection: close
                var forwardedRequest = "\(capturedMethod) \(capturedPath) \(capturedVersion)\r\n"

                // Forward headers, excluding ones we'll override or that break error detection
                let excludedHeaders: Set<String> = ["connection", "content-length", "host", "transfer-encoding", "accept-encoding"]
                for (name, value) in capturedHeaders {
                    if !excludedHeaders.contains(name.lowercased()) {
                        forwardedRequest += "\(name): \(value)\r\n"
                    }
                }

                // Add our headers
                forwardedRequest += "Host: \(targetHost):\(targetPort)\r\n"
                forwardedRequest += "Connection: close\r\n"  // KEY: Force fresh connections
                forwardedRequest += "Content-Length: \(body.utf8.count)\r\n"
                forwardedRequest += "\r\n"
                forwardedRequest += body

                guard let requestData = forwardedRequest.data(using: .utf8) else {
                    self.completeMessageFlowIfNeeded(
                        isMessageRequest: isMessageRequest,
                        lifecycle: messageLifecycle,
                        outcome: .permanentFailure
                    )
                    self.sendError(to: originalConnection, statusCode: 500, message: "Failed to encode request")
                    targetConnection.cancel()
                    return
                }

                targetConnection.send(content: requestData, completion: .contentProcessed { error in
                    if error != nil {
                        self.completeMessageFlowIfNeeded(
                            isMessageRequest: isMessageRequest,
                            lifecycle: messageLifecycle,
                            outcome: .transientFailure
                        )
                        self.sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Failed to send upstream request")
                        targetConnection.cancel()
                    } else {
                        // Start receiving response
                        self.receiveResponse(
                            from: targetConnection,
                            to: originalConnection,
                            connectionId: connectionId,
                            startTime: startTime,
                            requestSize: requestSize,
                            metadata: metadata,
                            responseData: Data(),
                            fallbackContext: capturedFallbackContext,
                            headers: capturedHeaders,
                            method: capturedMethod,
                            path: capturedPath,
                            version: capturedVersion,
                            targetPort: targetPort,
                            targetHost: targetHost,
                            isMessageRequest: isMessageRequest,
                            messageLifecycle: messageLifecycle
                        )
                    }
                })

            case .failed:
                timeoutState.cancelled = true
                self.completeMessageFlowIfNeeded(
                    isMessageRequest: isMessageRequest,
                    lifecycle: messageLifecycle,
                    outcome: .transientFailure
                )
                self.sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Cannot connect to proxy")
                targetConnection.cancel()

            default:
                break
            }
        }

        targetConnection.start(queue: .global(qos: .userInitiated))
    }
    
    // MARK: - Response Streaming (Iterative)

    private nonisolated func receiveResponse(
        from targetConnection: NWConnection,
        to originalConnection: NWConnection,
        connectionId: Int,
        startTime: Date,
        requestSize: Int,
        metadata: (provider: String?, model: String?, method: String, path: String),
        responseData: Data,
        fallbackContext: FallbackContext,
        headers: [(String, String)],
        method: String,
        path: String,
        version: String,
        targetPort: UInt16,
        targetHost: String,
        isMessageRequest: Bool,
        messageLifecycle: MessageRequestLifecycle?
    ) {
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil {
                self.completeMessageFlowIfNeeded(
                    isMessageRequest: isMessageRequest,
                    lifecycle: messageLifecycle,
                    outcome: .transientFailure
                )
                self.sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Upstream connection lost")
                targetConnection.cancel()
                return
            }

            // Use let to avoid captured var warning - Data is already accumulated via parameter
            let accumulatedResponse: Data
            if let data = data, !data.isEmpty {
                var newAccumulated = responseData
                newAccumulated.append(data)
                accumulatedResponse = newAccumulated
            } else {
                accumulatedResponse = responseData
            }

            // Check for quota exceeded BEFORE forwarding to client (within first 4KB to catch streaming errors)
            let quotaCheckThreshold = 4096
            if accumulatedResponse.count <= quotaCheckThreshold && !accumulatedResponse.isEmpty && fallbackContext.hasFallback {
                let fallbackReason = self.fallbackReason(responseData: accumulatedResponse)

                // Check for thinking signature errors - retry same provider with sanitized body
                if fallbackReason != nil {
                    let isSignatureError = FallbackFormatConverter.isThinkingSignatureError(responseData: accumulatedResponse)

                    if isSignatureError && !fallbackContext.triedSanitization,
                       let currentEntry = fallbackContext.currentEntry {
                        let sanitizedBody = self.sanitizeThinkingBlocks(fallbackContext.originalBody, targetModelId: currentEntry.modelId)

                        if sanitizedBody != fallbackContext.originalBody {
                            targetConnection.cancel()
                            let retryContext = fallbackContext.withSanitizationAttempted()

                            self.forwardRequest(
                                method: method,
                                path: path,
                                version: version,
                                headers: headers,
                                body: sanitizedBody,
                                originalConnection: originalConnection,
                                connectionId: connectionId,
                                startTime: startTime,
                                requestSize: requestSize,
                                metadata: metadata,
                                targetPort: targetPort,
                                targetHost: targetHost,
                                fallbackContext: retryContext,
                                isMessageRequest: isMessageRequest,
                                messageLifecycle: messageLifecycle
                            )
                            return
                        }
                    }
                }

                if let reason = fallbackReason, fallbackContext.hasMoreFallbacks {
                    // Don't forward error to client, try next fallback instead
                    targetConnection.cancel()

                    // Try next fallback
                    let updatedContext: FallbackContext
                    if let failedEntry = fallbackContext.currentEntry {
                        let failedAttempt = FallbackAttempt(entry: failedEntry, outcome: .failed, reason: reason)
                        updatedContext = fallbackContext.appendingAttempt(failedAttempt)
                    } else {
                        updatedContext = fallbackContext
                    }
                    let nextContext = updatedContext.next()
                    if let nextEntry = nextContext.currentEntry,
                       let virtualModelName = nextContext.virtualModelName {

                        // Update route state for UI display (cache is only updated on success)
                        Task { @MainActor in
                            let settings = FallbackSettingsManager.shared
                            settings.updateRouteState(
                                virtualModelName: virtualModelName,
                                entryIndex: nextContext.currentIndex,
                                entry: nextEntry,
                                totalEntries: nextContext.fallbackEntries.count
                            )
                        }

                        let nextBody = self.replaceModelInBody(fallbackContext.originalBody, with: nextEntry.modelId)

                        self.forwardRequest(
                            method: method,
                            path: path,
                            version: version,
                            headers: headers,
                            body: nextBody,
                            originalConnection: originalConnection,
                            connectionId: connectionId,
                            startTime: startTime,
                            requestSize: requestSize,
                            metadata: metadata,
                            targetPort: targetPort,
                            targetHost: targetHost,
                            fallbackContext: nextContext,
                            isMessageRequest: isMessageRequest,
                            messageLifecycle: messageLifecycle
                        )
                    }
                    return
                }
            }

            if let data = data, !data.isEmpty {
                // Forward chunk to client
                originalConnection.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        self.completeMessageFlowIfNeeded(
                            isMessageRequest: isMessageRequest,
                            lifecycle: messageLifecycle,
                            outcome: .transientFailure
                        )
                        targetConnection.cancel()
                        originalConnection.cancel()
                        return
                    }

                    if isComplete {
                        // Request complete - record metadata
                        self.recordCompletion(
                            connectionId: connectionId,
                            startTime: startTime,
                            requestSize: requestSize,
                            responseSize: accumulatedResponse.count,
                            responseData: accumulatedResponse,
                            metadata: metadata,
                            fallbackContext: fallbackContext,
                            isMessageRequest: isMessageRequest,
                            messageLifecycle: messageLifecycle
                        )

                        targetConnection.cancel()
                        originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                            originalConnection.cancel()
                        })
                    } else {
                        // Continue streaming - use async dispatch to break recursion stack
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.receiveResponse(
                                from: targetConnection,
                                to: originalConnection,
                                connectionId: connectionId,
                                startTime: startTime,
                                requestSize: requestSize,
                                metadata: metadata,
                                responseData: accumulatedResponse,
                                fallbackContext: fallbackContext,
                                headers: headers,
                                method: method,
                                path: path,
                                version: version,
                                targetPort: targetPort,
                                targetHost: targetHost,
                                isMessageRequest: isMessageRequest,
                                messageLifecycle: messageLifecycle
                            )
                        }
                    }
                })
            } else if isComplete {
                // Record completion
                self.recordCompletion(
                    connectionId: connectionId,
                    startTime: startTime,
                    requestSize: requestSize,
                    responseSize: accumulatedResponse.count,
                    responseData: accumulatedResponse,
                    metadata: metadata,
                    fallbackContext: fallbackContext,
                    isMessageRequest: isMessageRequest,
                    messageLifecycle: messageLifecycle
                )

                targetConnection.cancel()
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    originalConnection.cancel()
                })
            }
        }
    }
    
    // MARK: - Completion Recording

    private nonisolated func recordCompletion(
        connectionId: Int,
        startTime: Date,
        requestSize: Int,
        responseSize: Int,
        responseData: Data,
        metadata: (provider: String?, model: String?, method: String, path: String),
        fallbackContext: FallbackContext,
        isMessageRequest: Bool,
        messageLifecycle: MessageRequestLifecycle?
    ) {
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        // Extract status code from response
        var statusCode: Int?
        if let responseString = String(data: responseData.prefix(100), encoding: .utf8),
           let statusLine = responseString.components(separatedBy: "\r\n").first {
            // Parse "HTTP/1.1 200 OK"
            let parts = statusLine.components(separatedBy: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                statusCode = code
            }
        }

        let messageOutcome = messageRequestOutcome(statusCode: statusCode, responseData: responseData)
        completeMessageFlowIfNeeded(
            isMessageRequest: isMessageRequest,
            lifecycle: messageLifecycle,
            outcome: messageOutcome
        )

        let tokenUsage = extractUsageTokens(fromHTTPResponseData: responseData)

        // Capture variables for Sendable closure
        let capturedStatusCode = statusCode
        let capturedMetadata = metadata

        // Extract resolved model/provider from fallback context
        let resolvedModel: String? = fallbackContext.currentEntry?.modelId
        let resolvedProvider: String? = fallbackContext.currentEntry?.provider.rawValue

        let finalReason: FallbackTriggerReason?
        if let statusCode = statusCode, !(200..<300).contains(statusCode) {
            finalReason = fallbackReason(responseData: responseData) ?? .httpStatus(statusCode)
        } else {
            finalReason = nil
        }

        var attempts = fallbackContext.attempts
        if fallbackContext.hasFallback,
           (fallbackContext.wasLoadedFromCache ||
            fallbackContext.currentIndex > 0 ||
            !attempts.isEmpty ||
            finalReason != nil),
           let entry = fallbackContext.currentEntry {
            let outcome: FallbackAttemptOutcome = finalReason == nil ? .success : .failed
            let finalAttempt = FallbackAttempt(entry: entry, outcome: outcome, reason: finalReason)
            attempts.append(finalAttempt)
        }

        let responseSnippet: String? = finalReason == nil ? nil : responseBodySnippet(from: responseData)

        // Notify callback on main thread
        Task { @MainActor [weak self] in
            // Cache successful entry ONLY if:
            // 1. Response is successful (HTTP 2xx)
            // 2. Fallback was actually triggered (currentIndex > 0)
            // 3. Entry was NOT loaded from cache (wasLoadedFromCache == false)
            if let statusCode = capturedStatusCode, (200..<300).contains(statusCode),
               fallbackContext.currentIndex > 0,
               !fallbackContext.wasLoadedFromCache,
               let virtualModelName = fallbackContext.virtualModelName,
               let currentEntry = fallbackContext.currentEntry {
                let settings = FallbackSettingsManager.shared
                settings.setCachedEntryId(for: virtualModelName, entryId: currentEntry.id)
                settings.updateRouteState(
                    virtualModelName: virtualModelName,
                    entryIndex: fallbackContext.currentIndex,
                    entry: currentEntry,
                    totalEntries: fallbackContext.fallbackEntries.count
                )
            }

            let requestMetadata = RequestMetadata(
                timestamp: startTime,
                method: capturedMetadata.method,
                path: capturedMetadata.path,
                provider: capturedMetadata.provider,
                model: capturedMetadata.model,
                resolvedModel: resolvedModel,
                resolvedProvider: resolvedProvider,
                inputTokens: tokenUsage.input,
                outputTokens: tokenUsage.output,
                statusCode: capturedStatusCode,
                durationMs: durationMs,
                requestSize: requestSize,
                responseSize: responseSize,
                fallbackAttempts: attempts,
                fallbackStartedFromCache: fallbackContext.wasLoadedFromCache,
                responseSnippet: responseSnippet
            )
            self?.onRequestCompleted?(requestMetadata)
        }
    }

    private nonisolated func extractUsageTokens(fromHTTPResponseData responseData: Data) -> (input: Int?, output: Int?) {
        let parsedResponse = parseHTTPResponse(responseData)
        guard !parsedResponse.body.isEmpty else {
            return (nil, nil)
        }

        let jsonTokens = extractUsageTokensFromJSONBody(parsedResponse.body)
        if jsonTokens.input != nil || jsonTokens.output != nil {
            return jsonTokens
        }

        let sseTokens = extractUsageTokensFromSSEBody(parsedResponse.body)
        if sseTokens.input != nil || sseTokens.output != nil {
            return sseTokens
        }

        return (nil, nil)
    }

    private nonisolated func parseHTTPResponse(_ responseData: Data) -> (headers: [String: String], body: Data) {
        let separator = Data([13, 10, 13, 10]) // CRLFCRLF
        guard let boundary = responseData.range(of: separator) else {
            return ([:], responseData)
        }

        let headerData = responseData.subdata(in: responseData.startIndex..<boundary.lowerBound)
        var bodyData = responseData.subdata(in: boundary.upperBound..<responseData.endIndex)

        var headers: [String: String] = [:]
        if let headerString = String(data: headerData, encoding: .utf8) {
            for line in headerString.components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    headers[name] = value
                }
            }
        }

        if headers["transfer-encoding"]?.localizedCaseInsensitiveContains("chunked") == true,
           let decodedChunked = decodeChunkedBody(bodyData) {
            bodyData = decodedChunked
        }

        return (headers, bodyData)
    }

    private nonisolated func decodeChunkedBody(_ chunkedData: Data) -> Data? {
        let bytes = Array(chunkedData)
        var index = 0
        var decoded = Data()

        while index < bytes.count {
            guard let lineEnd = findCRLFIndex(in: bytes, from: index) else {
                return nil
            }

            let sizeLineBytes = bytes[index..<lineEnd]
            guard let sizeLine = String(bytes: sizeLineBytes, encoding: .utf8) else {
                return nil
            }

            let sizeToken = sizeLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first ?? ""

            guard let chunkSize = Int(sizeToken, radix: 16) else {
                return nil
            }

            index = lineEnd + 2

            if chunkSize == 0 {
                return decoded
            }

            guard index + chunkSize <= bytes.count else {
                return nil
            }

            decoded.append(contentsOf: bytes[index..<(index + chunkSize)])
            index += chunkSize

            guard index + 1 < bytes.count, bytes[index] == 13, bytes[index + 1] == 10 else {
                return nil
            }

            index += 2
        }

        return decoded
    }

    private nonisolated func findCRLFIndex(in bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        var cursor = start
        while cursor + 1 < bytes.count {
            if bytes[cursor] == 13, bytes[cursor + 1] == 10 {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private nonisolated func extractUsageTokensFromJSONBody(_ bodyData: Data) -> (input: Int?, output: Int?) {
        guard let object = try? JSONSerialization.jsonObject(with: bodyData) else {
            return (nil, nil)
        }

        var inputCandidates: [Int] = []
        var outputCandidates: [Int] = []
        var totalCandidates: [Int] = []
        extractUsageCandidates(
            from: object,
            inputCandidates: &inputCandidates,
            outputCandidates: &outputCandidates,
            totalCandidates: &totalCandidates
        )
        return mergeTokenCandidates(inputCandidates: inputCandidates, outputCandidates: outputCandidates, totalCandidates: totalCandidates)
    }

    private nonisolated func extractUsageTokensFromSSEBody(_ bodyData: Data) -> (input: Int?, output: Int?) {
        guard let sseText = String(data: bodyData, encoding: .utf8), sseText.contains("data:") else {
            return (nil, nil)
        }

        var inputCandidates: [Int] = []
        var outputCandidates: [Int] = []
        var totalCandidates: [Int] = []

        for rawLine in sseText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }

            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let payloadData = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payloadData) else {
                continue
            }

            extractUsageCandidates(
                from: object,
                inputCandidates: &inputCandidates,
                outputCandidates: &outputCandidates,
                totalCandidates: &totalCandidates
            )
        }

        return mergeTokenCandidates(inputCandidates: inputCandidates, outputCandidates: outputCandidates, totalCandidates: totalCandidates)
    }

    private nonisolated func extractUsageCandidates(
        from object: Any,
        inputCandidates: inout [Int],
        outputCandidates: inout [Int],
        totalCandidates: inout [Int]
    ) {
        if let dictionary = object as? [String: Any] {
            let usageLike = dictionary["usage"] as? [String: Any]
            let usageMetadata = dictionary["usageMetadata"] as? [String: Any]
            let usageMetadataSnake = dictionary["usage_metadata"] as? [String: Any]

            let inputTokenKeys = [
                "input_tokens",
                "prompt_tokens",
                "inputTokenCount",
                "promptTokenCount",
                "prompt_tokens_details.cached_tokens",
                "cache_creation_input_tokens",
                "cache_read_input_tokens"
            ]
            let outputTokenKeys = [
                "output_tokens",
                "completion_tokens",
                "outputTokenCount",
                "candidatesTokenCount",
                "completion_tokens_details.reasoning_tokens"
            ]
            let totalTokenKeys = [
                "total_tokens",
                "totalTokenCount"
            ]

            func collectValues(from source: [String: Any]) {
                for key in inputTokenKeys {
                    if let value = intValue(at: key, in: source) {
                        inputCandidates.append(value)
                    }
                }
                for key in outputTokenKeys {
                    if let value = intValue(at: key, in: source) {
                        outputCandidates.append(value)
                    }
                }
                for key in totalTokenKeys {
                    if let value = intValue(at: key, in: source) {
                        totalCandidates.append(value)
                    }
                }
            }

            collectValues(from: dictionary)
            if let usageLike {
                collectValues(from: usageLike)
            }
            if let usageMetadata {
                collectValues(from: usageMetadata)
            }
            if let usageMetadataSnake {
                collectValues(from: usageMetadataSnake)
            }

            for nested in dictionary.values {
                extractUsageCandidates(
                    from: nested,
                    inputCandidates: &inputCandidates,
                    outputCandidates: &outputCandidates,
                    totalCandidates: &totalCandidates
                )
            }
            return
        }

        if let array = object as? [Any] {
            for item in array {
                extractUsageCandidates(
                    from: item,
                    inputCandidates: &inputCandidates,
                    outputCandidates: &outputCandidates,
                    totalCandidates: &totalCandidates
                )
            }
        }
    }

    private nonisolated func mergeTokenCandidates(
        inputCandidates: [Int],
        outputCandidates: [Int],
        totalCandidates: [Int]
    ) -> (input: Int?, output: Int?) {
        var input = inputCandidates.max()
        var output = outputCandidates.max()
        let total = totalCandidates.max()

        if let total {
            if let output, input == nil {
                input = max(total - output, 0)
            } else if let input, output == nil {
                output = max(total - input, 0)
            } else if input == nil, output == nil {
                output = total
            }
        }

        return (input, output)
    }

    private nonisolated func intValue(at keyPath: String, in dictionary: [String: Any]) -> Int? {
        let segments = keyPath.split(separator: ".").map(String.init)
        guard !segments.isEmpty else { return nil }

        var current: Any = dictionary
        for segment in segments.dropLast() {
            guard let dict = current as? [String: Any], let next = dict[segment] else {
                return nil
            }
            current = next
        }

        guard let finalDictionary = current as? [String: Any] else {
            return nil
        }
        return intValue(from: finalDictionary[segments.last ?? ""])
    }

    private nonisolated func intValue(from value: Any?) -> Int? {
        guard let value else { return nil }

        if let int = value as? Int {
            return int
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        if let double = value as? Double {
            return Int(double.rounded())
        }

        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }
    
    // MARK: - Error Response
    
    private nonisolated func sendError(
        to connection: NWConnection,
        statusCode: Int,
        message: String,
        additionalHeaders: [(String, String)] = []
    ) {
        guard let bodyData = message.data(using: .utf8) else {
            connection.cancel()
            return
        }
        
        // Map status code to proper HTTP reason phrase
        let reasonPhrase: String
        switch statusCode {
        case 400: reasonPhrase = "Bad Request"
        case 404: reasonPhrase = "Not Found"
        case 500: reasonPhrase = "Internal Server Error"
        case 502: reasonPhrase = "Bad Gateway"
        case 503: reasonPhrase = "Service Unavailable"
        default: reasonPhrase = "Error"
        }
        
        // Build HTTP response with proper CRLF line endings (no leading whitespace)
        var headers = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n" +
            "Content-Type: text/plain\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n"
        for (name, value) in additionalHeaders {
            headers += "\(name): \(value)\r\n"
        }
        headers += "\r\n"
        
        guard let headerData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }
        
        var responseData = Data()
        responseData.append(headerData)
        responseData.append(bodyData)
        
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
