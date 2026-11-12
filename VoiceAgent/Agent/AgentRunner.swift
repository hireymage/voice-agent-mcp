import Foundation

struct AgentTool: Sendable {
    let def: ToolDef
    /// Its call is the last thing to do: if the model already said something with it, no further round asks the model
    /// again (it would only say the same once more, and what is read aloud cannot be taken back).
    var finishes = false
    /// Not offered to the model, only run when the model calls it anyway (a subagent's tool the main agent knows by
    /// name from the description of `delegate`).
    var hidden = false
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

/// Takes tool calls a model wrote into its text out of the stream: `<tool_call>…</tool_call>` blocks, in the XML form of
/// Qwen (`<function=name><parameter=key>value</parameter></function>`) or as JSON (`{"name": …, "arguments": {…}}`).
/// Some servers pass such a block on as text when they cannot read it as a call, for example when it names a tool
/// the request did not declare; it must not be shown or read aloud.
final class ToolCallTextFilter: @unchecked Sendable {
    private static let open = "<tool_call>", close = "</tool_call>"
    private var pending = ""
    private var inside = false
    private var block = ""
    private(set) var blocks: [String] = []

    func push(_ delta: String) -> String {
        pending += delta
        var out = ""
        while !pending.isEmpty {
            if inside {
                guard let r = pending.range(of: Self.close, options: .caseInsensitive) else {
                    let keep = Self.partialLength(pending, of: Self.close)
                    block += pending.dropLast(keep)
                    pending = String(pending.suffix(keep))
                    return out
                }
                block += pending[..<r.lowerBound]
                blocks.append(block)
                block = ""
                pending = String(pending[r.upperBound...])
                inside = false
                continue
            }
            guard let o = pending.range(of: Self.open, options: .caseInsensitive) else {
                let keep = Self.partialLength(pending, of: Self.open)
                out += pending.dropLast(keep)
                pending = String(pending.suffix(keep))
                return out
            }
            out += pending[..<o.lowerBound]
            pending = String(pending[o.upperBound...])
            inside = true
        }
        return out
    }

    /// What is left at the end; a block the model never closed still counts as a call.
    func finish() -> String {
        defer { pending = ""; block = ""; inside = false }
        if inside {
            blocks.append(block + pending)
            return ""
        }
        return pending
    }

    /// The calls in the blocks, in order; a block that reads as neither form is dropped.
    var calls: [ToolCall] {
        blocks.enumerated().compactMap { i, b in Self.parse(b).map { ToolCall(id: "text_call_\(i + 1)", name: $0.name, arguments: $0.arguments) } }
    }

    static func parse(_ block: String) -> (name: String, arguments: String)? {
        let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = JSONValue.parse(text), let name = json["name"]?.string, !name.isEmpty {
            let args = json["arguments"] ?? json["parameters"] ?? .object([:])
            if let s = args.string { return (name, s) }
            return (name, args.compact)
        }
        guard let f = text.range(of: #"<function=([^>\s]+)>"#, options: .regularExpression) else { return nil }
        let name = String(text[f].dropFirst("<function=".count).dropLast())
        var args: [String: JSONValue] = [:]
        let pattern = try! NSRegularExpression(pattern: #"<parameter=([^>\s]+)>(.*?)</parameter>"#, options: [.dotMatchesLineSeparators])
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let k = Range(m.range(at: 1), in: text), let v = Range(m.range(at: 2), in: text) else { continue }
            let value = text[v].trimmingCharacters(in: .whitespacesAndNewlines)
            // Numbers, true/false, lists and objects come as their JSON; anything else is text.
            if let parsed = JSONValue.parse(value), parsed.string == nil { args[String(text[k])] = parsed } else { args[String(text[k])] = .string(value) }
        }
        return (name, JSONValue.object(args).compact)
    }

    private static func partialLength(_ s: String, of tag: String) -> Int {
        let lower = s.lowercased()
        for n in stride(from: min(tag.count - 1, lower.count), to: 0, by: -1) where tag.hasPrefix(String(lower.suffix(n))) { return n }
        return 0
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
    /// The tools go to the model with only a sentence each and no parameters; it reads a tool's whole description
    /// and parameters with `load_tools`, as a tool result: dozens of full descriptions made every request long.
    /// The list of tools stays the same all the way: a list that changed made servers that keep the prompt
    /// (llama.cpp and the like) read the whole conversation again, since the tools come right after the system text.
    var lazy = false

    static let loadToolsName = "load_tools"

    /// The first sentence of a description, at most about a hundred characters.
    static func brief(_ description: String) -> String {
        let flat = description.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        var sentence = flat
        if let end = flat.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { sentence = String(flat[..<end.upperBound]).trimmingCharacters(in: .whitespaces) }
        return sentence.count > 100 ? String(sentence.prefix(99)) + "…" : sentence
    }

    static let loadToolsDef = ToolDef(
        name: loadToolsName,
        description: "Gives you the full description and the parameters of the tools you name. The other tools are listed with one sentence and no parameters: read a tool here before you call it for the first time, and only the tools the task needs.",
        schema: ["type": "object", "properties": ["names": ["type": "array", "items": ["type": "string"], "description": "Names of the tools."]], "required": ["names"]]
    )

    /// A tool as the model sees it before reading it: its name, one sentence, any arguments.
    static func briefDef(_ def: ToolDef) -> ToolDef {
        ToolDef(name: def.name, description: brief(def.description), schema: ["type": "object"])
    }

    /// What `load_tools` answers for one tool.
    static func details(_ def: ToolDef) -> String {
        "## \(def.name)\n\(def.description)\nParameters (JSON Schema): \(def.schema.compact)"
    }

    /// The names a `load_tools` call asks for: a list, or one text with commas.
    static func requestedNames(_ arguments: String) -> [String] {
        let value = JSONValue.parse(arguments.isEmpty ? "{}" : arguments)?["names"]
        let raw: [String] = value?.array?.compactMap(\.string) ?? value?.string.map { $0.split(separator: ",").map(String.init) } ?? []
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

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
        let loadable = lazy ? tools.filter { !$0.hidden } : []
        let defs: [ToolDef] = lazy
            ? [Self.loadToolsDef] + loadable.map { Self.briefDef($0.def) }
            : tools.filter { !$0.hidden }.map(\.def)
        // Text of earlier rounds was already shown and read aloud; a later round's text follows it as a new paragraph.
        let said = TextBox()
        for _ in 0..<maxRounds {
            try Task.checkCancellation()
            let filter = ThinkFilter()
            let calls = ToolCallTextFilter()
            let collected = TextBox()
            let show: @Sendable (String) -> Void = { visible in
                let gap = collected.value.isEmpty && !said.value.isEmpty ? "\n\n" : ""
                collected.append(visible)
                said.append(gap + visible)
                onText(gap + visible)
            }
            var response = try await client.complete(system: system, messages: messages, tools: defs) { delta in
                let visible = calls.push(filter.push(delta))
                if !visible.isEmpty { show(visible) }
            }
            let rest = calls.push(filter.finish()) + calls.finish()
            if !rest.isEmpty { show(rest) }
            response.text = collected.value
            var assistant = ChatMessage.assistant(response.text)
            if response.toolCalls.isEmpty, !calls.calls.isEmpty {
                response.toolCalls = calls.calls
                // A provider's own form of the turn knows nothing of these calls; only reasoning text goes along.
                if response.raw?.api != .openAIChat { response.raw = nil }
            }
            assistant.toolCalls = response.toolCalls
            assistant.raw = response.raw
            messages.append(assistant)
            if response.toolCalls.isEmpty { return Outcome(messages: messages, text: response.text) }

            for call in response.toolCalls { onTool(call.name, call.arguments) }
            let results = await withTaskGroup(of: (Int, String, Bool).self) { group in
                for (i, call) in response.toolCalls.enumerated() {
                    if lazy, call.name == Self.loadToolsName {
                        let names = Self.requestedNames(call.arguments)
                        let found = loadable.filter { names.contains($0.def.name) }
                        let missing = names.filter { n in !found.contains { $0.def.name == n } }
                        var text = found.map { Self.details($0.def) }.joined(separator: "\n\n")
                        if found.isEmpty { text = "No tool was found." }
                        if !missing.isEmpty { text += "\n\nNot among your tools: \(missing.joined(separator: ", "))." }
                        group.addTask { (i, text, found.isEmpty) }
                        continue
                    }
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
            let finished = response.toolCalls.allSatisfy { call in tools.first { $0.def.name == call.name }?.finishes == true }
            if finished, !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Outcome(messages: messages, text: response.text)
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

    /// The time goes with each user message, not in the system text: a system text that changed every minute made
    /// servers that keep a conversation's prompt (llama.cpp and the like) read the whole conversation again, for example
    /// when the main agent came back after its subagent's request. Worded as a reading of the device clock: some
    /// models (Qwen3 Coder) answered that they have no access to the time when it only said "Current date and time".
    static let clockRule = "Each user message begins with a reading of the user's device clock in square brackets, taken when the message was sent. It is the real current local time; use the latest reading whenever the date or time matters. The app adds it, not the user, so do not mention it otherwise."

    static func clockReading(_ now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm 'on' EEEE d MMMM yyyy"
        return "[Device clock: \(f.string(from: now)), time zone \(timeZone.identifier)]"
    }

    /// A user message as it goes into the history: with the time it was sent, so it never changes afterwards.
    static func stamped(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        clockReading(now, timeZone: timeZone) + "\n" + text
    }

    /// The message without the clock readings, for when its words go into a later message.
    static func unstamped(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[Device clock: [^\]\n]*\]\n"#, with: "", options: .regularExpression)
    }

    static func mainSystem(soul: String, spoken: Bool, listening: Bool) -> String {
        var parts: [String] = []
        if !soul.isEmpty { parts.append(soul) }
        if spoken { parts.append("Your reply is read aloud sentence by sentence, and the user can interrupt you at any time.") }
        if listening { parts.append("User messages are automatic transcripts of speech. If a message is only noise or is clearly not meant for you, reply exactly \(silentReply).") }
        parts.append(clockRule)
        return parts.joined(separator: "\n\n")
    }

    /// A subagent started while the user is still talking may only read.
    static func liveSubagentSystem(instructions: String) -> String {
        subagentSystem(instructions: instructions) + "\n\nThe user is still talking, so only read and look things up. Never create, change, delete, upload or send anything, even if the task seems to ask for it; say that it is left for later."
    }

    static func subagentSystem(instructions: String) -> String {
        var parts = ["You are a subagent carrying out one task with the available tools. Report back only the facts the task asks about, where they came from, and what could not be determined. Never invent data. You are not talking to the user; another agent reads your report."]
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { parts.append(extra) }
        parts.append(clockRule)
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

    /// What `delegate` answers when subagents are already at work: so the model does not start the same task again.
    static func delegateStarted(alsoRunning: [String]) -> String {
        guard !alsoRunning.isEmpty else { return delegateStarted }
        return delegateStarted + " Also still running, do not start these again: " + alsoRunning.map { "\"\($0)\"" }.joined(separator: "; ") + "."
    }

    static let delegateAlreadyRunning = "This task is already running in the background; its report will come to you. Do not start it again. Tell the user briefly that you are on it, and carry on with the conversation."

    /// Reports of background work that came in, sent to the main agent as a message of their own.
    static func backgroundReports(_ reports: [String]) -> String {
        "Reports from subagents you started earlier in the background:\n\n" + reports.joined(separator: "\n\n") + "\n\nTell the user only what they still want from this and you have not told them yet. If nothing is left, because you already said it or the user no longer wants it, reply exactly \(silentReply)."
    }

    /// The one tool that is not from MCP: it does nothing itself, it only hands work to the subagent, whose tools are MCP's.
    /// `brief` lists only the names, for a model with little room.
    static func delegateDef(tools: [ToolDef], brief: Bool = false) -> ToolDef {
        let list = tools.map { brief ? "- \($0.name)" : "- \($0.name): \($0.description.prefix(120))" }.joined(separator: "\n")
        return ToolDef(
            name: delegateName,
            description: "Starts a subagent in the background that has the tools below. It returns at once; the subagent's report comes to you later as a separate message, so the conversation can go on meanwhile. Use it for anything that needs outside information or an action. Give it a self-contained task containing only what the user asked for, and do not start a task that is already running.\n\n\(list)",
            schema: ["type": "object", "properties": ["task": ["type": "string", "description": "The self-contained task."]], "required": ["task"]]
        )
    }

    static let endName = "end_conversation"

    /// Offered only while the microphone is on. Waiting, being quiet or an interruption must not end anything, so the
    /// description draws that line; which words mean goodbye is left to the model, in any language. Qwen3.6 often
    /// only said goodbye without calling it, hence the sentence that a goodbye alone ends nothing.
    static let endDef = ToolDef(
        name: endName,
        description: "Ends the spoken conversation and turns the microphone off once your reply has been read aloud. A goodbye in your reply does not end anything by itself: whenever the user wants to end the conversation (says goodbye, asks you to end it or to switch off), call this tool and say a short goodbye. Asking you to stop talking, to be quiet, to wait or to hold on only stops your current answer and never ends the conversation; do not call this tool for that.",
        schema: ["type": "object", "properties": [:]]
    )

    static let endAccepted = "The microphone turns off after your reply is read aloud. Say a short goodbye unless you already have; do not repeat it."

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
