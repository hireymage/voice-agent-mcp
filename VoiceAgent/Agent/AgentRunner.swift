import Foundation

struct AgentTool: Sendable {
    let def: ToolDef
    let run: @Sendable (_ arguments: String) async -> (text: String, isError: Bool)

    static func mcp(_ t: BoundTool, onResult: (@Sendable (String) -> Void)? = nil) -> AgentTool {
        AgentTool(def: t.def) { arguments in
            guard let args = JSONValue.parse(arguments.isEmpty ? "{}" : arguments), args.object != nil else {
                return ("Tool arguments were not a JSON object.", true)
            }
            do {
                let r = try await t.client.call(tool: t.remoteName, arguments: args)
                if !r.isError { onResult?(r.text) }
                return r
            } catch {
                return (error.localizedDescription, true)
            }
        }
    }
}

/// Removes reasoning from a text stream: `<think>…</think>` blocks, and a stray `</think>` some models emit.
/// After a full answer a stray close is followed by the same answer again (GLM), so what follows is dropped;
/// after a short lead-in it only separates text.
final class ThinkFilter: @unchecked Sendable {
    private static let open = "<think>", close = "</think>"
    private static let strayAnswerChars = 80
    private var pending = ""
    private var inside = false
    private var muted = false
    private var visibleChars = 0

    func push(_ delta: String) -> String {
        if muted { return "" }
        pending += delta
        var out = ""
        while !pending.isEmpty {
            if inside {
                guard let r = pending.range(of: Self.close, options: .caseInsensitive) else {
                    pending = String(pending.suffix(Self.close.count - 1))
                    return emit(out)
                }
                pending = String(pending[r.upperBound...])
                inside = false
                continue
            }
            let o = pending.range(of: Self.open, options: .caseInsensitive)
            let c = pending.range(of: Self.close, options: .caseInsensitive)
            if let o, c == nil || o.lowerBound < c!.lowerBound {
                out += pending[..<o.lowerBound]
                pending = String(pending[o.upperBound...])
                inside = true
            } else if let c {
                out += pending[..<c.lowerBound]
                let after = String(pending[c.upperBound...])
                pending = ""
                if visibleChars + out.count >= Self.strayAnswerChars {
                    muted = true
                    return emit(out)
                }
                out += " "
                pending = after
            } else {
                let keep = partialTagLength(pending)
                out += pending.dropLast(keep)
                pending = String(pending.suffix(keep))
                return emit(out)
            }
        }
        return emit(out)
    }

    func finish() -> String {
        defer { pending = "" }
        return muted || inside ? "" : emit(pending)
    }

    private func emit(_ s: String) -> String { visibleChars += s.count; return s }

    private func partialTagLength(_ s: String) -> Int {
        let lower = s.lowercased()
        for n in stride(from: min(Self.close.count - 1, lower.count), to: 0, by: -1) {
            let tail = String(lower.suffix(n))
            if Self.open.hasPrefix(tail) || Self.close.hasPrefix(tail) { return n }
        }
        return 0
    }
}

struct AgentRunner: Sendable {
    let client: LLMClient
    let system: String
    let tools: [AgentTool]
    var maxRounds = 20

    struct Outcome: Sendable {
        var messages: [ChatMessage]
        var text: String
    }

    /// Model and tools in turns until the model answers without calling a tool. Tools of one turn run in parallel.
    func run(messages start: [ChatMessage], onText: @escaping @Sendable (String) -> Void = { _ in }, onTool: @escaping @Sendable (String, String) -> Void = { _, _ in }) async throws -> Outcome {
        if let own = client as? ToolRunningLLMClient {
            let text = try await own.run(system: system, messages: start, tools: tools, onText: onText, onTool: onTool)
            return Outcome(messages: start + [.assistant(text)], text: text)
        }
        var messages = start
        let defs = tools.map(\.def)
        for _ in 0..<maxRounds {
            try Task.checkCancellation()
            let filter = ThinkFilter()
            let collected = TextBox()
            var response = try await client.complete(system: system, messages: messages, tools: defs) { delta in
                let visible = filter.push(delta)
                if !visible.isEmpty { collected.append(visible); onText(visible) }
            }
            let rest = filter.finish()
            if !rest.isEmpty { collected.append(rest); onText(rest) }
            response.text = collected.value
            var assistant = ChatMessage.assistant(response.text)
            assistant.toolCalls = response.toolCalls
            assistant.raw = response.raw
            messages.append(assistant)
            if response.toolCalls.isEmpty { return Outcome(messages: messages, text: response.text) }

            for call in response.toolCalls { onTool(call.name, call.arguments) }
            let results = await withTaskGroup(of: (Int, String, Bool).self) { group in
                for (i, call) in response.toolCalls.enumerated() {
                    group.addTask {
                        guard let tool = tools.first(where: { $0.def.name == call.name }) else { return (i, "Unknown tool \(call.name).", true) }
                        let r = await tool.run(call.arguments)
                        return (i, r.text, r.isError)
                    }
                }
                var all: [(Int, String, Bool)] = []
                for await r in group { all.append(r) }
                return all.sorted { $0.0 < $1.0 }
            }
            try Task.checkCancellation()
            for (i, text, isError) in results {
                messages.append(.toolResult(call: response.toolCalls[i], text: text, isError: isError))
            }
        }
        throw AppError(tr("The agent stopped after %d tool rounds without an answer.", maxRounds))
    }
}

final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) { lock.withLock { text += s } }
    var value: String { lock.withLock { text } }
    private var list: [String] = []
    func add(_ s: String) { lock.withLock { list.append(s) } }
    var items: [String] { lock.withLock { list } }
    func reset() { lock.withLock { list = [] } }
}

/// The mechanics of the agent setup. How the agent behaves and talks belongs in its soul, not here.
enum AgentSetup {
    static let silentReply = "[SILENT]"

    /// Sent unseen at the start of a conversation, so that the agent speaks first and everything gets loaded right away.
    static func greeting(language: String) -> String { "The conversation has just started and you speak first. Greet the user briefly and naturally for the time of day, in \(language), and ask how they are and what you will do together. Do not say the date or time. One or two short sentences, without tools, and do not mention this message." }

    static func dateLine(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return "Current date and time: \(f.string(from: now))."
    }

    static func mainSystem(soul: String, spoken: Bool, listening: Bool, now: Date = Date()) -> String {
        var parts: [String] = []
        if !soul.isEmpty { parts.append(soul) }
        if spoken { parts.append("Your reply is read aloud sentence by sentence, and the user can interrupt you at any time.") }
        if listening { parts.append("User messages are automatic transcripts of speech. If a message is only noise or is clearly not meant for you, reply exactly \(silentReply).") }
        parts.append(dateLine(now))
        return parts.joined(separator: "\n\n")
    }

    /// A subagent started while the user is still talking may only read.
    static func liveSubagentSystem(instructions: String) -> String {
        subagentSystem(instructions: instructions) + "\n\nThe user is still talking, so only read and look things up. Never create, change, delete, upload or send anything, even if the task seems to ask for it; say that it is left for later."
    }

    static func subagentSystem(instructions: String, now: Date = Date()) -> String {
        var parts = ["You are a subagent carrying out one task with the available tools. Report back only the facts the task asks about, where they came from, and what could not be determined. Never invent data. You are not talking to the user; another agent reads your report."]
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { parts.append(extra) }
        parts.append(dateLine(now))
        return parts.joined(separator: "\n\n")
    }

    /// Whether speech-to-text made a word of it. Markers such as [BLANK_AUDIO] or (music) are not words.
    static func hasWords(_ text: String) -> Bool {
        let bare = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#, with: " ", options: .regularExpression)
        return bare.contains { $0.isLetter }
    }

    static let delegateName = "delegate"

    /// What `delegate` answers at once: the report comes later.
    static let delegateStarted = "Started in the background. The report will come to you as a separate message when it is ready. Tell the user briefly that you are on it, and carry on with the conversation."

    /// Reports of background work that came in, sent to the main agent as a message of their own.
    static func backgroundReports(_ reports: [String]) -> String {
        "Reports from subagents you started earlier in the background:\n\n" + reports.joined(separator: "\n\n") + "\n\nTell the user what they need to know from this."
    }

    /// The one tool that is not from MCP: it does nothing itself, it only hands work to the subagent, whose tools are MCP's.
    /// `brief` lists only the names, for a model with little room.
    static func delegateDef(tools: [ToolDef], brief: Bool = false) -> ToolDef {
        let list = tools.map { brief ? "- \($0.name)" : "- \($0.name): \($0.description.prefix(120))" }.joined(separator: "\n")
        return ToolDef(
            name: delegateName,
            description: "Starts a subagent in the background that has the tools below. It returns at once; the subagent's report comes to you later as a separate message, so the conversation can go on meanwhile. Use it for anything that needs outside information or an action. Give it a self-contained task containing only what the user asked for.\n\n\(list)",
            schema: ["type": "object", "properties": ["task": ["type": "string", "description": "The self-contained task."]], "required": ["task"]]
        )
    }

    static let soulLoaderSystem = "Carry out the startup instruction from the user with the available tools. When it is done, reply with the single word OK. Do nothing else."

    /// Runs the soul instruction; what the tools returned is the soul. Nothing loaded is an error: there is no fallback persona.
    static func loadSoul(instruction: String, client: LLMClient, tools: [BoundTool]) async throws -> String {
        if tools.isEmpty { throw AppError("Soul: this profile has no MCP server to load it with.") }
        let loaded = TextBox()
        let names = toolsNamed(in: instruction, among: tools.map(\.remoteName))
        let agentTools = tools.filter { names.contains($0.remoteName) }.map { AgentTool.mcp($0) { loaded.add($0) } }
        _ = try await AgentRunner(client: client, system: soulLoaderSystem, tools: agentTools, maxRounds: 4).run(messages: [.user(instruction)])
        let items = loaded.items
        if items.isEmpty { throw AppError("Soul: the instruction loaded nothing from MCP.") }
        return composeSoul(items)
    }

    /// An instruction that names its tools needs no others, and a server's whole list can be thousands of tokens.
    static func toolsNamed(in instruction: String, among names: [String]) -> [String] {
        let named = names.filter { instruction.contains($0) }
        return named.isEmpty ? names : named
    }

    /// One soul from what the tools returned. A profile server sends its text as `machine_context` beside data
    /// that is not for the model, and loading two roles returns the shared parts twice, so each paragraph is kept once.
    static func composeSoul(_ results: [String]) -> String {
        var seen = Set<String>()
        var paragraphs: [String] = []
        for result in results {
            let root = JSONValue.parse(result)
            let text = root?["data"]?["machine_context"]?.string ?? root?["machine_context"]?.string ?? result
            for paragraph in text.components(separatedBy: "\n\n") {
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, seen.insert(trimmed).inserted { paragraphs.append(trimmed) }
            }
        }
        return paragraphs.joined(separator: "\n\n")
    }
}
