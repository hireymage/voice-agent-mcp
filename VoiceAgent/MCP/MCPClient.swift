import Foundation

struct MCPTool: Sendable, Hashable {
    let name: String
    let description: String
    let schema: JSONValue
    /// What the server says about the tool; many servers say nothing.
    var readOnly: Bool?
}

/// MCP over Streamable HTTP: JSON-RPC by POST, answered with JSON or an event stream.
actor MCPClient {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private var sessionID: String?
    private var protocolVersion: String?
    private var nextID = 1
    private var initialized = false

    init(url: URL, headers: [String: String], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    func listTools() async throws -> [MCPTool] {
        var out: [MCPTool] = []
        var cursor: String?
        repeat {
            let result = try await request("tools/list", cursor.map { ["cursor": .string($0)] } ?? [:])
            for t in result["tools"]?.array ?? [] {
                guard let name = t["name"]?.string else { continue }
                var readOnly: Bool?
                if case .bool(let hint)? = t["annotations"]?["readOnlyHint"] { readOnly = hint }
                out.append(MCPTool(name: name, description: t["description"]?.string ?? "", schema: t["inputSchema"] ?? ["type": "object", "properties": [:]], readOnly: readOnly))
            }
            cursor = result["nextCursor"]?.string
        } while cursor != nil
        return out
    }

    func call(tool: String, arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        let result = try await request("tools/call", ["name": .string(tool), "arguments": arguments])
        var parts: [String] = []
        for c in result["content"]?.array ?? [] {
            if let t = c["text"]?.string { parts.append(t) }
            else if let t = c["resource"]?["text"]?.string { parts.append(t) }
            else if let kind = c["type"]?.string { parts.append("[\(kind) content omitted]") }
        }
        if parts.isEmpty, let s = result["structuredContent"] { parts.append(s.compact) }
        return (parts.joined(separator: "\n"), result["isError"]?.bool ?? false)
    }

    private func ensureInitialized() async throws {
        if initialized { return }
        let result = try await rpc("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "VoiceAgent", "version": "0.1"],
        ], allowRestart: false)
        protocolVersion = result["protocolVersion"]?.string
        initialized = true
        _ = try? await post(["jsonrpc": "2.0", "method": "notifications/initialized"], id: nil)
    }

    private func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await ensureInitialized()
        return try await rpc(method, params, allowRestart: true)
    }

    private func rpc(_ method: String, _ params: JSONValue, allowRestart: Bool) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        do {
            let reply = try await post(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params], id: id)
            if let e = reply?["error"] { throw AppError("MCP: \(e["message"]?.string ?? e.compact)") }
            return reply?["result"] ?? [:]
        } catch let failure as HTTPFailure where failure.status == 404 && allowRestart && sessionID != nil {
            // The spec's way of saying the session expired (a restarted server, for instance).
            sessionID = nil
            initialized = false
            try await ensureInitialized()
            return try await rpc(method, params, allowRestart: false)
        }
    }

    private func post(_ message: JSONValue, id: Int?) async throws -> JSONValue? {
        var r = jsonRequest(url, body: message, headers: headers)
        r.timeoutInterval = 180
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { r.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { r.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        let (bytes, response) = try await session.bytes(for: r)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if let s = http?.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = s }
        if !(200..<300).contains(status) {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 4096 { break } }
            throw HTTPFailure(status: status, body: String(decoding: body, as: UTF8.self))
        }
        guard let id else { return nil }
        if http?.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            // Notifications may come first; the answer is the message carrying our id.
            for try await line in bytes.lines where line.hasPrefix("data:") {
                guard let json = JSONValue.parse(String(line.dropFirst(5))) else { continue }
                if json["id"]?.int == id { return json }
            }
            throw AppError("MCP: the stream ended without an answer.")
        }
        var body = Data()
        for try await b in bytes { body.append(b) }
        guard let json = JSONValue.parse(body) else { throw AppError("MCP: the server did not return JSON.") }
        return json
    }
}

/// One tool as the models see it, with the name the APIs accept (letters, digits, _ and -; 64 characters at most).
struct BoundTool: Sendable {
    let def: ToolDef
    let client: MCPClient
    let remoteName: String
    var readOnly: Bool?
    var serverID: UUID?

    /// About how many tokens its description takes in every request (four characters a token, roughly).
    var tokenEstimate: Int {
        let json = JSONValue.object(["name": .string(def.name), "description": .string(def.description), "parameters": def.schema]).compact
        return max(1, json.count / 4)
    }
}

enum MCPTools {
    static func modelName(server: String, tool: String, taken: Set<String>) -> String {
        let clean = { (s: String) in String(s.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" || $0 == "-" ? $0 : "_" }) }
        let base = String("\(clean(server))__\(clean(tool))".prefix(60))
        var name = base
        var n = 2
        while taken.contains(name) { name = "\(base)_\(n)"; n += 1 }
        return name
    }

    /// Connects to the given servers. One that is down is reported and the others stay usable.
    static func connect(_ servers: [MCPServer], headers: (MCPServer) -> [String: String]) async -> (tools: [BoundTool], failures: [String]) {
        let inputs = servers.map { ($0, headers($0)) }
        let results = await withTaskGroup(of: (MCPServer, MCPClient?, Result<[MCPTool], Error>).self) { group in
            for (server, hdrs) in inputs {
                group.addTask {
                    guard let url = URL(string: server.url.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
                        return (server, nil, .failure(AppError("Invalid address.")))
                    }
                    let client = MCPClient(url: url, headers: hdrs)
                    do { return (server, client, .success(try await client.listTools())) }
                    catch { return (server, client, .failure(error)) }
                }
            }
            var all: [(MCPServer, MCPClient?, Result<[MCPTool], Error>)] = []
            for await r in group { all.append(r) }
            return all
        }
        var tools: [BoundTool] = []
        var failures: [String] = []
        var taken = Set<String>()
        for (server, client, result) in results.sorted(by: { $0.0.name < $1.0.name }) {
            switch result {
            case .failure(let e): failures.append("\(server.name): \(e.localizedDescription)")
            case .success(let list):
                guard let client else { continue }
                for t in list where !server.disabledTools.contains(t.name) {
                    let name = modelName(server: server.name, tool: t.name, taken: taken)
                    taken.insert(name)
                    tools.append(BoundTool(def: ToolDef(name: name, description: t.description, schema: t.schema), client: client, remoteName: t.name, readOnly: t.readOnly, serverID: server.id))
                }
            }
        }
        return (tools, failures)
    }
}
