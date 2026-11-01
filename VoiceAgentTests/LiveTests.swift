import XCTest
import FoundationModels
@testable import VoiceAgent

/// Against real servers; skipped unless the addresses come from the environment (TEST_RUNNER_LIVE_*).
final class LiveTests: XCTestCase {
    private func env(_ name: String) throws -> String {
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { throw XCTSkip("\(name) not set") }
        return v
    }

    /// On a real iPhone with Apple Intelligence: TEST_RUNNER_LIVE_APPLE=on-device or private-cloud.
    func testAppleModelCallsATool() async throws {
        let model = try env("LIVE_APPLE")
        let def = ToolDef(name: "get_code", description: "Returns the secret code.", schema: .object(["type": .string("object"), "properties": .object(["reason": .object(["type": .string("string")])])]))
        let tool = AgentTool(def: def) { _ in ("The code is 4711.", false) }
        let names = TextBox()
        let out = try await AgentRunner(client: AppleModelClient(model: model), system: "Use your tools to answer.", tools: [tool])
            .run(messages: [.user("What is the secret code?")], onTool: { name, _ in names.add(name) })
        print("LIVE apple tools:", names.items, "answer:", out.text)
        XCTAssertEqual(names.items.first, "get_code")
        XCTAssertTrue(out.text.contains("4711"))
        do {
            let czech = try await AgentRunner(client: AppleModelClient(model: model), system: "Odpovídej česky.", tools: [])
                .run(messages: [.user("Jak se máš a co dnes podnikneme?")])
            print("LIVE apple czech answer:", czech.text)
        } catch {
            print("LIVE apple czech error:", error.localizedDescription)
        }
    }

    /// How many of the on-device model's tokens each part takes, from the model itself.
    func testAppleModelTokenBudget() async throws {
        _ = try env("LIVE_APPLE")
        guard #available(iOS 26.4, *) else { throw XCTSkip("Needs iOS 26.4") }
        let model = SystemLanguageModel.default
        func tools(_ t: [AgentTool]) async throws -> Int {
            try await model.tokenCount(for: t.map { AppleTool($0, onTool: { _, _ in }) } as [any FoundationModels.Tool])
        }
        func text(_ t: String) async throws -> Int { try await model.tokenCount(for: Prompt(t)) }
        print("LIVE budget context:", model.contextSize)
        let server = MCPServer(name: "umm", url: try env("LIVE_MCP_URL"))
        let result = await MCPTools.connect([server]) { _ in ["Authorization": "Bearer " + ((try? self.env("LIVE_MCP_TOKEN")) ?? "")] }
        let umm = result.tools.map { AgentTool.mcp($0) }
        print("LIVE budget umm tools:", umm.count, "tokens:", try await tools(umm))
        let loader = umm.filter { $0.def.name.contains("agent_bootstrap") }
        print("LIVE budget loader tool only:", try await tools(loader))
        let phone = PhoneTools.agentTools(enabled: PhoneTools.all.map(\.name))
        print("LIVE budget phone tools:", phone.count, "tokens:", try await tools(phone))
        let delegateUmm = AgentTool(def: AgentSetup.delegateDef(tools: umm.map(\.def))) { _ in ("", false) }
        print("LIVE budget delegate over umm:", try await tools([delegateUmm]))
        let delegatePhone = AgentTool(def: AgentSetup.delegateDef(tools: phone.map(\.def))) { _ in ("", false) }
        print("LIVE budget delegate over phone:", try await tools([delegatePhone]))
        let soul = try await AgentSetup.loadSoul(instruction: try env("LIVE_SOUL_INSTRUCTION"), client: DirectBootstrap(), tools: result.tools)
        print("LIVE budget soul chars:", soul.count, "tokens:", try await text(soul))
        print("LIVE budget subagent system:", try await text(AgentSetup.subagentSystem(instructions: "")))
        let client = AppleModelClient(model: AppleModel.onDevice)
        do {
            _ = try await client.complete(system: soul + soul + soul, messages: [.user("Hello")], tools: []) { _ in }
            print("LIVE budget oversize: no error")
        } catch {
            print("LIVE budget oversize error:", type(of: error), error.localizedDescription)
        }
        let small = try await AgentRunner(client: client, system: AgentSetup.subagentSystem(instructions: ""), tools: phone.filter { $0.def.name == "list_reminders" }.isEmpty ? [] : phone)
            .run(messages: [.user("Say hello in one short sentence. Do not use any tools.")])
        print("LIVE budget phone tools run:", small.text)
    }

    /// The whole way on a real iPhone: the soul through MCP, then a question that needs the subagent and a memory tool.
    /// Read-only tools only, so that a small model cannot write to the shared memory.
    func testAppleModelThroughRealMCP() async throws {
        _ = try env("LIVE_APPLE")
        let server = MCPServer(name: "umm", url: try env("LIVE_MCP_URL"))
        let result = await MCPTools.connect([server]) { _ in ["Authorization": "Bearer " + ((try? self.env("LIVE_MCP_TOKEN")) ?? "")] }
        let client = AppleModelClient(model: AppleModel.onDevice)
        let soul = try await AgentSetup.loadSoul(instruction: try env("LIVE_SOUL_INSTRUCTION"), client: client, tools: result.tools)
        print("LIVE mcp soul chars:", soul.count)
        // The server does not mark its tools, so by name; none of these can write.
        let reads = ["get_", "find_", "list_", "search_", "query_", "retrieve_"]
        let reading = result.tools.filter { t in reads.contains { t.remoteName.hasPrefix($0) } }.map { AgentTool.mcp($0) }
        print("LIVE mcp read-only tools:", reading.count)
        let names = TextBox()
        do {
            let direct = try await AgentRunner(client: client, system: AgentSetup.subagentSystem(instructions: ""), tools: reading)
                .run(messages: [.user("List the people stored in memory.")], onTool: { name, _ in names.add(name) })
            print("LIVE mcp direct tools:", names.items, "answer chars:", direct.text.count, "starts:", direct.text.prefix(120))
        } catch {
            print("LIVE mcp direct error:", type(of: error), String(describing: error).prefix(300))
        }
        names.reset()
        let delegate = AgentTool(def: AgentSetup.delegateDef(tools: reading.map(\.def), brief: true)) { arguments in
            let task = JSONValue.parse(arguments)?["task"]?.string ?? arguments
            do {
                let o = try await AgentRunner(client: client, system: AgentSetup.subagentSystem(instructions: ""), tools: reading)
                    .run(messages: [.user(task)], onTool: { name, _ in names.add(name) })
                return (o.text, false)
            } catch {
                print("LIVE mcp subagent error:", type(of: error), error.localizedDescription)
                return (error.localizedDescription, true)
            }
        }
        let main = AgentSetup.mainSystem(soul: soul, spoken: true, listening: false)
        let out = try await AgentRunner(client: client, system: main, tools: [delegate])
            .run(messages: [.user("Using your tools, find out which agent profiles exist in memory and tell me their names.")], onTool: { name, _ in names.add(name) })
        print("LIVE mcp tools used:", names.items)
        print("LIVE mcp answer:", out.text.prefix(400))
        var history = [ChatMessage.user("Hello"), .assistant("Hello, how can I help?")]
        for i in 0..<12 { history += [.user("Question \(i) about a long and rather detailed topic that goes on for a while."), .assistant("Answer \(i) that is also fairly long and goes into some detail about the topic.")] }
        history.append(.user("Say OK."))
        do {
            let long = try await AgentRunner(client: client, system: main, tools: [delegate]).run(messages: history)
            print("LIVE mcp long conversation:", long.text.prefix(120))
        } catch {
            print("LIVE mcp long conversation is a context limit:", isContextLimit(error))
        }
    }

    /// Which part makes Apple's safety check refuse: the loading of the soul, the soul itself, or anything at all.
    func testAppleModelGuardrails() async throws {
        _ = try env("LIVE_APPLE")
        guard #available(iOS 26, *) else { throw XCTSkip("Needs iOS 26") }
        let server = MCPServer(name: "umm", url: try env("LIVE_MCP_URL"))
        let result = await MCPTools.connect([server]) { _ in ["Authorization": "Bearer " + ((try? self.env("LIVE_MCP_TOKEN")) ?? "")] }
        let instruction = try env("LIVE_SOUL_INSTRUCTION")
        do {
            let loaded = try await AgentSetup.loadSoul(instruction: instruction, client: AppleModelClient(model: AppleModel.onDevice), tools: result.tools)
            print("LIVE guard load through model: ok, chars", loaded.count)
        } catch {
            print("LIVE guard load through model:", type(of: error), error.localizedDescription.prefix(160))
        }
        let soul = try await AgentSetup.loadSoul(instruction: instruction, client: DirectBootstrap(), tools: result.tools)
        func attempt(_ label: String, _ model: SystemLanguageModel, _ system: String, _ prompt: String) async {
            do {
                let r = try await LanguageModelSession(model: model, instructions: system).respond(to: prompt).content
                print("LIVE guard \(label): ok:", r.prefix(70))
            } catch {
                print("LIVE guard \(label):", type(of: error), error.localizedDescription.prefix(120))
            }
        }
        let normal = SystemLanguageModel.default
        let permissive = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let english = AgentSetup.greeting(language: "English")
        let czech = AgentSetup.greeting(language: "Czech")
        await attempt("neutral soul, english greeting", normal, "You are a helpful assistant.", english)
        await attempt("neutral soul, czech greeting", normal, "You are a helpful assistant.", czech)
        await attempt("neutral soul, czech question", normal, "You are a helpful assistant.", "Jak se dnes máš?")
        await attempt("real soul, english greeting", normal, AgentSetup.mainSystem(soul: soul, spoken: true, listening: false), english)
        await attempt("real soul, czech greeting", normal, AgentSetup.mainSystem(soul: soul, spoken: true, listening: false), czech)
        await attempt("real soul, english question", normal, AgentSetup.mainSystem(soul: soul, spoken: true, listening: false), "How are you today?")
        await attempt("permissive, real soul, czech greeting", permissive, AgentSetup.mainSystem(soul: soul, spoken: true, listening: false), czech)
        let parts = soul.components(separatedBy: "\n\n")
        print("LIVE guard soul paragraphs:", parts.count)
        for (i, part) in parts.enumerated() {
            await attempt("paragraph \(i) (\(part.count) chars)", normal, part, "How are you today?")
        }
    }

    private struct DirectBootstrap: LLMClient {
        func complete(system: String, messages: [ChatMessage], tools: [ToolDef], onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse {
            if messages.contains(where: { $0.role == .tool }) { return LLMResponse(text: "OK") }
            let name = tools.first { $0.name.contains("agent_bootstrap") }?.name ?? ""
            let agent = ProcessInfo.processInfo.environment["LIVE_AGENT_ID"] ?? "assistant"
            return LLMResponse(toolCalls: [
                ToolCall(id: "1", name: name, arguments: #"{"agent_id":"\#(agent)","session_role":"voice"}"#),
                ToolCall(id: "2", name: name, arguments: #"{"agent_id":"\#(agent)"}"#),
            ])
        }
    }

    private func llm() throws -> LLMClient {
        makeLLMClient(LLMConfig(api: .openAIChat, baseURL: try env("LIVE_LLM_URL"), apiKey: "", model: try env("LIVE_LLM_MODEL"), extra: nil))
    }

    private func memory() throws -> MCPServer {
        MCPServer(name: "memory", url: try env("LIVE_MCP_URL"))
    }

    func testModelList() async throws {
        let models = try await listModels(api: .openAIChat, baseURL: try env("LIVE_LLM_URL"), apiKey: "")
        XCTAssertTrue(models.contains(try env("LIVE_LLM_MODEL")), "\(models)")
    }

    func testStreamedAnswer() async throws {
        let client = try llm()
        let out = try await AgentRunner(client: client, system: "Reply with one short sentence.", tools: []).run(messages: [.user("Say hello.")])
        XCTAssertFalse(out.text.isEmpty)
        XCTAssertFalse(out.text.contains("think>"))
    }

    func testSoulLoadsThroughMCPAndSubagentUsesTools() async throws {
        let token = try env("LIVE_MCP_TOKEN")
        let result = await MCPTools.connect([try memory()]) { _ in ["Authorization": "Bearer \(token)"] }
        XCTAssertEqual(result.failures, [])
        XCTAssertGreaterThan(result.tools.count, 5)

        let client = try llm()
        let soul = try await AgentSetup.loadSoul(instruction: try env("LIVE_SOUL_INSTRUCTION"), client: client, tools: result.tools)
        XCTAssertFalse(soul.isEmpty)

        let subTools = result.tools.map { AgentTool.mcp($0) }
        let delegate = AgentTool(def: AgentSetup.delegateDef(tools: subTools.map(\.def))) { arguments in
            let task = JSONValue.parse(arguments)?["task"]?.string ?? arguments
            let o = try? await AgentRunner(client: client, system: AgentSetup.subagentSystem(instructions: ""), tools: subTools).run(messages: [.user(task)])
            return (o?.text ?? "failed", o == nil)
        }
        let names = TextBox()
        let main = AgentSetup.mainSystem(soul: soul, spoken: true, listening: false)
        let out = try await AgentRunner(client: client, system: main, tools: [delegate], maxRounds: 4).run(
            messages: [.user("Through the delegate tool, find out which agent profiles exist in memory and tell me how many there are.")],
            onTool: { name, _ in names.add(name) })
        XCTAssertEqual(names.items.first, AgentSetup.delegateName)
        XCTAssertFalse(out.text.isEmpty)
        print("LIVE answer:", out.text)
    }

    func testPiperThenWhisperRoundTrip() async throws {
        var tts = TTSSettings()
        tts.kind = .piper
        tts.url = try env("LIVE_PIPER_URL")
        tts.voice = try env("LIVE_PIPER_VOICE")
        let clip = try await makeTTS(tts).synthesize("Dobrý den, tohle je zkouška hlasu.")
        XCTAssertGreaterThan(clip.buffer.frameLength, 24000)

        // Down to 16 kHz samples, the form the microphone path produces.
        let src = clip.buffer.floatChannelData![0]
        let pcm = stride(from: 0, to: Int(clip.buffer.frameLength), by: 3).map { Int16(max(-1, min(1, src[$0])) * 32767) }
        var stt = STTSettings()
        stt.kind = .whisperCpp
        stt.url = try env("LIVE_WHISPER_URL")
        stt.language = "cs"
        let text = try await makeSTT(stt).transcribe(wav: wavData(pcm, sampleRate: 16000))
        print("LIVE transcript:", text)
        XCTAssertTrue(text.lowercased().contains("zkouška") || text.lowercased().contains("den"), text)
    }

    func testPiperSentenceEndsInSilence() async throws {
        var tts = TTSSettings()
        tts.kind = .piper
        tts.url = try env("LIVE_PIPER_URL")
        tts.voice = try env("LIVE_PIPER_VOICE")
        let clip = try await makeTTS(tts).synthesize("Dobrý den, tohle je zkouška hlasu.")
        let n = Int(clip.buffer.frameLength)
        let end = UnsafeBufferPointer(start: clip.buffer.floatChannelData![0] + n - 4800, count: 4800)
        XCTAssertLessThan(end.map(abs).max() ?? 1, 0.01, "the last 100 ms must not click")
    }

    func testTwoRolesLoadWithoutRepeats() async throws {
        let token = try env("LIVE_MCP_TOKEN")
        let result = await MCPTools.connect([try memory()]) { _ in ["Authorization": "Bearer \(token)"] }
        let soul = try await AgentSetup.loadSoul(
            instruction: try env("LIVE_TWO_ROLE_INSTRUCTION"),
            client: try llm(), tools: result.tools)
        print("LIVE soul chars:", soul.count)
        XCTAssertEqual(soul.components(separatedBy: "AGENT IDENTITY").count - 1, 1, String(soul.prefix(300)))
        XCTAssertEqual(soul.components(separatedBy: "\nSOUL\n").count + soul.components(separatedBy: "SOUL\n").count, 4, "Soul once")
        XCTAssertEqual(soul.components(separatedBy: "ACTIVE ROLE").count - 1, 2)
    }

    func testSearchServerThroughMCP() async throws {
        let address = try env("LIVE_SEARCH_MCP_URL")
        let token = try env("LIVE_SEARCH_MCP_TOKEN")
        let client = MCPClient(url: try XCTUnwrap(URL(string: address)), headers: ["Authorization": "Bearer \(token)"])
        let tools = try await client.listTools()
        XCTAssertTrue(tools.contains { $0.name == "searxng_web_search" }, "\(tools.map(\.name))")
        let info = try await client.call(tool: "searxng_instance_info", arguments: [:])
        XCTAssertFalse(info.isError, info.text)
    }
}
