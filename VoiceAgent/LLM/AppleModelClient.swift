import Foundation
import FoundationModels

/// A client whose session keeps the whole exchange to itself, so it calls the tools on its own
/// and only the final answer comes back.
protocol ToolRunningLLMClient: LLMClient {
    func run(system: String, messages: [ChatMessage], tools: [AgentTool], onText: @escaping @Sendable (String) -> Void, onTool: @escaping @Sendable (String, String) -> Void) async throws -> String
}

/// Apple's own models from the Foundation Models framework. Nothing to sign in to and no address.
enum AppleModel {
    /// Runs on the iPhone; nothing leaves it.
    static let onDevice = "on-device"
    /// Private Cloud Compute needs a managed entitlement this app does not have. Without it the framework
    /// ends the whole app instead of throwing, although the model reports itself as available, so it is not offered.
    /// The name stays so that a choice saved earlier gets an explanation.
    static let privateCloud = "private-cloud"

    /// The models this iPhone can use now. When there is none, the reason.
    static func names() throws -> [String] {
        guard #available(iOS 26, *) else { throw needsNewerSystem }
        if let problem = onDeviceProblem() { throw problem }
        return [onDevice]
    }

    static var needsNewerSystem: AppError { AppError(tr("Apple's model needs iOS 26 or later.")) }

    @available(iOS 26, *)
    static func onDeviceProblem() -> AppError? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): AppError(tr("This iPhone cannot run Apple's model."))
        case .unavailable(.appleIntelligenceNotEnabled): AppError(tr("Turn on Apple Intelligence in the iPhone's Settings to use Apple's model."))
        case .unavailable(.modelNotReady): AppError(tr("Apple's model is not ready yet, it may still be downloading. Try again later."))
        case .unavailable: AppError(tr("Apple's model is not available now."))
        }
    }
}

struct AppleModelClient: ToolRunningLLMClient {
    let model: String

    func complete(system: String, messages: [ChatMessage], tools: [ToolDef], onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse {
        LLMResponse(text: try await run(system: system, messages: messages, tools: [], onText: onText, onTool: { _, _ in }))
    }

    func run(system: String, messages: [ChatMessage], tools: [AgentTool], onText: @escaping @Sendable (String) -> Void, onTool: @escaping @Sendable (String, String) -> Void) async throws -> String {
        guard #available(iOS 26, *) else { throw AppleModel.needsNewerSystem }
        guard model != AppleModel.privateCloud else {
            throw AppError(tr("Apple's Private Cloud Compute is not available in this app. Choose the on-device model in Settings."))
        }
        let prompt = messages.last { $0.role == .user }?.text ?? ""
        do {
            let chosen = try await toolsThatFit(tools, system: system, task: prompt)
            let results = ToolResultRoom()
            let bridged = chosen.map { AppleTool($0, onTool: onTool, results: results) }
            try await setRoomForResults(results, messages: messages, system: system, tools: bridged, prompt: prompt)
            let session = try makeSession(tools: bridged, transcript: Self.transcript(system: system, messages: messages, tools: bridged))
            var sent = ""
            for try await snapshot in session.streamResponse(to: prompt) {
                let text = snapshot.content
                if text.hasPrefix(sent), text.count > sent.count { onText(String(text.dropFirst(sent.count))) }
                sent = text
            }
            return sent
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw Self.tooMuch
            case .unsupportedLanguageOrLocale: throw Self.wrongLanguage
            case .guardrailViolation: throw Self.stoppedBySafety
            default: throw error
            }
        } catch {
            if #available(iOS 27, *), let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: throw Self.tooMuch
                case .unsupportedLanguageOrLocale: throw Self.wrongLanguage
                case .guardrailViolation: throw Self.stoppedBySafety
                default: break
                }
            }
            // During tool calls the framework reports this with an internal type of its own.
            if String(describing: type(of: error)) == "GenerativeError", error.localizedDescription.contains("maximum allowed") { throw Self.tooMuch }
            throw error
        }
    }

    @available(iOS 26, *)
    private func makeSession(tools: [AppleTool], transcript: Transcript) throws -> LanguageModelSession {
        if let problem = AppleModel.onDeviceProblem() { throw problem }
        return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, transcript: transcript)
    }

    /// The on-device model has little room. When the tools would take more than half of it, the model first
    /// picks by name what the task needs, and only those are described to it.
    @available(iOS 26, *)
    private func toolsThatFit(_ tools: [AgentTool], system: String, task: String) async throws -> [AgentTool] {
        guard #available(iOS 26.4, *), !tools.isEmpty else { return tools }
        let model = SystemLanguageModel.default
        let room = model.contextSize / 2
        func size(_ some: [AgentTool]) async throws -> Int {
            try await model.tokenCount(for: some.map { AppleTool($0, onTool: { _, _ in }) } as [any FoundationModels.Tool])
        }
        if try await size(tools) <= room { return tools }
        let names = tools.map(\.def.name)
        let menu = tools.map { "\($0.def.name): \($0.def.description.prefix(50))" }.joined(separator: "\n")
        // The schema makes it answer with real names; in free text it often does not.
        let list = DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "Name", anyOf: names), minimumElements: 1, maximumElements: 3)
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Pick", properties: [.init(name: "tools", schema: list)]), dependencies: [])
        let picker = LanguageModelSession(model: model, instructions: "Pick the tools needed for the task.\n\n" + menu)
        let reply = try await picker.respond(to: task, schema: schema, includeSchemaInPrompt: false).content.jsonString
        let picked = JSONValue.parse(reply)?["tools"]?.array?.compactMap(\.string) ?? []
        var chosen = tools.filter { picked.contains($0.def.name) }
        while try await size(chosen) > room, !chosen.isEmpty { chosen.removeLast() }
        if chosen.isEmpty { throw AppError(tr("Apple's model found no tool it could use among %d.", names.count)) }
        return chosen
    }

    /// What the model would otherwise overflow with: results get what the rest leaves, but always something.
    /// A conversation that then does not fit starts anew, see `ContextLimitError`.
    @available(iOS 26, *)
    private func setRoomForResults(_ results: ToolResultRoom, messages: [ChatMessage], system: String, tools: [AppleTool], prompt: String) async throws {
        guard #available(iOS 26.4, *) else { return }
        let model = SystemLanguageModel.default
        let replyRoom = 500
        let leastForResults = 1000
        let used = try await model.tokenCount(for: Instructions(system)) + model.tokenCount(for: tools as [any FoundationModels.Tool]) + model.tokenCount(for: Prompt(prompt))
        var room = model.contextSize - used - replyRoom
        for message in messages.dropLast() { room -= try await model.tokenCount(for: Prompt(message.text)) }
        results.setTokens(max(room, leastForResults))
    }

    private static var stoppedBySafety: AppError {
        AppError(tr("Apple's safety check stopped this reply. It can happen even with harmless text. Try saying it differently or use another model."))
    }

    private static var tooMuch: ContextLimitError {
        ContextLimitError(message: tr("This is too much for Apple's model: the soul and tools do not fit. Load fewer MCP servers in the profile."))
    }

    @available(iOS 26, *)
    private static var wrongLanguage: AppError {
        let names = SystemLanguageModel.default.supportedLanguages
            .compactMap { $0.languageCode?.identifier }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .compactMap { Locale(identifier: Localizer.code).localizedString(forLanguageCode: $0) }
            .sorted()
        return AppError(tr("Apple's model does not work in this language yet. It supports: %@.", names.joined(separator: ", ")))
    }

    /// Everything before the last user message; that one is the prompt.
    @available(iOS 26, *)
    static func transcript(system: String, messages: [ChatMessage], tools: [AppleTool]) -> Transcript {
        func segments(_ text: String) -> [Transcript.Segment] { [.text(Transcript.TextSegment(content: text))] }
        var entries: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: segments(system), toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }))]
        let lastUser = messages.lastIndex { $0.role == .user } ?? messages.endIndex
        for message in messages[..<lastUser] where !message.text.isEmpty {
            switch message.role {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: segments(message.text))))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: segments(message.text))))
            case .tool: break
            }
        }
        return Transcript(entries: entries)
    }
}

/// What tools return can be far larger than the whole model. It gets as much as is left, and once that is gone
/// it is told to answer with what it has.
final class ToolResultRoom: @unchecked Sendable {
    private let lock = NSLock()
    private var chars = Int.max

    /// Results are dense JSON and every tool call takes room of its own: two characters to a token stays on the safe side.
    func setTokens(_ tokens: Int) { lock.withLock { chars = max(0, tokens) * 2 } }

    func take(_ text: String) -> String {
        lock.withLock {
            guard chars > 0 else { return "No more results fit. Answer with what you have." }
            let kept = String(text.prefix(chars))
            chars -= kept.count
            return kept.count < text.count ? kept + "\n[The rest did not fit.]" : kept
        }
    }
}

/// An app tool as the framework wants it: the JSON schema translated, the arguments handed over as JSON.
@available(iOS 26, *)
struct AppleTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    private let tool: AgentTool
    private let onTool: @Sendable (String, String) -> Void
    private let results: ToolResultRoom

    init(_ tool: AgentTool, onTool: @escaping @Sendable (String, String) -> Void, results: ToolResultRoom = ToolResultRoom()) {
        name = tool.def.name
        description = tool.def.description
        parameters = Self.parameters(tool.def.schema, name: tool.def.name)
        self.tool = tool
        self.onTool = onTool
        self.results = results
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let json = arguments.jsonString
        onTool(name, json)
        return results.take(await tool.run(json).text)
    }

    /// A schema that cannot be translated still gives a callable tool, without arguments.
    static func parameters(_ schema: JSONValue, name: String) -> GenerationSchema {
        let root = dynamicSchema(schema, name: name, asObject: true)
        if let translated = try? GenerationSchema(root: root, dependencies: []) { return translated }
        let empty = DynamicGenerationSchema(name: name, properties: [])
        guard let fallback = try? GenerationSchema(root: empty, dependencies: []) else { fatalError("An empty schema is always valid") }
        return fallback
    }

    /// What has no plain counterpart here (`anyOf`, `$ref`, free-form values) becomes a string.
    private static func dynamicSchema(_ json: JSONValue, name: String, asObject: Bool = false) -> DynamicGenerationSchema {
        let type = json["type"]?.string ?? json["type"]?.array?.compactMap(\.string).first { $0 != "null" } ?? (asObject ? "object" : "string")
        if let choices = json["enum"]?.array?.compactMap(\.string), !choices.isEmpty {
            return DynamicGenerationSchema(name: name, anyOf: choices)
        }
        switch type {
        case "object":
            let required = json["required"]?.array?.compactMap(\.string) ?? []
            let properties = (json["properties"]?.object ?? [:]).sorted { $0.key < $1.key }.map { key, value in
                DynamicGenerationSchema.Property(
                    name: key,
                    description: value["description"]?.string,
                    schema: dynamicSchema(value, name: "\(name)_\(key)"),
                    isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, description: json["description"]?.string, properties: properties)
        case "array":
            return DynamicGenerationSchema(arrayOf: dynamicSchema(json["items"] ?? .object([:]), name: "\(name)_item"))
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: return DynamicGenerationSchema(type: String.self)
        }
    }
}
