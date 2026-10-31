import Foundation

// MARK: - OpenAI Chat Completions (OpenAI, OpenRouter, Groq, Mistral, DeepSeek, xAI, Ollama, vLLM, LM Studio…)

struct OpenAIChatClient: LLMClient {
    let c: LLMConfig
    init(_ c: LLMConfig) { self.c = c }

    func body(system: String, messages: [ChatMessage], tools: [ToolDef]) -> JSONValue {
        var out: [JSONValue] = system.isEmpty ? [] : [["role": "system", "content": .string(system)]]
        for m in messages {
            switch m.role {
            case .user: out.append(["role": "user", "content": .string(m.text)])
            case .assistant:
                var a: [String: JSONValue] = ["role": "assistant", "content": m.text.isEmpty ? .null : .string(m.text)]
                if !m.toolCalls.isEmpty {
                    a["tool_calls"] = .array(m.toolCalls.map {
                        ["id": .string($0.id), "type": "function", "function": ["name": .string($0.name), "arguments": .string($0.arguments)]]
                    })
                }
                if m.raw?.api == .openAIChat, let extra = m.raw?.content.object { for (k, v) in extra { a[k] = v } }
                out.append(.object(a))
            case .tool: out.append(["role": "tool", "tool_call_id": .string(m.toolCallID), "content": .string(m.text)])
            }
        }
        var b: JSONValue = ["model": .string(c.model), "stream": true, "messages": .array(out)]
        if !tools.isEmpty {
            b = b.merging(["tools": .array(tools.map {
                ["type": "function", "function": ["name": .string($0.name), "description": .string($0.description), "parameters": $0.schema]]
            })])
        }
        return b.merging(c.extra)
    }

    func complete(system: String, messages: [ChatMessage], tools: [ToolDef], onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse {
        var headers: [String: String] = [:]
        if !c.apiKey.isEmpty { headers["Authorization"] = "Bearer \(c.apiKey)" }
        let req = jsonRequest(try c.url("/chat/completions"), body: body(system: system, messages: messages, tools: tools), headers: headers)
        return try await consume(sseData(req), onText: onText)
    }

    func consume(_ stream: AsyncThrowingStream<(event: String?, json: JSONValue), Error>, onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse {
        var r = LLMResponse()
        var calls: [Int: ToolCall] = [:]
        var reasoning = ""
        for try await (_, json) in stream {
            if let e = json["error"] { throw AppError(e["message"]?.string ?? e.compact) }
            guard let choice = json["choices"]?.array?.first else { continue }
            let d = choice["delta"] ?? choice["message"] ?? [:]
            if let t = d["content"]?.string, !t.isEmpty { r.text += t; onText(t) }
            if let t = d["reasoning_content"]?.string { reasoning += t }
            for (pos, tc) in (d["tool_calls"]?.array ?? []).enumerated() {
                let i = tc["index"]?.int ?? pos
                var call = calls[i] ?? ToolCall(id: "", name: "", arguments: "")
                if let v = tc["id"]?.string, !v.isEmpty { call.id = v }
                if let v = tc["function"]?["name"]?.string { call.name += v }
                if let v = tc["function"]?["arguments"]?.string { call.arguments += v }
                calls[i] = call
            }
        }
        r.toolCalls = calls.sorted { $0.key < $1.key }.map { _, call in
            var call = call
            if call.id.isEmpty { call.id = "call_\(UUID().uuidString.prefix(8))" }
            if call.arguments.isEmpty { call.arguments = "{}" }
            return call
        }
        // Some servers (DeepSeek) ask for the reasoning back together with the tool call it led to.
        if !reasoning.isEmpty, !r.toolCalls.isEmpty { r.raw = RawTurn(api: .openAIChat, content: ["reasoning_content": .string(reasoning)]) }
        return r
    }
}

// MARK: - OpenAI Responses

struct OpenAIResponsesClient: LLMClient {
    let c: LLMConfig
    init(_ c: LLMConfig) { self.c = c }

    func body(system: String, messages: [ChatMessage], tools: [ToolDef]) -> JSONValue {
        var input: [JSONValue] = []
        for m in messages {
            switch m.role {
            case .user: input.append(["role": "user", "content": .string(m.text)])
            case .assistant:
                if m.raw?.api == .openAIResponses, let items = m.raw?.content.array { input += items; continue }
                if !m.text.isEmpty { input.append(["role": "assistant", "content": .string(m.text)]) }
                for t in m.toolCalls {
                    input.append(["type": "function_call", "call_id": .string(t.id), "name": .string(t.name), "arguments": .string(t.arguments)])
                }
            case .tool: input.append(["type": "function_call_output", "call_id": .string(m.toolCallID), "output": .string(m.text)])
            }
        }
        var b: JSONValue = ["model": .string(c.model), "stream": true, "input": .array(input)]
        if !system.isEmpty { b = b.merging(["instructions": .string(system)]) }
        if !tools.isEmpty {
            b = b.merging(["tools": .array(tools.map {
                ["type": "function", "name": .string($0.name), "description": .string($0.description), "parameters": $0.schema]
            })])
        }
        return b.merging(c.extra)
    }

    func complete(system: String, messages: [ChatMessage], tools: [ToolDef], onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse {
        var headers: [String: String] = [:]
        if !c.apiKey.isEmpty { headers["Authorization"] = "Bearer \(c.apiKey)" }
        let req = jsonRequest(try c.url("/responses"), body: body(system: system, messages: messages, tools: tools), headers: headers)
        return try await consume(sseData(req), onText: onText)
    }

    func consume(_ stream: AsyncThrowingStream<(event: String?, json: JSONValue), Error>, onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse {
        var r = LLMResponse()
        for try await (_, json) in stream {
            switch json["type"]?.string {
            case "response.output_text.delta":
                if let t = json["delta"]?.string { r.text += t; onText(t) }
            case "response.completed", "response.incomplete":
                let output = json["response"]?["output"]?.array ?? []
                r.toolCalls = output.filter { $0["type"]?.string == "function_call" }.map {
                    ToolCall(id: $0["call_id"]?.string ?? UUID().uuidString, name: $0["name"]?.string ?? "", arguments: $0["arguments"]?.string ?? "{}")
                }
                r.raw = RawTurn(api: .openAIResponses, content: .array(output))
            case "response.failed":
                throw AppError(json["response"]?["error"]?["message"]?.string ?? "The model failed.")
            case "error":
                throw AppError(json["message"]?.string ?? json["error"]?["message"]?.string ?? "The model failed.")
            default: break
            }
        }
        return r
    }
}

// MARK: - Anthropic Messages

struct AnthropicClient: LLMClient {
    let c: LLMConfig
    init(_ c: LLMConfig) { self.c = c }

    func body(system: String, messages: [ChatMessage], tools: [ToolDef]) -> JSONValue {
        var out: [JSONValue] = []
        var pendingResults: [JSONValue] = []
        func flushResults() {
            if !pendingResults.isEmpty { out.append(["role": "user", "content": .array(pendingResults)]); pendingResults = [] }
        }
        for m in messages {
            if m.role == .tool {
                var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(m.toolCallID), "content": .string(m.text)]
                if m.isError { block["is_error"] = true }
                pendingResults.append(.object(block))
                continue
            }
            flushResults()
            if m.role == .user { out.append(["role": "user", "content": .string(m.text)]); continue }
            if m.raw?.api == .anthropic, let blocks = m.raw?.content { out.append(["role": "assistant", "content": blocks]); continue }
            var blocks: [JSONValue] = m.text.isEmpty ? [] : [["type": "text", "text": .string(m.text)]]
            for t in m.toolCalls {
                blocks.append(["type": "tool_use", "id": .string(t.id), "name": .string(t.name), "input": JSONValue.parse(t.arguments) ?? [:]])
            }
            out.append(["role": "assistant", "content": .array(blocks)])
        }
        flushResults()
        var b: JSONValue = ["model": .string(c.model), "stream": true, "max_tokens": 8192, "messages": .array(out)]
        if !system.isEmpty { b = b.merging(["system": .string(system)]) }
        if !tools.isEmpty {
            b = b.merging(["tools": .array(tools.map {
                ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.schema]
            })])
        }
        return b.merging(c.extra)
    }

    func complete(system: String, messages: [ChatMessage], tools: [ToolDef], onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse {
        let req = jsonRequest(try c.url(c.base.hasSuffix("/v1") ? "/messages" : "/v1/messages"), body: body(system: system, messages: messages, tools: tools), headers: ["x-api-key": c.apiKey, "anthropic-version": "2023-06-01"])
        return try await consume(sseData(req), onText: onText)
    }

    func consume(_ stream: AsyncThrowingStream<(event: String?, json: JSONValue), Error>, onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse {
        var r = LLMResponse()
        var blocks: [Int: [String: JSONValue]] = [:]
        var partial: [Int: String] = [:]
        func append(_ text: String, to field: String, of index: Int) {
            guard var block = blocks[index] else { return }
            block[field] = .string((block[field]?.string ?? "") + text)
            blocks[index] = block
        }
        for try await (_, json) in stream {
            switch json["type"]?.string {
            case "content_block_start":
                if let i = json["index"]?.int, let b = json["content_block"]?.object { blocks[i] = b }
            case "content_block_delta":
                guard let i = json["index"]?.int, let d = json["delta"] else { continue }
                switch d["type"]?.string {
                case "text_delta":
                    if let t = d["text"]?.string {
                        r.text += t
                        onText(t)
                        append(t, to: "text", of: i)
                    }
                case "input_json_delta": partial[i, default: ""] += d["partial_json"]?.string ?? ""
                case "thinking_delta": append(d["thinking"]?.string ?? "", to: "thinking", of: i)
                case "signature_delta": append(d["signature"]?.string ?? "", to: "signature", of: i)
                default: break
                }
            case "error":
                throw AppError(json["error"]?["message"]?.string ?? "The model failed.")
            default: break
            }
        }
        var ordered: [JSONValue] = []
        for (i, var b) in blocks.sorted(by: { $0.key < $1.key }) {
            if b["type"]?.string == "tool_use" {
                let args = partial[i].flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
                b["input"] = JSONValue.parse(args) ?? [:]
                r.toolCalls.append(ToolCall(id: b["id"]?.string ?? UUID().uuidString, name: b["name"]?.string ?? "", arguments: args))
            }
            ordered.append(.object(b))
        }
        r.raw = RawTurn(api: .anthropic, content: .array(ordered))
        return r
    }
}

// MARK: - Google Gemini

struct GeminiClient: LLMClient {
    let c: LLMConfig
    init(_ c: LLMConfig) { self.c = c }

    func body(system: String, messages: [ChatMessage], tools: [ToolDef]) -> JSONValue {
        var contents: [JSONValue] = []
        var results: [JSONValue] = []
        func flushResults() {
            if !results.isEmpty { contents.append(["role": "user", "parts": .array(results)]); results = [] }
        }
        for m in messages {
            if m.role == .tool {
                results.append(["functionResponse": ["name": .string(m.toolName), "response": [m.isError ? "error" : "result": .string(m.text)]]])
                continue
            }
            flushResults()
            if m.role == .user { contents.append(["role": "user", "parts": [["text": .string(m.text)]]]); continue }
            if m.raw?.api == .gemini, let parts = m.raw?.content { contents.append(["role": "model", "parts": parts]); continue }
            var parts: [JSONValue] = m.text.isEmpty ? [] : [["text": .string(m.text)]]
            for t in m.toolCalls { parts.append(["functionCall": ["name": .string(t.name), "args": JSONValue.parse(t.arguments) ?? [:]]]) }
            contents.append(["role": "model", "parts": .array(parts)])
        }
        flushResults()
        var b: JSONValue = ["contents": .array(contents)]
        if !system.isEmpty { b = b.merging(["systemInstruction": ["parts": [["text": .string(system)]]]]) }
        if !tools.isEmpty {
            b = b.merging(["tools": [["functionDeclarations": .array(tools.map {
                ["name": .string($0.name), "description": .string($0.description), "parametersJsonSchema": $0.schema]
            })]]])
        }
        return b.merging(c.extra)
    }

    func complete(system: String, messages: [ChatMessage], tools: [ToolDef], onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse {
        let model = c.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? c.model
        let req = jsonRequest(try c.url("/models/\(model):streamGenerateContent?alt=sse"), body: body(system: system, messages: messages, tools: tools), headers: ["x-goog-api-key": c.apiKey])
        return try await consume(sseData(req), onText: onText)
    }

    func consume(_ stream: AsyncThrowingStream<(event: String?, json: JSONValue), Error>, onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse {
        var r = LLMResponse()
        var all: [JSONValue] = []
        for try await (_, json) in stream {
            if let e = json["error"] { throw AppError(e["message"]?.string ?? e.compact) }
            for part in json["candidates"]?.array?.first?["content"]?["parts"]?.array ?? [] {
                all.append(part)
                if let f = part["functionCall"] {
                    r.toolCalls.append(ToolCall(id: f["id"]?.string ?? "call_\(UUID().uuidString.prefix(8))", name: f["name"]?.string ?? "", arguments: (f["args"] ?? [:]).compact))
                } else if part["thought"]?.bool != true, let t = part["text"]?.string, !t.isEmpty {
                    r.text += t
                    onText(t)
                }
            }
        }
        r.raw = RawTurn(api: .gemini, content: .array(all))
        return r
    }
}
