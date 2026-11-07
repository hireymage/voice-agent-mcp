import XCTest
import EventKit
@testable import VoiceAgent

/// Serves canned responses, so the protocols can be tested without any server.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&chunk, maxLength: chunk.count)
                if n <= 0 { break }
                body.append(chunk, count: n)
            }
            stream.close()
        }
        Self.bodies.append(body)
        var r = request
        r.httpBody = body
        // Answered on its own thread, like real servers: a slow model must not hold up speech-to-text.
        let handler = Self.handler!
        DispatchQueue.global().async { [self] in
            let (status, headers, data) = handler(r)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }
}

private func sse(_ events: [String]) -> Data { Data(events.map { "data: \($0)\n\n" }.joined().utf8) }

private func stream(_ events: [String]) -> AsyncThrowingStream<(event: String?, json: JSONValue), Error> {
    AsyncThrowingStream { c in
        for e in events { c.yield((nil, JSONValue.parse(e)!)) }
        c.finish()
    }
}

private let config = { (api: LLMAPI) in LLMConfig(api: api, baseURL: "https://x/v1/", apiKey: "k", model: "m", extra: nil) }

final class LLMClientTests: XCTestCase {
    func testOpenAIChatAssemblesToolCallsFromFragments() async throws {
        let c = OpenAIChatClient(config(.openAIChat))
        let r = try await c.consume(stream([
            #"{"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"{"choices":[{"delta":{"content":"lo"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"t","arguments":"{\"x\""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":1}"}}]}}]}"#,
        ]), onText: { _ in })
        XCTAssertEqual(r.text, "Hello")
        XCTAssertEqual(r.toolCalls, [ToolCall(id: "a", name: "t", arguments: #"{"x":1}"#)])
    }

    func testOpenAIChatBodyHasSystemToolsAndExtraParams() {
        let c = OpenAIChatClient(LLMConfig(api: .openAIChat, baseURL: "u", apiKey: "", model: "m", extra: ["temperature": 0]))
        let call = ToolCall(id: "a", name: "t", arguments: "{}")
        var assistant = ChatMessage.assistant("")
        assistant.toolCalls = [call]
        let b = c.body(system: "S", messages: [.user("hi"), assistant, .toolResult(call: call, text: "R", isError: false)], tools: [ToolDef(name: "t", description: "d", schema: [:])])
        let m = b["messages"]!.array!
        XCTAssertEqual(m[0]["role"]?.string, "system")
        XCTAssertEqual(m[2]["tool_calls"]?.array?.first?["id"]?.string, "a")
        XCTAssertEqual(m[3]["tool_call_id"]?.string, "a")
        XCTAssertEqual(b["tools"]?.array?.first?["function"]?["name"]?.string, "t")
        XCTAssertEqual(b["temperature"]?.int, 0)
    }

    func testResponsesParsesTextAndFunctionCalls() async throws {
        let c = OpenAIResponsesClient(config(.openAIResponses))
        let r = try await c.consume(stream([
            #"{"type":"response.output_text.delta","delta":"Hi"}"#,
            #"{"type":"response.completed","response":{"output":[{"type":"reasoning","id":"r"},{"type":"function_call","call_id":"c","name":"t","arguments":"{}"}]}}"#,
        ]), onText: { _ in })
        XCTAssertEqual(r.text, "Hi")
        XCTAssertEqual(r.toolCalls.first?.id, "c")
        // The reasoning item must be replayed with the call it led to.
        var assistant = ChatMessage.assistant(r.text)
        assistant.raw = r.raw
        let body = c.body(system: "", messages: [assistant], tools: [])
        XCTAssertEqual(body["input"]?.array?.first?["type"]?.string, "reasoning")
    }

    func testAnthropicKeepsThinkingSignatureAndMergesToolResults() async throws {
        let c = AnthropicClient(config(.anthropic))
        let r = try await c.consume(stream([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"SIG"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"u","name":"t","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"a\":1}"}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"v","name":"t","input":{}}}"#,
        ]), onText: { _ in })
        XCTAssertEqual(r.toolCalls.map(\.id), ["u", "v"])
        XCTAssertEqual(r.toolCalls[1].arguments, "{}")
        var assistant = ChatMessage.assistant("")
        assistant.toolCalls = r.toolCalls
        assistant.raw = r.raw
        let b = c.body(system: "S", messages: [.user("q"), assistant, .toolResult(call: r.toolCalls[0], text: "1", isError: false), .toolResult(call: r.toolCalls[1], text: "2", isError: true)], tools: [])
        let m = b["messages"]!.array!
        XCTAssertEqual(m.count, 3, "two tool results belong in one user message")
        XCTAssertEqual(m[1]["content"]?.array?.first?["signature"]?.string, "SIG")
        XCTAssertEqual(m[2]["content"]?.array?.count, 2)
        XCTAssertEqual(m[2]["content"]?.array?[1]["is_error"]?.bool, true)
        XCTAssertEqual(b["system"]?.string, "S")
    }

    func testGeminiHidesThoughtsAndReplaysSignature() async throws {
        let c = GeminiClient(config(.gemini))
        let r = try await c.consume(stream([
            #"{"candidates":[{"content":{"parts":[{"text":"secret","thought":true},{"text":"Hi"}]}}]}"#,
            #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"t","args":{"a":1}},"thoughtSignature":"SIG"}]}}]}"#,
        ]), onText: { _ in })
        XCTAssertEqual(r.text, "Hi")
        XCTAssertEqual(r.toolCalls.first?.arguments, #"{"a":1}"#)
        var assistant = ChatMessage.assistant(r.text)
        assistant.toolCalls = r.toolCalls
        assistant.raw = r.raw
        let b = c.body(system: "", messages: [assistant, .toolResult(call: r.toolCalls[0], text: "ok", isError: false)], tools: [])
        let contents = b["contents"]!.array!
        XCTAssertEqual(contents[0]["parts"]?.array?.last?["thoughtSignature"]?.string, "SIG")
        XCTAssertEqual(contents[1]["parts"]?.array?.first?["functionResponse"]?["name"]?.string, "t")
    }

    func testHTTPErrorShowsTheServersMessage() {
        let e = HTTPFailure(status: 401, body: #"{"error":{"message":"bad key"}}"#)
        XCTAssertEqual(e.errorDescription, "HTTP 401: bad key")
    }

    func testBadExtraParamsAreAnError() {
        XCTAssertThrowsError(try parseExtraParams("{oops"))
        XCTAssertNil(try parseExtraParams("  "))
    }
}

final class MCPClientTests: XCTestCase {
    func testHandshakeSessionPagingAndCalls() async throws {
        StubProtocol.bodies = []
        var sessions: [String?] = []
        StubProtocol.handler = { r in
            let m = JSONValue.parse(r.httpBody!)!
            let id = m["id"]?.int ?? 0
            sessions.append(r.value(forHTTPHeaderField: "Mcp-Session-Id"))
            switch m["method"]?.string {
            case "initialize":
                return (200, ["Content-Type": "application/json", "Mcp-Session-Id": "S1"], Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-03-26"}}"#.utf8))
            case "notifications/initialized":
                return (202, [:], Data())
            case "tools/list":
                let page2 = m["params"]?["cursor"]?.string == "next"
                let json = page2
                    ? #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"b"}]}}"#
                    : #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"a","description":"A","inputSchema":{"type":"object"}}],"nextCursor":"next"}}"#
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            default:
                // Answer as an event stream, with a notification before the reply.
                let body = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}],\"isError\":true}}\n\n"
                return (200, ["Content-Type": "text/event-stream"], Data(body.utf8))
            }
        }
        let client = MCPClient(url: URL(string: "https://x/mcp")!, headers: ["Authorization": "Bearer T"], session: StubProtocol.session())
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["a", "b"])
        let result = try await client.call(tool: "a", arguments: [:])
        XCTAssertEqual(result.text, "done")
        XCTAssertTrue(result.isError)
        XCTAssertNil(sessions.first!)
        XCTAssertEqual(sessions.last!, "S1")
    }

    func testToolNamesAreValidAndUnique() {
        var taken = Set<String>()
        let a = MCPTools.modelName(server: "my server", tool: "do.it", taken: taken)
        XCTAssertEqual(a, "my_server__do_it")
        taken.insert(a)
        XCTAssertEqual(MCPTools.modelName(server: "my server", tool: "do it", taken: taken), "my_server__do_it_2")
        XCTAssertLessThanOrEqual(MCPTools.modelName(server: String(repeating: "s", count: 50), tool: String(repeating: "t", count: 50), taken: []).count, 64)
    }

    @MainActor func testImportSkipsLocalServers() throws {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
        store.settings.mcp = []
        let r = try store.importMCP(json: #"{"mcpServers":{"web":{"url":"https://x/mcp","headers":{"Authorization":"Bearer T"}},"local":{"command":"npx"}}}"#)
        XCTAssertEqual(r.added, ["web"])
        XCTAssertEqual(r.skipped, ["local"])
        let server = store.settings.mcp[0]
        XCTAssertEqual(store.headers(of: server)["Authorization"], "Bearer T")
        store.setHeaders([:], of: server)
        store.settings.mcp = []
    }
}

private struct ScriptedClient: LLMClient {
    let replies: [LLMResponse]
    let seen = Seen()
    final class Seen: @unchecked Sendable { var messages: [[ChatMessage]] = []; var tools: [[String]] = [] }

    func complete(system: String, messages: [ChatMessage], tools: [ToolDef], onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse {
        let i = seen.messages.count
        seen.messages.append(messages)
        seen.tools.append(tools.map(\.name))
        let r = replies[min(i, replies.count - 1)]
        if !r.text.isEmpty { onText(r.text) }
        return r
    }
}

final class AgentTests: XCTestCase {
    func testToolRoundTripKeepsResultOrder() async throws {
        let calls = [ToolCall(id: "1", name: "slow", arguments: "{}"), ToolCall(id: "2", name: "fast", arguments: "{}")]
        let client = ScriptedClient(replies: [LLMResponse(text: "", toolCalls: calls), LLMResponse(text: "Done")])
        let tools = [
            AgentTool(def: ToolDef(name: "slow", description: "", schema: [:])) { _ in try? await Task.sleep(for: .milliseconds(50)); return ("S", false) },
            AgentTool(def: ToolDef(name: "fast", description: "", schema: [:])) { _ in ("F", false) },
        ]
        let out = try await AgentRunner(client: client, system: "", tools: tools).run(messages: [.user("q")])
        XCTAssertEqual(out.text, "Done")
        XCTAssertEqual(client.seen.messages[1].suffix(2).map(\.text), ["S", "F"])
    }

    func testRoundLimit() async {
        let client = ScriptedClient(replies: [LLMResponse(text: "", toolCalls: [ToolCall(id: "1", name: "t", arguments: "{}")])])
        let tool = AgentTool(def: ToolDef(name: "t", description: "", schema: [:])) { _ in ("x", false) }
        do {
            _ = try await AgentRunner(client: client, system: "", tools: [tool], maxRounds: 3).run(messages: [.user("q")])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(client.seen.messages.count, 3)
        }
    }

    func testThinkFilter() {
        func run(_ parts: [String]) -> String {
            let f = ThinkFilter()
            return parts.map { f.push($0) }.joined() + f.finish()
        }
        XCTAssertEqual(run(["<think>hid", "den</thi", "nk>Hello"]), "Hello")
        XCTAssertEqual(run(["Hi <thi", "nk>x</think>there"]), "Hi there")
        XCTAssertEqual(run(["a < b"]), "a < b")
        let answer = String(repeating: "x", count: 90)
        XCTAssertEqual(run([answer, "</think>", answer]), answer, "a stray close after an answer precedes a repeat")
        XCTAssertEqual(run(["Short.</think>Rest"]), "Short. Rest")
    }

    func testSoulLoadedFromToolResultsOnly() async throws {
        // No MCP tools at all is an error, not a silent conversation without a persona.
        do {
            _ = try await AgentSetup.loadSoul(instruction: "load", client: ScriptedClient(replies: [LLMResponse(text: "OK")]), tools: [])
            XCTFail("expected an error")
        } catch {}
    }

    func testSystemPromptHasNoSpeakingRulesFromCode() {
        let s = AgentSetup.mainSystem(soul: "SOUL", spoken: true, listening: true)
        XCTAssertTrue(s.hasPrefix("SOUL"))
        XCTAssertTrue(s.contains(AgentSetup.silentReply))
        XCTAssertFalse(s.lowercased().contains("markdown"))
    }
}

final class SpeechTextTests: XCTestCase {
    private func pieces(_ text: String, chunk: Int = 3) -> [String] {
        let s = SentenceSplitter(minChars: 5, firstClauseChars: 0)
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            out += s.push(String(rest.prefix(chunk)))
            rest = rest.dropFirst(chunk)
        }
        return out + s.flush()
    }

    func testSplitsSentencesAcrossChunks() {
        XCTAssertEqual(pieces("Hello there. How are you? Fine!"), ["Hello there.", "How are you?", "Fine!"])
    }

    func testProtectsOrdinalsAndInitials() {
        XCTAssertEqual(pieces("Came on 28. října to town. J. Smith left."), ["Came on 28. října to town.", "J. Smith left."])
    }

    func testCodeBlocksAreNotSpoken() {
        XCTAssertEqual(pieces("Look here.\n```swift\nlet a = 1.\n```\nThat is all."), ["Look here.", "That is all."])
    }

    func testShortFragmentJoinsTheNext() {
        XCTAssertEqual(pieces("Ok. That works well."), ["Ok. That works well."])
    }

    func testCleanRemovesSymbolsNotWords() {
        XCTAssertEqual(cleanForSpeech("**Bold** [link](https://x.cz) `code` 😀 and - dash"), "Bold link code and - dash")
        XCTAssertEqual(cleanForSpeech("- item\n# Title"), "item Title")
    }

    func testDetectorFindsAPhraseAndIgnoresABlip() {
        let d = PhraseDetector()
        d.silenceMs = 200
        let quiet = [Int16](repeating: 20, count: 16000)
        let loud = (0..<16000).map { Int16(sin(Double($0) * 0.1) * 8000) }
        XCTAssertEqual(d.feed(quiet), [])
        let started = d.feed(loud)
        XCTAssertEqual(started, [.started])
        let ended = d.feed(quiet)
        guard case .ended(let pcm)? = ended.first else { return XCTFail("no phrase") }
        XCTAssertGreaterThan(pcm.count, 16000)
        XCTAssertEqual(d.feed(Array(loud.prefix(1600))), [], "100 ms is not speech")
    }

    func testWavHeader() {
        let w = wavData([1, 2, 3], sampleRate: 16000)
        XCTAssertEqual(w.count, 50)
        XCTAssertEqual(String(decoding: w.prefix(4), as: UTF8.self), "RIFF")
    }

    func testStreamedWavSizesAreFixed() throws {
        var w = wavData([Int16](repeating: 100, count: 1000), sampleRate: 16000)
        w.replaceSubrange(40..<44, with: [0xFF, 0xFF, 0xFF, 0xFF])
        let clip = try AudioFormats.decode(w)
        XCTAssertGreaterThan(clip.buffer.frameLength, 2000, "1000 samples at 16 kHz become 3000 at 48 kHz")
    }

    func testZeroWavSizeIsFixed() throws {
        var w = wavData([Int16](repeating: 100, count: 1000), sampleRate: 16000)
        w.replaceSubrange(40..<44, with: [0, 0, 0, 0])
        let clip = try AudioFormats.decode(w)
        XCTAssertGreaterThan(clip.buffer.frameLength, 2000)
    }

    /// Piper's server sends the audio with a correct header and then the line "/dev/stdout". Played as audio it clicks.
    func testWhatFollowsTheAudioIsNotPlayed() throws {
        let silence = wavData([Int16](repeating: 0, count: 1000), sampleRate: 16000)
        let clip = try AudioFormats.decode(silence + Data("/dev/stdout\n".utf8))
        XCTAssertEqual(AudioFormats.fixedWavHeader(silence + Data("x".utf8)), silence + Data("x".utf8), "a correct header stays")
        let samples = UnsafeBufferPointer(start: clip.buffer.floatChannelData![0], count: Int(clip.buffer.frameLength))
        XCTAssertLessThan(samples.map(abs).max() ?? 1, 0.001)
    }
}

final class CarPlayTests: XCTestCase {
    func testCarShowsStateAndNeverWaitsOnText() {
        XCTAssertEqual(CarVoiceState(phase: .listening, last: nil), .listening)
        XCTAssertEqual(CarVoiceState(phase: .hearing, last: nil), .listening)
        XCTAssertEqual(CarVoiceState(phase: .transcribing, last: nil), .thinking)
        XCTAssertEqual(CarVoiceState(phase: .thinking, last: nil), .thinking)
        XCTAssertEqual(CarVoiceState(phase: .speaking, last: ChatItem(kind: .assistant, text: "ok")), .speaking)
        XCTAssertEqual(CarVoiceState(phase: .listening, last: ChatItem(kind: .error, text: "no")), .problem)
    }

    func testTemplateAcceptsEveryState() {
        XCTAssertLessThanOrEqual(CarVoiceState.allCases.count, 5, "CPVoiceControlTemplate shows at most 5 states")
        for state in CarVoiceState.allCases {
            XCTAssertEqual(state.template.identifier, state.rawValue)
            XCTAssertNotNil(state.template.image, "\(state) symbol must exist")
        }
    }

    func testToneIsPlayableAndDoesNotClick() {
        let tone = AudioFormats.tone(hz: 880, ms: 100)
        XCTAssertEqual(tone.buffer.format, AudioFormats.playback)
        XCTAssertEqual(tone.buffer.frameLength, 4800)
        let samples = tone.buffer.floatChannelData![0]
        XCTAssertEqual(samples[0], 0, accuracy: 0.001)
        XCTAssertEqual(samples[4799], 0, accuracy: 0.01)
    }
}

final class ProfileTests: XCTestCase {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    func testOldSettingsBecomeTheFirstProfile() throws {
        let server = UUID()
        let s = try decode("""
        {"mcp":[{"id":"\(server.uuidString)","name":"memory","url":"http://x/mcp","enabled":true,"disabledTools":[]}],
         "soul":{"text":"Call bootstrap","loadViaMCP":true},
         "voice":{"speakReplies":false,"bargeIn":true,"silenceMs":800,"sensitivity":0.5}}
        """)
        XCTAssertEqual(s.profiles.count, 1)
        XCTAssertEqual(s.activeProfileID, s.profiles[0].id)
        XCTAssertEqual(s.profile.soul.text, "Call bootstrap")
        XCTAssertTrue(s.profile.soul.loadViaMCP)
        XCTAssertFalse(s.profile.speakReplies)
        XCTAssertEqual(s.profile.mcpServers, [server])
        XCTAssertEqual(s.profileMCP.map(\.name), ["memory"])
        XCTAssertEqual(s.voice.silenceMs, 800)
    }

    func testProfilesSurviveSavingAndKeepTheActiveOne() throws {
        var s = AppSettings()
        let second = AgentProfile(name: "Alex", soul: SoulSettings(text: "Hi"), speakReplies: false)
        s.profiles.append(second)
        s.activeProfileID = second.id
        let back = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back.profiles.count, 2)
        XCTAssertEqual(back.profile.name, "Alex")
        XCTAssertEqual(back.profile.soul.text, "Hi")
        XCTAssertFalse(back.profile.speakReplies)
    }

    func testMissingActiveProfileFallsBackToTheFirst() throws {
        let p = AgentProfile(name: "One")
        let json = String(decoding: try JSONEncoder().encode([p]), as: UTF8.self)
        let s = try decode("{\"profiles\":\(json),\"activeProfileID\":\"\(UUID().uuidString)\"}")
        XCTAssertEqual(s.profile.name, "One")
    }

    func testEachProfileLoadsOnlyItsOwnServers() {
        var s = AppSettings()
        let a = MCPServer(name: "a"), b = MCPServer(name: "b")
        s.mcp = [a, b]
        s.addToActiveProfile(a)
        XCTAssertEqual(s.profileMCP.map(\.name), ["a"])
        let other = AgentProfile(name: "Other", mcpServers: [b.id])
        s.profiles.append(other)
        s.activeProfileID = other.id
        XCTAssertEqual(s.profileMCP.map(\.name), ["b"])
    }

    @MainActor func testImportedServerJoinsOnlyTheActiveProfile() throws {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
        var settings = AppSettings()
        let other = AgentProfile(name: "Other")
        settings.profiles.append(other)
        store.settings = settings
        try store.importMCP(json: #"{"mcpServers":{"exa":{"url":"https://example.test/mcp"}}}"#)
        XCTAssertEqual(store.settings.profileMCP.map(\.name), ["exa"])
        XCTAssertTrue(store.settings.profiles[1].mcpServers.isEmpty)
    }
}

final class SoulCompositionTests: XCTestCase {
    private func bootstrap(role: String, text: String) -> String {
        let context = "AGENT IDENTITY\nYou are Test.\n\nSOUL\nBe useful.\n\nSecond paragraph.\n\nACTIVE ROLE (\(role))\n\(text)\n\nLANGUAGE POLICY\nUser communication: cs"
        let data = try! JSONEncoder().encode(["ok": JSONValue.bool(true), "data": ["profile_hash": "abc", "machine_context": .string(context)]])
        return String(decoding: data, as: UTF8.self)
    }

    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    func testTwoRolesShareIdentityAndSoulOnce() {
        let soul = AgentSetup.composeSoul([bootstrap(role: "work", text: "Use the data."), bootstrap(role: "voice", text: "Speak.")])
        XCTAssertEqual(count("You are Test.", in: soul), 1)
        XCTAssertEqual(count("Second paragraph.", in: soul), 1)
        XCTAssertEqual(count("LANGUAGE POLICY", in: soul), 1)
        XCTAssertTrue(soul.contains("ACTIVE ROLE (work)\nUse the data."), soul)
        XCTAssertTrue(soul.contains("ACTIVE ROLE (voice)\nSpeak."), soul)
        XCTAssertFalse(soul.contains("profile_hash"), "Only the text meant for the model")
    }

    func testOneRoleKeepsItsWholeText() {
        let soul = AgentSetup.composeSoul([bootstrap(role: "voice", text: "Speak.\n\nMore.")])
        XCTAssertTrue(soul.hasPrefix("AGENT IDENTITY"), soul)
        XCTAssertTrue(soul.contains("Speak.\n\nMore."), soul)
    }

    func testPlainResultsFromAnyServerStayAsTheyAre() {
        XCTAssertEqual(AgentSetup.composeSoul(["You are a poet.\n\nWrite short."]), "You are a poet.\n\nWrite short.")
        let json = #"{"name":"Ann","role":"poet"}"#
        XCTAssertEqual(AgentSetup.composeSoul([json]), json, "JSON without machine_context is not thrown away")
        XCTAssertEqual(AgentSetup.composeSoul(["Same.", "Same."]), "Same.")
    }
}

final class PhraseFinishTests: XCTestCase {
    private func tone(frames: Int, amplitude: Int16 = 8000) -> [Int16] {
        (0..<frames * 320).map { $0 % 40 < 20 ? amplitude : -amplitude }
    }

    func testTurningOffKeepsAPhraseInProgress() {
        let detector = PhraseDetector()
        _ = detector.feed([Int16](repeating: 0, count: 320 * 30))
        let events = detector.feed(tone(frames: 40))
        XCTAssertEqual(events, [.started])
        let phrase = detector.finish()
        XCTAssertNotNil(phrase)
        XCTAssertGreaterThan(phrase?.count ?? 0, 320 * 30)
        XCTAssertNil(detector.finish(), "Taken once")
    }

    func testTurningOffInSilenceSendsNothing() {
        let detector = PhraseDetector()
        _ = detector.feed([Int16](repeating: 0, count: 320 * 30))
        XCTAssertNil(detector.finish())
    }
}

final class BargeInTests: XCTestCase {
    private func noise(frames: Int, amplitude: Int16) -> [Int16] {
        (0..<frames * 320).map { $0 % 40 < 20 ? amplitude : -amplitude }
    }

    private func detectorWhileAssistantTalks() -> PhraseDetector {
        let d = PhraseDetector()
        _ = d.feed([Int16](repeating: 20, count: 320 * 30))
        d.speaking = true
        return d
    }

    func testOwnEchoDoesNotInterrupt() {
        let d = detectorWhileAssistantTalks()
        XCTAssertEqual(d.feed(noise(frames: 200, amplitude: 500)), [], "Below the gate however long it lasts")
    }

    func testPersonTalkingOverTheAssistantInterrupts() {
        let d = detectorWhileAssistantTalks()
        _ = d.feed(noise(frames: 100, amplitude: 500))
        XCTAssertEqual(d.feed(noise(frames: 12, amplitude: 4000)), [.started])
    }

    func testInterruptionSurvivesGapsInTheVoice() {
        // The phone's echo cancelling cuts a voice into pieces while it plays.
        let d = detectorWhileAssistantTalks()
        var started = false
        for _ in 0..<8 {
            started = d.feed(noise(frames: 4, amplitude: 4000)).contains(.started) || started
            started = d.feed(noise(frames: 1, amplitude: 20)).contains(.started) || started
        }
        XCTAssertTrue(started)
    }

    func testALoudVoiceDoesNotRaiseItsOwnBar() {
        let d = detectorWhileAssistantTalks()
        // Too short to count as speech, repeated: must not make the next real attempt impossible.
        for _ in 0..<40 {
            _ = d.feed(noise(frames: 3, amplitude: 6000))
            _ = d.feed(noise(frames: 6, amplitude: 20))
        }
        XCTAssertTrue(d.feed(noise(frames: 12, amplitude: 4000)).contains(.started))
    }

    func testEchoGateStaysShortlyAfterTheAssistantStops() {
        let d = detectorWhileAssistantTalks()
        _ = d.feed([Int16](repeating: 20, count: 320 * 5))
        d.speaking = false
        XCTAssertEqual(d.feed(noise(frames: 20, amplitude: 500)), [], "Tail of its own voice")
        _ = d.feed([Int16](repeating: 20, count: 320 * 40))
        XCTAssertTrue(d.feed(noise(frames: 12, amplitude: 500)).contains(.started), "Quiet speech counts again")
    }
}

final class GreetingTests: XCTestCase {
    @MainActor func testOpeningGreetsOnceAndOnlyAfterTheNotice() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
        var settings = AppSettings()
        let server = LLMServer(name: "s", baseURL: "http://127.0.0.1:9/v1")
        settings.servers = [server]
        settings.main = ModelChoice(serverID: server.id, model: "m")
        store.settings = settings
        let conversation = ConversationModel(store: store)
        conversation.greetOnce()
        XCTAssertFalse(conversation.isTurnRunning, "Nothing goes out before the notice is accepted")
        store.settings.dataNoticeAccepted = true
        conversation.greetOnce()
        XCTAssertTrue(conversation.isTurnRunning)
        conversation.interrupt()
        conversation.greetOnce()
        XCTAssertFalse(conversation.isTurnRunning, "Only once")
    }

    @MainActor func testAProfileNotAlwaysReadyWaitsForTheUser() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
        var settings = AppSettings()
        let server = LLMServer(name: "s", baseURL: "http://127.0.0.1:9/v1")
        settings.servers = [server]
        settings.main = ModelChoice(serverID: server.id, model: "m")
        settings.dataNoticeAccepted = true
        settings.profiles[0].alwaysReady = false
        store.settings = settings
        let conversation = ConversationModel(store: store)
        conversation.greetOnce()
        XCTAssertFalse(conversation.isTurnRunning)
        conversation.startOver()
        XCTAssertFalse(conversation.isTurnRunning)
        conversation.send("Hello")
        XCTAssertTrue(conversation.isTurnRunning, "The first message goes out as usual")
        conversation.interrupt()
    }

    func testOlderProfilesAreAlwaysReady() throws {
        let old = #"{"profiles":[{"id":"8C0F69B7-B350-4C84-9B43-B48781C6CDCF","name":"Old","soul":{"text":"x","loadViaMCP":false},"speakReplies":false,"mcpServers":[]}]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.profile.name, "Old")
        XCTAssertFalse(s.profile.speakReplies)
        XCTAssertTrue(s.profile.alwaysReady)
    }

    func testSharedSubagentInstructionsMoveIntoEveryProfile() throws {
        let old = #"{"subagentInstructions":"Answer briefly.","profiles":[{"name":"A"},{"name":"B","subagentSoul":{"text":"Own","loadViaMCP":true}}]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.profiles[0].subagentSoul.text, "Answer briefly.")
        XCTAssertEqual(s.profiles[1].subagentSoul.text, "Own", "a profile's own subagent soul stays")
        XCTAssertTrue(s.profiles[1].subagentSoul.loadViaMCP)
        XCTAssertEqual(s.subagentInstructions, "", "copied once, so clearing a profile later is not undone")
        let again = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(again.profiles[0].subagentSoul.text, "Answer briefly.")
    }

    /// The time goes to the model as a reading of the device clock, with its time zone, in every system text.
    func testTheModelIsToldTheTimeOfDay() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Prague"))
        var parts = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: zone, year: 2026, month: 11, day: 7, hour: 17, minute: 2)
        parts.second = 0
        let now = try XCTUnwrap(parts.date)
        let line = AgentSetup.dateLine(now, timeZone: zone)
        XCTAssertEqual(line, "The user's device clock shows it is now 17:02 on Saturday 7 November 2026 (time zone Europe/Prague). This is the real current local time; use it whenever the date or time matters.")
        XCTAssertTrue(AgentSetup.mainSystem(soul: "", spoken: false, listening: false).contains("device clock shows it is now"))
        XCTAssertTrue(AgentSetup.subagentSystem(instructions: "").contains("device clock shows it is now"))
    }

    func testApplesModelIsNoLongerNamedAfterTheIPhone() throws {
        let old = #"{"servers":[{"id":"8C0F69B7-B350-4C84-9B43-B48781C6CDC1","name":"Apple (v tomto iPhonu)","api":"apple","baseURL":""},{"id":"8C0F69B7-B350-4C84-9B43-B48781C6CDC2","name":"My iPhone model","api":"apple","baseURL":""}]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.servers[0].name, tr("Apple (on this device)"))
        XCTAssertEqual(s.servers[1].name, "My iPhone model", "a name the user wrote stays")
    }

    @MainActor func testNoModelMeansNoGreeting() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
        let conversation = ConversationModel(store: store)
        conversation.startOver()
        XCTAssertEqual(conversation.phase, .idle)
        XCTAssertTrue(conversation.items.isEmpty)
    }

    /// The turn itself begins a moment later; here it only must not put the hidden prompt on screen.
    @MainActor func testSwitchingProfileStartsOverAndHidesThePrompt() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
        var settings = AppSettings()
        let server = LLMServer(name: "s", baseURL: "http://127.0.0.1:9/v1")
        settings.servers = [server]
        settings.main = ModelChoice(serverID: server.id, model: "m")
        let other = AgentProfile(name: "Other", speakReplies: false)
        settings.profiles.append(other)
        store.settings = settings
        let conversation = ConversationModel(store: store)
        conversation.switchProfile(to: other.id)
        XCTAssertEqual(store.settings.activeProfileID, other.id)
        XCTAssertFalse(conversation.items.contains { $0.kind == .user }, "The agent speaks first; the prompt stays unseen")
        conversation.interrupt()
    }
}

/// What the user says stays on screen and reaches the model, however the pauses fall.
final class SpokenTextTests: XCTestCase {
    override func setUp() { URLProtocol.registerClass(StubProtocol.self) }
    override func tearDown() {
        URLProtocol.unregisterClass(StubProtocol.self)
        StubProtocol.handler = nil
        StubProtocol.bodies = []
    }

    @MainActor private func conversation(heard: [String], replies: [String], interruptOnWord: Bool = false, speech: Double = 1, withTools: Bool = false) -> ConversationModel {
        final class Queue: @unchecked Sendable {
            var heard: [String], replies: [String]
            init(heard: [String], replies: [String]) { self.heard = heard; self.replies = replies }
        }
        let queue = Queue(heard: heard, replies: replies)
        StubProtocol.handler = { r in
            if r.url!.path.hasSuffix("/inference") {
                Thread.sleep(forTimeInterval: 0.2)
                return (200, ["Content-Type": "application/json"], Data("{\"text\":\"\(queue.heard.removeFirst())\"}".utf8))
            }
            if String(decoding: r.httpBody ?? Data(), as: UTF8.self).contains("You listen to a user of a voice assistant") {
                return (200, ["Content-Type": "text/event-stream"], sse([#"{"choices":[{"index":0,"delta":{"content":"{\"tasks\":[{\"task\":\"look up the weather now\"}]}"}}]}"#, "[DONE]"]))
            }
            if String(decoding: r.httpBody ?? Data(), as: UTF8.self).contains("You are a subagent") {
                Thread.sleep(forTimeInterval: 2)
                return (200, ["Content-Type": "text/event-stream"], sse([#"{"choices":[{"index":0,"delta":{"content":"Found it."}}]}"#, "[DONE]"]))
            }
            var reply = queue.replies.removeFirst()
            if reply == "DELEGATE" {
                let call = #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"delegate","arguments":"{\"task\":\"look it up\"}"}}]}}]}"#
                return (200, ["Content-Type": "text/event-stream"], sse([call, "[DONE]"]))
            }
            if reply.hasPrefix("SLOW:") {
                reply.removeFirst(5)
                Thread.sleep(forTimeInterval: 2.5)
            }
            if reply == "TOO_LONG" { return (400, ["Content-Type": "application/json"], Data(#"{"error":{"code":"context_length_exceeded","message":"This model's maximum context length is 10 tokens."}}"#.utf8)) }
            let delta = #"{"choices":[{"index":0,"delta":{"content":"\#(reply)"}}]}"#
            return (200, ["Content-Type": "text/event-stream"], sse([delta, "[DONE]"]))
        }
        let store = SettingsStore(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
        var settings = AppSettings()
        let server = LLMServer(name: "s", baseURL: "http://127.0.0.1:9/v1")
        settings.servers = [server]
        settings.main = ModelChoice(serverID: server.id, model: "m")
        settings.stt.kind = .whisperCpp
        settings.stt.url = "http://127.0.0.1:9/inference"
        settings.profiles[0].speakReplies = false
        settings.dataNoticeAccepted = true
        settings.voice.bargeInOnWord = interruptOnWord
        if withTools {
            settings.phoneTools = [PhoneTools.all[0].name]
            settings.profiles[0].mcpServers = [PhoneTools.serverID]
        }
        store.settings = settings
        let c = ConversationModel(store: store)
        c.speechConfidence = { _ in speech }
        return c
    }

    @MainActor private func waitForRepliesCount(_ count: Int, in c: ConversationModel) async {
        for _ in 0..<200 where StubProtocol.bodies.filter({ String(decoding: $0, as: UTF8.self).contains("\"messages\"") }).count < count || c.isTurnRunning {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private var lastPrompt: String { String(decoding: StubProtocol.bodies.last ?? Data(), as: UTF8.self) }
    private let pcm = [Int16](repeating: 0, count: 1600)

    @MainActor func testAConversationThatNoLongerFitsStartsAnewWithTheLastMessage() async {
        let c = conversation(heard: [], replies: ["First answer.", "TOO_LONG", "Second answer."])
        c.send("First question")
        await waitForRepliesCount(1, in: c)
        c.send("Second question")
        await waitForRepliesCount(3, in: c)
        XCTAssertEqual(c.items.filter { $0.kind == .user }.map(\.text), ["First question", "Second question"], "What was said stays on screen")
        XCTAssertEqual(c.items.filter { $0.kind == .assistant }.map(\.text), ["First answer.", "Second answer."])
        XCTAssertEqual(c.items.filter { $0.kind == .notice }.count, 1)
        XCTAssertEqual(c.items.map(\.kind).suffix(3), [.notice, .user, .assistant])
        XCTAssertFalse(c.items.contains { $0.kind == .error })
        XCTAssertTrue(lastPrompt.contains("Second question"))
        XCTAssertFalse(lastPrompt.contains("First question"), "The model starts with only the last message")
    }

    @MainActor func testWithNoHistoryToDropItStopsInsteadOfTryingForever() async {
        let c = conversation(heard: [], replies: ["TOO_LONG", "Never asked."])
        c.send("Only question")
        await waitForRepliesCount(1, in: c)
        XCTAssertEqual(c.items.filter { $0.kind == .error }.count, 1)
        XCTAssertEqual(StubProtocol.bodies.count, 1)
        XCTAssertFalse(c.isTurnRunning)
    }

    func testContextLimitsAreRecognisedAcrossProviders() {
        XCTAssertTrue(HTTPFailure(status: 400, body: #"{"error":{"code":"context_length_exceeded"}}"#).isContextLimit)
        XCTAssertTrue(HTTPFailure(status: 400, body: #"{"error":{"message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#).isContextLimit)
        XCTAssertTrue(HTTPFailure(status: 400, body: #"{"error":{"message":"The input token count exceeds the maximum"}}"#).isContextLimit)
        XCTAssertFalse(HTTPFailure(status: 400, body: #"{"error":{"message":"Invalid model"}}"#).isContextLimit)
        XCTAssertFalse(HTTPFailure(status: 500, body: "context length").isContextLimit, "Only a refused request")
    }

    @MainActor func testGoingOnBeforeTheTranscriptIsReadyIsOneMessage() async {
        let c = conversation(heard: ["Find that.", "And the rest."], replies: ["Answer."])
        c.hearForTesting(.started)
        c.hearForTesting(.ended(pcm))
        c.hearForTesting(.started) // the first transcript is still on its way
        c.hearForTesting(.ended(pcm))
        await waitForRepliesCount(1, in: c)
        XCTAssertEqual(c.items.filter { $0.kind == .user }.map(\.text), ["Find that. And the rest."])
        XCTAssertTrue(lastPrompt.contains("Find that. And the rest."))
    }

    @MainActor func testASilentReplyLeavesTheWordsAndTheyGoWithTheNextOnes() async {
        let c = conversation(heard: ["Find that", "and the rest."], replies: ["[SILENT]", "Answer."])
        c.hearForTesting(.started)
        c.hearForTesting(.ended(pcm))
        await waitForRepliesCount(1, in: c)
        XCTAssertEqual(c.items.filter { $0.kind == .user }.map(\.text), ["Find that"])
        c.hearForTesting(.started)
        c.hearForTesting(.ended(pcm))
        await waitForRepliesCount(2, in: c)
        XCTAssertEqual(c.items.filter { $0.kind == .user }.map(\.text), ["Find that", "and the rest."])
        XCTAssertTrue(lastPrompt.contains("Find that and the rest."))
    }

    @MainActor func testWithInterruptOnWordANoiseDoesNotStopTheAgent() async throws {
        let c = conversation(heard: ["[BLANK_AUDIO]"], replies: ["SLOW:Answer."], interruptOnWord: true)
        c.send("Question")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(c.isTurnRunning)
        c.hearForTesting(.started)
        c.hearForTesting(.ended(pcm))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(c.isTurnRunning, "a sound without a word does not stop the agent")
        await waitForRepliesCount(1, in: c)
        XCTAssertEqual(c.items.filter { $0.kind == .user }.map(\.text), ["Question"])
        XCTAssertEqual(c.items.filter { $0.kind == .assistant }.map(\.text), ["Answer."])
    }

    @MainActor func testWithInterruptOnWordTheFirstWordStopsTheAgentAndIsSent() async throws {
        let c = conversation(heard: ["Stop that."], replies: ["SLOW:Long answer.", "OK."], interruptOnWord: true)
        c.send("Question")
        try await Task.sleep(for: .milliseconds(300))
        c.hearForTesting(.started)
        XCTAssertTrue(c.isTurnRunning, "nothing stops before a word is written")
        c.hearForTesting(.ended(pcm))
        await waitForRepliesCount(2, in: c)
        XCTAssertEqual(c.items.filter { $0.kind == .user }.map(\.text), ["Question", "Stop that."])
        XCTAssertEqual(c.items.filter { $0.kind == .assistant }.map(\.text).last, "OK.")
        XCTAssertTrue(lastPrompt.contains("Stop that."))
    }

    @MainActor func testWithInterruptOnWordWhisperWritingWordsForNoiseDoesNotStopTheAgent() async throws {
        let c = conversation(heard: ["Titulky vytvořil JohnyX."], replies: ["SLOW:Answer."], interruptOnWord: true, speech: 0.2)
        c.send("Question")
        try await Task.sleep(for: .milliseconds(300))
        c.hearForTesting(.started)
        c.hearForTesting(.ended(pcm))
        await waitForRepliesCount(1, in: c)
        XCTAssertEqual(c.items.filter { $0.kind == .user }.map(\.text), ["Question"])
        XCTAssertEqual(c.items.filter { $0.kind == .assistant }.map(\.text), ["Answer."])
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<120 where !condition() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @MainActor func testSpeechWhileTheAgentWorksWaitsForItsTurn() async throws {
        let c = conversation(heard: ["And the weather."], replies: ["SLOW:Homelab answer.", "Weather answer."])
        c.send("Tell me about the homelab.")
        try await Task.sleep(for: .milliseconds(300))
        c.hearForTesting(.started)
        XCTAssertTrue(c.isTurnRunning, "speaking before the agent says anything does not stop it")
        c.hearForTesting(.ended(pcm))
        await waitForRepliesCount(2, in: c)
        await waitUntil { !c.isTurnRunning && c.items.filter { $0.kind == .assistant }.count == 2 }
        XCTAssertEqual(c.items.filter { $0.kind == .user }.map(\.text), ["Tell me about the homelab.", "And the weather."])
        XCTAssertEqual(c.items.filter { $0.kind == .assistant }.map(\.text), ["Homelab answer.", "Weather answer."])
    }

    @MainActor func testAfterStopTheUnansweredMessageGoesWithTheNext() async throws {
        let c = conversation(heard: [], replies: ["SLOW:Never shown.", "Both answered."])
        c.send("Tell me about the homelab.")
        try await Task.sleep(for: .milliseconds(300))
        c.interrupt()
        c.send("And the weather.")
        await waitForRepliesCount(2, in: c)
        await waitUntil { !c.isTurnRunning }
        XCTAssertTrue(lastPrompt.contains(#"Tell me about the homelab.\n\nAnd the weather."#), "one message with both: \(lastPrompt.suffix(400))")
    }

    @MainActor func testAnAnsweredMessageStaysItsOwn() async {
        let c = conversation(heard: [], replies: ["First answer.", "Second answer."])
        c.send("First")
        await waitForRepliesCount(1, in: c)
        c.send("Second")
        await waitForRepliesCount(2, in: c)
        XCTAssertFalse(lastPrompt.contains(#"First\n\nSecond"#))
        XCTAssertTrue(lastPrompt.contains("First answer."))
    }

    @MainActor func testTheAgentTalksWhileASubagentWorksAndTellsTheReportLater() async {
        let c = conversation(heard: [], replies: ["DELEGATE", "On it.", "Fine, thanks.", "Here is what I found."], withTools: true)
        c.send("Find it in my memory.")
        await waitUntil { !c.isTurnRunning && c.items.contains { $0.text == "On it." } }
        XCTAssertEqual(c.activeSubagents, 1, "the subagent works in the background")
        XCTAssertFalse(c.isTurnRunning, "the agent does not wait for it")
        c.send("How are you?")
        await waitUntil { c.items.contains { $0.text == "Fine, thanks." } }
        XCTAssertEqual(c.activeSubagents, 1, "chatting meanwhile, the subagent still works")
        await waitUntil { c.items.contains { $0.text == "Here is what I found." } && !c.isTurnRunning }
        XCTAssertEqual(c.activeSubagents, 0)
        XCTAssertEqual(c.items.filter { $0.kind == .assistant }.map(\.text), ["On it.", "Fine, thanks.", "Here is what I found."])
        XCTAssertEqual(c.items.filter { $0.kind == .user }.map(\.text), ["Find it in my memory.", "How are you?"], "the report is not a bubble of the user's")
        XCTAssertTrue(lastPrompt.contains("Found it."), "the report goes to the main agent")
    }

    @MainActor func testStopEndsTheAnswerNotTheBackgroundWork() async {
        let c = conversation(heard: [], replies: ["DELEGATE", "On it.", "Report told."], withTools: true)
        c.send("Find it.")
        await waitUntil { c.activeSubagents == 1 }
        c.interrupt()
        XCTAssertEqual(c.activeSubagents, 1, "Stop ends what the agent says; the background work goes on")
        c.newConversation()
        XCTAssertEqual(c.activeSubagents, 0, "a new conversation stops it")
    }

    @MainActor func testAMessageSentWhileTheAgentWorksWaitsAndGetsItsOwnSubagent() async throws {
        let c = conversation(heard: [], replies: ["SLOW:Homelab answer.", "Weather answer."], withTools: true)
        c.send("Tell me about the homelab.")
        try await Task.sleep(for: .milliseconds(300))
        c.send("And the weather.")
        XCTAssertTrue(c.isTurnRunning, "the first is not stopped")
        XCTAssertEqual(c.items.filter { $0.kind == .user }.map(\.text), ["Tell me about the homelab.", "And the weather."], "the second message shows at once")
        await waitUntil { c.activeSubagents == 1 }
        XCTAssertEqual(c.activeSubagents, 1, "the waiting message has its own subagent already")
        await waitUntil { !c.isTurnRunning && c.items.filter { $0.kind == .assistant }.count == 2 }
        XCTAssertEqual(c.items.filter { $0.kind == .assistant }.map(\.text), ["Homelab answer.", "Weather answer."], "both answered, in order")
        XCTAssertTrue(lastPrompt.contains("Homelab answer."))
        XCTAssertTrue(lastPrompt.contains("Found it."), "with what its own subagent found")
    }

    func testOnlyRealWordsCount() {
        XCTAssertFalse(AgentSetup.hasWords(""))
        XCTAssertFalse(AgentSetup.hasWords(" [BLANK_AUDIO] "))
        XCTAssertFalse(AgentSetup.hasWords("(music) *cough* ..."))
        XCTAssertTrue(AgentSetup.hasWords("Stůj"))
        XCTAssertTrue(AgentSetup.hasWords("[noise] no"))
    }

    func testOlderVoiceSettingsKeepWorking() throws {
        let v = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"bargeIn":false,"silenceMs":900,"sensitivity":0.4}"#.utf8))
        XCTAssertFalse(v.bargeIn)
        XCTAssertFalse(v.bargeInOnWord)
        XCTAssertEqual(v.silenceMs, 900)
    }
}

final class AppleModelTests: XCTestCase {
    @available(iOS 26, *)
    private func tool(_ schema: String) -> AppleTool {
        let def = ToolDef(name: "t__x", description: "d", schema: JSONValue.parse(Data(schema.utf8))!)
        return AppleTool(AgentTool(def: def) { arguments in (arguments, false) }, onTool: { _, _ in })
    }

    func testToolSchemasTranslate() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Needs iOS 26") }
        let t = tool(#"{"type":"object","required":["q"],"properties":{"q":{"type":"string","description":"what"},"n":{"type":["integer","null"]},"kind":{"type":"string","enum":["a","b"]},"tags":{"type":"array","items":{"type":"string"}},"inner":{"type":"object","properties":{"deep":{"type":"boolean"}}},"odd":{"anyOf":[{"type":"string"},{"type":"number"}]}}}"#)
        XCTAssertEqual(t.name, "t__x")
        let text = String(describing: t.parameters)
        for name in ["q", "kind", "tags", "deep", "odd"] { XCTAssertTrue(text.contains(name), "\(name) is missing in \(text.prefix(800))") }
        _ = tool(#"{"type":"object"}"#)
        _ = tool("{}")
    }

    func testHistoryBecomesATranscriptWithoutThePrompt() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Needs iOS 26") }
        var call = ChatMessage.assistant("")
        call.toolCalls = [ToolCall(id: "1", name: "x", arguments: "{}")]
        let messages: [ChatMessage] = [.user("first"), call, .assistant("answer"), .user("second")]
        let entries = Array(AppleModelClient.transcript(system: "sys", messages: messages, tools: [tool("{}")]))
        XCTAssertEqual(entries.count, 3, "Instructions, the first question and the answer; the last question is the prompt")
    }

    func testTheRunnerLetsTheModelRunItsTools() async throws {
        struct Own: ToolRunningLLMClient {
            func complete(system: String, messages: [ChatMessage], tools: [ToolDef], onText: @escaping @Sendable (String) -> Void) async throws -> LLMResponse { XCTFail("Not used"); return LLMResponse() }
            func run(system: String, messages: [ChatMessage], tools: [AgentTool], onText: @escaping @Sendable (String) -> Void, onTool: @escaping @Sendable (String, String) -> Void) async throws -> String {
                onTool("x", "{}")
                onText("done")
                return "done"
            }
        }
        let names = TextBox()
        let out = try await AgentRunner(client: Own(), system: "s", tools: []).run(messages: [.user("q")], onTool: { name, _ in names.add(name) })
        XCTAssertEqual(out.text, "done")
        XCTAssertEqual(out.messages.count, 2)
        XCTAssertEqual(names.items, ["x"])
    }

    func testPrivateCloudIsNotOfferedAndAnOldChoiceExplainsItself() async throws {
        XCTAssertFalse(((try? AppleModel.names()) ?? []).contains(AppleModel.privateCloud))
        guard #available(iOS 26, *) else { throw XCTSkip("Needs iOS 26") }
        let client = AppleModelClient(model: AppleModel.privateCloud)
        do {
            _ = try await client.complete(system: "s", messages: [.user("q")], tools: []) { _ in }
            XCTFail("Must not reach the framework, which would end the app")
        } catch {
            XCTAssertTrue(error is AppError)
        }
    }

    func testSoulLoadingGetsOnlyTheToolItNames() {
        let all = ["agent_bootstrap", "remember", "notes"]
        XCTAssertEqual(AgentSetup.toolsNamed(in: "Call agent_bootstrap on the umm server", among: all), ["agent_bootstrap"])
        XCTAssertEqual(AgentSetup.toolsNamed(in: "Load who you are", among: all), all, "Nothing named: the model chooses")
    }

    func testABriefDelegateListsOnlyNames() {
        let tools = [ToolDef(name: "search", description: "A long description of it", schema: .object([:]))]
        XCTAssertTrue(AgentSetup.delegateDef(tools: tools).description.contains("A long description"))
        let brief = AgentSetup.delegateDef(tools: tools, brief: true).description
        XCTAssertTrue(brief.contains("search"))
        XCTAssertFalse(brief.contains("A long description"))
    }

    func testToolResultsAreCutToTheRoomLeft() {
        let room = ToolResultRoom()
        XCTAssertEqual(room.take("no limit yet"), "no limit yet")
        room.setTokens(3)
        XCTAssertEqual(room.take("abcd"), "abcd")
        XCTAssertTrue(room.take("efghijkl").hasPrefix("ef\n"))
        XCTAssertFalse(room.take("anything").contains("anything"))
    }

    func testAppleServerHasNoAddressAndIsOffered() {
        XCTAssertTrue(LLMPreset.all.contains { $0.api == .apple })
        XCTAssertTrue(makeLLMClient(LLMConfig(api: .apple, baseURL: "", apiKey: "", model: AppleModel.onDevice, extra: nil)) is AppleModelClient)
    }
}

final class SpeechServicesTests: XCTestCase {
    func testOldSettingsBecomeTheFirstServiceInUse() throws {
        let old = #"{"stt":{"kind":"whisperCpp","url":"http://a/inference","model":"","language":"cs","prompt":""},"tts":{"kind":"piper","url":"http://a/api/tts","model":"","voice":"jirka","language":""}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.sttServices.count, 1)
        XCTAssertEqual(s.stt.kind, .whisperCpp)
        XCTAssertEqual(s.stt.url, "http://a/inference")
        XCTAssertEqual(s.tts.voice, "jirka")
    }

    func testSwitchingKeepsEveryServiceAndAllSurvivesSaving() throws {
        var s = AppSettings()
        var first = TTSSettings(kind: .piper)
        first.url = "http://one/api/tts"
        var second = TTSSettings(kind: .piper)
        second.url = "http://two/api/tts"
        s.ttsServices += [first, second]
        s.activeTTS = first.id
        XCTAssertEqual(s.tts.url, "http://one/api/tts")
        s.activeTTS = second.id
        XCTAssertEqual(s.tts.url, "http://two/api/tts")
        s.tts.voice = "only here"
        XCTAssertEqual(s.ttsServices.first { $0.id == first.id }?.voice, "")
        XCTAssertNotEqual(first.keyAccount, second.keyAccount, "Two services of one kind have separate logins")
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.ttsServices, s.ttsServices)
        XCTAssertEqual(back.tts.id, second.id)
    }

    func testKeysFromTheOldPlaceGoOnWorking() throws {
        Keychain.set("tts.piper", "piper key")
        Keychain.set("stt.elevenLabs", "scribe key")
        defer {
            Keychain.set("tts.piper", "")
            Keychain.set("stt.elevenLabs", "")
        }
        guard Keychain.get("tts.piper") == "piper key" else { throw XCTSkip("Keychain needs a signed build") }
        var s = AppSettings()
        s.ttsServices = [TTSSettings(kind: .piper)]
        s.activeTTS = s.ttsServices[0].id
        s.moveOldSpeechKeys()
        XCTAssertEqual(Keychain.get(s.tts.keyAccount), "piper key")
        let added = try XCTUnwrap(s.sttServices.first { $0.kind == .elevenLabs }, "A login without a service gets one")
        XCTAssertEqual(Keychain.get(added.keyAccount), "scribe key")
        XCTAssertEqual(s.stt.kind, .apple, "The service in use does not change")
        Keychain.set(s.tts.keyAccount, "")
        Keychain.set(added.keyAccount, "")
    }
}

final class ReleaseTests: XCTestCase {
    override func tearDown() { Localizer.use(.system) }

    func testTheChosenLanguageIsUsedAtOnce() {
        Localizer.use(.czech)
        XCTAssertEqual(tr("Settings"), "Nastavení")
        XCTAssertEqual(tr("Connected. Models: %d.", 3), "Připojeno. Počet modelů: 3.")
        XCTAssertEqual(AppError("Invalid URL.").errorDescription, "Neplatná URL.")
        XCTAssertEqual(STTKind.apple.label, "Apple (v tomto zařízení)")
        Localizer.use(.english)
        XCTAssertEqual(tr("Settings"), "Settings")
        XCTAssertEqual(STTKind.apple.label, "Apple (on this device)")
    }

    func testSpeechFollowsTheChosenLanguage() {
        Localizer.use(.czech)
        XCTAssertEqual(Localizer.speechLanguage, "cs-CZ")
        XCTAssertTrue(AgentSetup.greeting(language: Localizer.speechLanguageName).contains("in Czech"))
        Localizer.use(.english)
        XCTAssertEqual(Localizer.speechLanguage, "en-US")
        XCTAssertTrue(AgentSetup.greeting(language: Localizer.speechLanguageName).contains("in English"))
    }

    func testOldSettingsKeepWorkingAndAskOnce() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"mcp":[{"id":"6B7FACCF-231C-4B98-8C7A-C87786645995","name":"a","url":"http://x/mcp","enabled":false,"disabledTools":[]}]}"#.utf8))
        XCTAssertEqual(s.language, .system)
        XCTAssertFalse(s.dataNoticeAccepted)
        XCTAssertEqual(s.mcp.map(\.name), ["a"], "The old switch is ignored")
        XCTAssertEqual(s.profileMCP.map(\.name), ["a"], "A server that had been off is chosen by the profile now")
    }

    func testOnlyTheProfileDecidesAboutAServer() async {
        var s = AppSettings()
        let on = MCPServer(name: "on", url: "http://127.0.0.1:9/mcp"), off = MCPServer(name: "off", url: "http://127.0.0.1:9/mcp")
        s.mcp = [on, off]
        s.addToActiveProfile(on)
        XCTAssertEqual(s.profileMCP.map(\.name), ["on"])
        let result = await MCPTools.connect(s.profileMCP) { _ in [:] }
        XCTAssertEqual(result.failures.count, 1, "It tries the chosen server, and only that one")
    }
}

final class PhoneToolsTests: XCTestCase {
    func testAToolExistsForTheAgentOnlyWhenTurnedOn() {
        XCTAssertTrue(PhoneTools.agentTools(enabled: []).isEmpty)
        XCTAssertEqual(PhoneTools.agentTools(enabled: ["list_events", "gone"]).map(\.def.name), ["device__list_events"])
    }

    func testAProfileGetsThemOnlyWithTheIPhoneSwitchedOn() throws {
        var s = AppSettings()
        s.phoneTools = ["list_events"]
        XCTAssertEqual(s.profilePhoneTools, [])
        s.profile.mcpServers.append(PhoneTools.serverID)
        XCTAssertEqual(s.profilePhoneTools, ["list_events"])
        XCTAssertEqual(s.profileMCP.count, 0, "It is not a network server")
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.profilePhoneTools, ["list_events"])
    }

    func testTurningOnAToolSwitchesTheCurrentProfileOnly() {
        var s = AppSettings()
        let other = AgentProfile(name: "Other")
        s.profiles.append(other)
        s.turnOnPhoneTool("list_events")
        s.turnOnPhoneTool("list_events")
        XCTAssertEqual(s.profilePhoneTools, ["list_events"])
        XCTAssertEqual(s.profile.mcpServers, [PhoneTools.serverID])
        XCTAssertTrue(s.profiles[1].mcpServers.isEmpty)
    }

    func testOldSettingsHaveNoToolsOn() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(s.phoneTools, [])
    }

    func testTheFormsOfTimeModelsWrite() throws {
        let local = try XCTUnwrap(PhoneTools.parseDate("2026-11-02T14:30"))
        XCTAssertEqual(Calendar.current.component(.hour, from: local), 14)
        XCTAssertEqual(PhoneTools.parseDate("2026-11-02 14:30"), local)
        XCTAssertEqual(PhoneTools.parseDate("2026-11-02T14:30:00"), local)
        XCTAssertEqual(PhoneTools.parseDate(PhoneTools.format(local)), local)
        XCTAssertNotNil(PhoneTools.parseDate("2026-11-02T14:30:00Z"))
        XCTAssertNotNil(PhoneTools.parseDate("2026-11-02T14:30:00.000+01:00"))
        XCTAssertEqual(Calendar.current.component(.hour, from: try XCTUnwrap(PhoneTools.parseDate("2026-11-02"))), 0)
        XCTAssertNil(PhoneTools.parseDate("tomorrow"))
    }

    func testAMistakeGoesBackToTheModel() async throws {
        guard await PhoneTools.requestAccess(.calendar) else { throw XCTSkip("no calendar access") }
        let tool = try XCTUnwrap(PhoneTools.agentTools(enabled: ["list_events"]).first)
        let r = await tool.run(#"{"start":"tomorrow"}"#)
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("tomorrow"), r.text)
    }

    func testCalendarAndRemindersRoundTrip() async throws {
        guard await PhoneTools.requestAccess(.calendar), await PhoneTools.requestAccess(.reminders) else { throw XCTSkip("no access") }
        let title = "Voice Agent test \(UUID().uuidString)"
        let start = "2031-03-04T10:00"
        _ = try await PhoneTools.run("create_event", ["title": .string(title), "start": .string(start)])
        let listed = try await PhoneTools.run("list_events", ["start": "2031-03-04", "end": "2031-03-05"]).compact
        XCTAssertTrue(listed.contains(title), listed)

        let store = EKEventStore()
        for e in store.events(matching: store.predicateForEvents(withStart: try XCTUnwrap(PhoneTools.parseDate("2031-03-04")), end: try XCTUnwrap(PhoneTools.parseDate("2031-03-05")), calendars: nil)) where e.title == title {
            try store.remove(e, span: .thisEvent)
        }
        let created = try await PhoneTools.run("create_reminder", ["title": .string(title)])
        let id = try XCTUnwrap(created["id"]?.string)
        let reminders = try await PhoneTools.run("list_reminders", [:]).compact
        XCTAssertTrue(reminders.contains(title), reminders)
        _ = try await PhoneTools.run("complete_reminder", ["id": .string(id)])
        let after = try await PhoneTools.run("list_reminders", [:]).compact
        XCTAssertFalse(after.contains(title))
        if let r = store.calendarItem(withIdentifier: id) as? EKReminder { try store.remove(r, commit: true) }
    }
}

final class LiveWorkTests: XCTestCase {
    private func voice(_ frames: Int) -> [Int16] { (0..<frames * 320).map { $0 % 40 < 20 ? 6000 : -6000 } }
    private func quiet(_ frames: Int) -> [Int16] { [Int16](repeating: 0, count: frames * 320) }
    private func phrases(_ events: [PhraseDetector.Event]) -> [[Int16]] { events.compactMap { if case .phrase(let p) = $0 { p } else { nil } } }

    private func detector(wanted: Bool = true) -> PhraseDetector {
        let d = PhraseDetector()
        d.phrasesWanted = wanted
        _ = d.feed(quiet(30))
        return d
    }

    func testAShortPauseGivesAPieceAndTheUtteranceGoesOn() {
        let d = detector()
        var events = d.feed(voice(60))
        XCTAssertEqual(events, [.started])
        events = d.feed(quiet(15))
        XCTAssertEqual(phrases(events).count, 1)
        XCTAssertFalse(events.contains { if case .ended = $0 { true } else { false } }, "Still the same utterance")
        events = d.feed(voice(60)) + d.feed(quiet(15))
        XCTAssertEqual(phrases(events).count, 1, "Only the new part")
        XCTAssertLessThan(phrases(events)[0].count, 320 * 100)
        let end = d.feed(quiet(60))
        XCTAssertTrue(end.contains { if case .ended = $0 { true } else { false } }, "The whole goes on to the final transcript")
    }

    func testTooShortPiecesAreNotCut() {
        let d = detector()
        _ = d.feed(voice(12))
        XCTAssertEqual(phrases(d.feed(quiet(15))).count, 0, "A word on its own waits for more")
    }

    func testLongSpeechWithoutAPauseIsCut() {
        let d = detector()
        XCTAssertEqual(phrases(d.feed(voice(650))).count, 1)
    }

    func testNoPiecesWhenSwitchedOff() {
        let d = detector(wanted: false)
        XCTAssertEqual(phrases(d.feed(voice(60)) + d.feed(quiet(15))).count, 0)
    }

    @MainActor func testPlanIsReadFromWhatModelsWrite() {
        XCTAssertEqual(LiveWork.parsePlan(#"{"tasks":[{"task":"Find the opening hours"},{"task":"short"}]}"#), ["Find the opening hours"])
        XCTAssertEqual(LiveWork.parsePlan("Sure:\n```json\n{\"tasks\":[{\"task\":\"Read my calendar\"}]}\n```"), ["Read my calendar"])
        XCTAssertEqual(LiveWork.parsePlan("no idea"), [])
        XCTAssertEqual(LiveWork.parsePlan(#"{"tasks":[]}"#), [])
    }

    func testOnlyReadingToolsMayRunWhileTalking() {
        XCTAssertTrue(PhoneTools.readsOnly("list_events"))
        XCTAssertTrue(PhoneTools.readsOnly("search_contacts"))
        XCTAssertFalse(PhoneTools.readsOnly("create_event"))
        XCTAssertFalse(PhoneTools.readsOnly("complete_reminder"))
        XCTAssertTrue(AgentSetup.liveSubagentSystem(instructions: "").contains("Never create"))
    }

    func testTheSettingIsOnForOldSettings() throws {
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).workWhileTalking)
    }
}

final class ThinkingTests: XCTestCase {
    private func config(_ api: LLMAPI, _ thinking: Thinking, base: String = "http://host:11434/v1", model: String = "m") -> LLMConfig {
        LLMConfig(api: api, baseURL: base, apiKey: "", model: model, extra: nil, thinking: thinking)
    }

    func testModelDefaultAndAppleSendNothing() {
        XCTAssertEqual(Thinking.model.variants(api: .anthropic, model: "m", base: "b"), [nil])
        XCTAssertEqual(Thinking.high.variants(api: .apple, model: "on-device", base: ""), [nil])
    }

    func testEachAPIGetsItsOwnParameters() {
        XCTAssertEqual(Thinking.low.variants(api: .openAIChat, model: "m", base: "https://api.openai.com/v1"), [["reasoning_effort": "low"]])
        XCTAssertEqual(Thinking.off.variants(api: .openAIChat, model: "m", base: "https://api.openai.com/v1").count, 3, "none, then minimal, then low")
        XCTAssertEqual(Thinking.off.variants(api: .openAIChat, model: "m", base: "http://10.0.0.2:11434/v1"), [["chat_template_kwargs": ["enable_thinking": false]]])
        XCTAssertEqual(Thinking.high.variants(api: .openAIResponses, model: "m", base: ""), [["reasoning": ["effort": "high"]]])
        let claude = Thinking.medium.variants(api: .anthropic, model: "m", base: "")
        XCTAssertEqual(claude.first, ["thinking": ["type": "adaptive"], "output_config": ["effort": "medium"]])
        XCTAssertEqual(claude.last??["max_tokens"]?.int, 8192 + 8192, "an older model's budget needs room under max_tokens")
        XCTAssertEqual(Thinking.off.variants(api: .gemini, model: "gemini-2.5-flash", base: "").first??["generationConfig"]?["thinkingConfig"]?["thinkingBudget"]?.int, 0)
        XCTAssertEqual(Thinking.low.variants(api: .gemini, model: "gemini-3-pro", base: "").first??["generationConfig"]?["thinkingConfig"]?["thinkingLevel"]?.string, "low")
    }

    func testExtraParametersOverrideThinking() {
        let c = OpenAIChatClient(LLMConfig(api: .openAIChat, baseURL: "u", apiKey: "", model: "m", extra: ["reasoning_effort": "medium"], thinking: .high))
        XCTAssertEqual(c.body(system: "", messages: [.user("hi")], tools: [], thinking: ["reasoning_effort": "high"])["reasoning_effort"]?.string, "medium")
    }

    func testARefusedVariantFallsBackToTheNext() async throws {
        var tried: [JSONValue?] = []
        let r = try await config(.anthropic, .off).firstAccepted { variant in
            tried.append(variant)
            if tried.count < 3 { throw HTTPFailure(status: 400, body: "thinking.type: not supported for this model") }
            return LLMResponse(text: "ok")
        }
        XCTAssertEqual(r.text, "ok")
        XCTAssertEqual(tried.last, ["output_config": ["effort": "low"]])
    }

    func testAllRefusedShowsTheFirstAnswerAndContextLimitIsNotRetried() async {
        var tried = 0
        do {
            _ = try await config(.openAIChat, .off, base: "https://api.openai.com/v1").firstAccepted { _ in
                tried += 1
                throw HTTPFailure(status: 400, body: "answer \(tried)")
            }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual((error as? HTTPFailure)?.body, "answer 1")
        }
        XCTAssertEqual(tried, 3)
        tried = 0
        do {
            _ = try await config(.openAIChat, .off, base: "https://api.openai.com/v1").firstAccepted { _ in
                tried += 1
                throw HTTPFailure(status: 400, body: "maximum context length exceeded")
            }
        } catch {}
        XCTAssertEqual(tried, 1, "a too long conversation is not a refused parameter")
    }

    func testOlderProfilesUseTheModelDefault() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"profiles":[{"name":"A"}]}"#.utf8))
        XCTAssertEqual(s.profile.mainThinking, .model)
        XCTAssertEqual(s.profile.subagentThinking, .model)
    }
}
