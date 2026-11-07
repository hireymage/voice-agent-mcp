import Foundation

struct ToolDef: Sendable {
    let name: String
    let description: String
    let schema: JSONValue
}

struct ToolCall: Hashable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

/// A provider's own form of an assistant turn (thinking signatures, reasoning items). Replayed only to the same API.
struct RawTurn: Hashable, Sendable {
    let api: LLMAPI
    let content: JSONValue
}

struct ChatMessage: Hashable, Sendable {
    enum Role: Sendable { case user, assistant, tool }
    var role: Role
    var text = ""
    var toolCalls: [ToolCall] = []
    var toolCallID = ""
    var toolName = ""
    var isError = false
    var raw: RawTurn?

    static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, text: text) }
    static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, text: text) }
    static func toolResult(call: ToolCall, text: String, isError: Bool) -> ChatMessage {
        ChatMessage(role: .tool, text: text, toolCallID: call.id, toolName: call.name, isError: isError)
    }
}

struct LLMResponse: Sendable {
    var text = ""
    var toolCalls: [ToolCall] = []
    var raw: RawTurn?
}

struct LLMConfig: Sendable {
    let api: LLMAPI
    let baseURL: String
    let apiKey: String
    let model: String
    let extra: JSONValue?
    var thinking = Thinking.model

    var base: String {
        var b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    func url(_ path: String) throws -> URL {
        guard let u = URL(string: base + path), u.scheme != nil else { throw AppError(tr("Invalid server address: %@", baseURL)) }
        return u
    }
}

extension LLMConfig {
    /// Models differ in which thinking parameters they accept, so the request goes out with each variant in turn
    /// until the server takes one. If none is taken, the server's answer to the first one is shown.
    func firstAccepted(_ send: (JSONValue?) async throws -> LLMResponse) async throws -> LLMResponse {
        let variants = thinking.variants(api: api, model: model, base: base)
        var first: Error?
        for variant in variants {
            do {
                return try await send(variant)
            } catch let failure as HTTPFailure where [400, 422].contains(failure.status) && !failure.isContextLimit && variants.count > 1 {
                first = first ?? failure
            }
        }
        throw first ?? AppError("The model failed.")
    }
}

extension Thinking {
    /// Request parameters for this level, best first. Nothing for the model's own default and for Apple's model.
    func variants(api: LLMAPI, model: String, base: String) -> [JSONValue?] {
        guard self != .model, api != .apple else { return [nil] }
        let level = JSONValue.string(rawValue)
        // Where "off" is not accepted, the lowest level that is comes instead.
        let offEfforts: [JSONValue] = ["none", "minimal", "low"]
        switch api {
        case .openAIChat:
            let clouds = ["api.openai.com", "openrouter.ai", "api.groq.com", "api.mistral.ai", "api.deepseek.com", "api.x.ai"]
            if clouds.contains(where: base.contains) {
                return self == .off ? offEfforts.map { ["reasoning_effort": $0] } : [["reasoning_effort": level]]
            }
            // Own servers (Ollama, vLLM, llama.cpp, LM Studio): reasoning_effort "none" makes some models write their
            // thinking into the answer, so "off" is the chat template switch that models such as Qwen and GLM have.
            return self == .off ? [["chat_template_kwargs": ["enable_thinking": false]]] : [["reasoning_effort": level]]
        case .openAIResponses:
            return self == .off ? offEfforts.map { ["reasoning": ["effort": $0]] } : [["reasoning": ["effort": level]]]
        case .anthropic:
            // Current Claude models take adaptive thinking with an effort; older ones a token budget, which needs room
            // under max_tokens. Some current ones cannot switch thinking off or only "between tools".
            if self == .off {
                return [["thinking": ["type": "disabled"]], ["thinking": ["type": "between_tools"]], ["output_config": ["effort": "low"]]]
            }
            let budget = ["low": 2048, "medium": 8192, "high": 16384][rawValue] ?? 8192
            return [["thinking": ["type": "adaptive"], "output_config": ["effort": level]],
                    ["thinking": ["type": "enabled", "budget_tokens": .number(Double(budget))], "max_tokens": .number(Double(budget + 8192))]]
        case .gemini:
            if model.contains("gemini-2") {
                let budgets: [Thinking: [Int]] = [.off: [0, 128], .low: [1024], .medium: [8192], .high: [24576]]
                return (budgets[self] ?? [8192]).map { ["generationConfig": ["thinkingConfig": ["thinkingBudget": .number(Double($0))]]] }
            }
            let levels: [Thinking: [String]] = [.off: ["minimal", "low"], .low: ["low"], .medium: ["medium", "high"], .high: ["high"]]
            return (levels[self] ?? ["high"]).map { ["generationConfig": ["thinkingConfig": ["thinkingLevel": .string($0)]]] }
        case .apple:
            return [nil]
        }
    }
}

protocol LLMClient: Sendable {
    func complete(system: String, messages: [ChatMessage], tools: [ToolDef], onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse
}

func makeLLMClient(_ c: LLMConfig) -> LLMClient {
    switch c.api {
    case .openAIChat: OpenAIChatClient(c)
    case .openAIResponses: OpenAIResponsesClient(c)
    case .anthropic: AnthropicClient(c)
    case .gemini: GeminiClient(c)
    case .apple: AppleModelClient(model: c.model)
    }
}

/// Up to 300 characters of the server's own message, so a wrong model or key can be read off the screen.
struct HTTPFailure: LocalizedError {
    let status: Int
    let body: String
    var errorDescription: String? {
        let detail = JSONValue.parse(body).flatMap { $0["error"]?["message"]?.string ?? $0["error"]?.string ?? $0["message"]?.string } ?? body
        return "HTTP \(status): \(detail.prefix(300))"
    }
}

/// The conversation no longer fits into the model.
struct ContextLimitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension HTTPFailure {
    /// Servers have no common code for this, so these are the wordings of their APIs.
    var isContextLimit: Bool {
        guard [400, 413, 422].contains(status) else { return false }
        let text = body.lowercased()
        return ["context_length", "context length", "context window", "maximum context", "prompt is too long", "too many tokens",
                "input is too long", "request_too_large", "input token count", "exceeds the maximum number of tokens"].contains { text.contains($0) }
    }
}

func isContextLimit(_ error: Error) -> Bool {
    error is ContextLimitError || (error as? HTTPFailure)?.isContextLimit == true
}

/// Lines of a server-sent event stream: only `data:` payloads, without `[DONE]`. A server that ignored
/// `stream: true` and answered with plain JSON comes out as one payload.
func sseData(_ request: URLRequest, session: URLSession = .shared) -> AsyncThrowingStream<(event: String?, json: JSONValue), Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !(200..<300).contains(status) {
                    var body = Data()
                    for try await b in bytes { body.append(b); if body.count > 4096 { break } }
                    throw HTTPFailure(status: status, body: String(decoding: body, as: UTF8.self))
                }
                var event: String?
                var plain = ""
                var sawData = false
                for try await line in bytes.lines {
                    if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
                    if line.hasPrefix("data:") {
                        sawData = true
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { continue }
                        if let json = JSONValue.parse(payload) { continuation.yield((event, json)) }
                    } else if !sawData, !line.hasPrefix(":") {
                        plain += line
                    }
                }
                if !sawData, let json = JSONValue.parse(plain) { continuation.yield((nil, json)) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

func jsonRequest(_ url: URL, body: JSONValue, headers: [String: String] = [:]) -> URLRequest {
    var r = URLRequest(url: url, timeoutInterval: 300)
    r.httpMethod = "POST"
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    r.httpBody = body.data()
    return r
}

/// Parses the "extra parameters" field of a model. A typo is an error here, not a silently ignored setting.
func parseExtraParams(_ text: String) throws -> JSONValue? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    guard let v = JSONValue.parse(t), v.object != nil else { throw AppError("Extra parameters must be a JSON object.") }
    return v
}

/// Models offered by the server, so no model name is hard-coded in the app.
func listModels(api: LLMAPI, baseURL: String, apiKey: String, session: URLSession = .shared) async throws -> [String] {
    let c = LLMConfig(api: api, baseURL: baseURL, apiKey: apiKey, model: "", extra: nil)
    var r: URLRequest
    switch api {
    case .apple:
        return try AppleModel.names()
    case .openAIChat, .openAIResponses:
        r = URLRequest(url: try c.url("/models"), timeoutInterval: 20)
        if !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    case .anthropic:
        r = URLRequest(url: try c.url(c.base.hasSuffix("/v1") ? "/models?limit=1000" : "/v1/models?limit=1000"), timeoutInterval: 20)
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    case .gemini:
        r = URLRequest(url: try c.url("/models?pageSize=1000"), timeoutInterval: 20)
        r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    }
    let (data, response) = try await session.data(for: r)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw HTTPFailure(status: status, body: String(decoding: data.prefix(4096), as: UTF8.self)) }
    guard let json = JSONValue.parse(data) else { throw AppError("The server did not return JSON.") }
    if api == .gemini {
        return (json["models"]?.array ?? [])
            .filter { ($0["supportedGenerationMethods"]?.array ?? []).contains("generateContent") }
            .compactMap { $0["name"]?.string?.replacingOccurrences(of: "models/", with: "") }
            .sorted()
    }
    return (json["data"]?.array ?? []).compactMap { $0["id"]?.string }.sorted()
}
