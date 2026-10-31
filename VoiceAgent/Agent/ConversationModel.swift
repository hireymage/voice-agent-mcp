import AVFoundation
import Observation
import UIKit

struct ChatItem: Identifiable, Hashable {
    enum Kind { case user, assistant, notice, error }
    let id = UUID()
    let kind: Kind
    var text: String
}

@MainActor @Observable
final class ConversationModel {
    enum Phase: Equatable {
        case idle, listening, hearing, transcribing, preparing, thinking, speaking

        var label: String {
            switch self {
            case .idle: tr("Tap the microphone to talk")
            case .listening: tr("Listening…")
            case .hearing: tr("Hearing you…")
            case .transcribing: tr("Transcribing…")
            case .preparing: tr("Getting ready…")
            case .thinking: tr("Thinking…")
            case .speaking: tr("Speaking…")
            }
        }
    }

    private(set) var items: [ChatItem] = []
    private(set) var phase = Phase.idle
    private(set) var micOn = false
    private(set) var carSession = false
    private var greeted = false
    private var live: LiveWork?
    private var liveItem: UUID?
    /// Finished utterances waiting to go out together: the user went on before the first one was transcribed.
    private var heardParts: [String] = []
    private var hearing = false
    private var hearingRound = 0
    /// What the model took for not meant for it. It stays on screen and goes along with the next spoken message.
    private var setAside = ""
    /// While Settings tries a speech service, what the microphone hears goes there and not to the agent.
    private var speechTest: (([Int16]?) -> Void)?

    private let store: SettingsStore
    private let audio = AudioIO()
    private var history: [ChatMessage] = []
    private var player: SpeechPlayer?
    private var turn: Task<Void, Never>?
    private var transcription: Task<Void, Never>?
    private var turnID = UUID()
    private var partial = ""
    private var turnRunning = false
    var isTurnRunning: Bool { turnRunning }
    private var turnSpeaking = false

    // What the current connections and soul were prepared from; a settings change prepares them again.
    private struct Prepared: Equatable { let profile: UUID; let mcp: [MCPServer]; let soul: SoulSettings; let revision: Int; let phone: [String] }
    private var prepared: Prepared?
    private var mcpTools: [BoundTool] = []
    private var soulPrompt = ""

    init(store: SettingsStore) {
        self.store = store
        audio.onEvent = { [weak self] in self?.handle($0) }
    }

    var settings: AppSettings { store.settings }

    // MARK: - Actions

    func newConversation() {
        dropLiveWork()
        interrupt()
        setAside = ""
        history = []
        items = []
        prepared = nil
        restAfterTurn()
    }

    func reloadSoul() { prepared = nil }

    /// A different agent does not continue another one's conversation.
    func switchProfile(to id: UUID) {
        guard id != settings.activeProfileID else { return }
        store.settings.activeProfileID = id
        startOver()
    }

    /// When the app opens, as in a new conversation: the agent speaks first, which also shows that everything has loaded.
    func greetOnce() {
        guard !greeted, settings.dataNoticeAccepted else { return }
        greeted = true
        if items.isEmpty, !turnRunning { startOver() }
    }

    /// A new conversation in which the agent speaks first. A failure to load shows here at once, not at the first question.
    func startOver() {
        newConversation()
        guard settings.profile.alwaysReady, settings.server(settings.main.serverID) != nil, !settings.main.model.isEmpty else { return }
        startTurn(AgentSetup.greeting(language: Localizer.speechLanguageName), shown: false)
    }

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Typed over speech: what was heard so far stays on screen, the typed message is its own.
        live?.cancel()
        live = nil
        liveItem = nil
        startTurn(t)
    }

    func interrupt() {
        transcription?.cancel()
        transcription = nil
        heardParts = []
        hearingRound += 1
        guard turnRunning else { return }
        turn?.cancel()
        player?.cancel()
        player = nil
        turnID = UUID()
        turnRunning = false
        audio.setSpeaking(false)
        // What was already said stays part of the conversation; unfinished tool work does not.
        let said = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { history.append(.assistant(said)) }
        restAfterTurn()
    }

    func toggleMic() {
        if micOn { stopListening() } else { startListening() }
    }

    /// CarPlay: speech in both directions. What was said can be read on the phone afterwards.
    func startCarSession() {
        carSession = true
        audio.car = true
        startListening()
    }

    func endCarSession() {
        guard carSession else { return }
        carSession = false
        interrupt()
        stopListening()
        audio.car = false
        audio.release()
    }

    /// What was said up to now still counts: a phrase in progress and one being transcribed go on to the agent.
    private func stopListening() {
        hearing = false
        let unfinished = audio.finishPhrase()
        micOn = false
        if turnRunning { interrupt() }
        audio.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        restAfterTurn()
        if !turnRunning, let unfinished {
            live?.stoppedSpeaking()
            transcribe(unfinished)
        } else if transcription != nil {
            phase = .transcribing
        } else if !sendHeard() {
            dropLiveWork()
        }
    }

    private func startListening() {
        Task {
            do {
                guard await AVAudioApplication.requestRecordPermission() else { throw AppError("Microphone access is off. Turn it on in iOS Settings.") }
                if settings.stt.kind == .apple, !(await AppleSTT.requestPermission()) { throw AppError("Speech recognition access is off. Turn it on in iOS Settings.") }
                audio.configure(silenceMs: settings.voice.silenceMs, sensitivity: settings.voice.sensitivity, phrases: settings.workWhileTalking && settings.subagentEnabled)
                try audio.ensureRunning(mic: true)
                micOn = true
                UIApplication.shared.isIdleTimerDisabled = !carSession
                restAfterTurn()
                if carSession { await audio.play(AudioFormats.listeningTone) }
            } catch {
                report(error)
            }
        }
    }

    func testSpeech(_ text: String, with service: TTSSettings) async throws {
        try audio.ensureRunning(mic: micOn)
        await audio.play(try await makeTTS(service).synthesize(text))
    }

    /// Listens until the first pause and returns what this service makes of it. The agent gets nothing;
    /// a conversation going on stops, and the microphone stays off afterwards.
    func testTranscription(with service: STTSettings, onHeard: @escaping () -> Void) async throws -> String {
        guard !carSession else { throw AppError(tr("Speech can't be tested during a car conversation.")) }
        finishTranscriptionTest(nil)
        guard await AVAudioApplication.requestRecordPermission() else { throw AppError("Microphone access is off. Turn it on in iOS Settings.") }
        if service.kind == .apple, !(await AppleSTT.requestPermission()) { throw AppError("Speech recognition access is off. Turn it on in iOS Settings.") }
        micOn = false
        interrupt()
        dropLiveWork()
        UIApplication.shared.isIdleTimerDisabled = false
        audio.stop()
        restAfterTurn()
        audio.configure(silenceMs: settings.voice.silenceMs, sensitivity: settings.voice.sensitivity, phrases: false)
        audio.resetDetector()
        try audio.ensureRunning(mic: true)
        defer { audio.stop() }
        let heard: [Int16]? = await withCheckedContinuation { continuation in
            speechTest = { continuation.resume(returning: $0) }
            #if DEBUG
            if let path = UserDefaults.standard.string(forKey: "autoSpeakFile"), let data = FileManager.default.contents(atPath: path) { feedForTesting(data) }
            #endif
        }
        guard let heard else { return "" }
        onHeard()
        return try await makeSTT(service).transcribe(wav: wavData(heard, sampleRate: PhraseDetector.sampleRate))
    }

    /// Enough listening: transcribes what has been said so far.
    func stopTranscriptionTest() { finishTranscriptionTest(audio.finishPhrase()) }

    /// Leaving the screen: nothing goes anywhere.
    func cancelTranscriptionTest() { finishTranscriptionTest(nil) }

    private func finishTranscriptionTest(_ heard: [Int16]?) {
        let finish = speechTest
        speechTest = nil
        finish?(heard)
    }

    // MARK: - Listening

    private func handle(_ event: PhraseDetector.Event) {
        if speechTest != nil {
            if case .ended(let pcm) = event { finishTranscriptionTest(pcm) }
            return
        }
        guard micOn else { return }
        switch event {
        case .started:
            if turnRunning {
                if !settings.voice.bargeIn { return }
                interrupt()
            }
            hearing = true
            phase = .hearing
            // Going on before the last words were transcribed is one message, not a new one that replaces them.
            if transcription != nil || !heardParts.isEmpty {
                live?.resumedSpeaking()
            } else {
                dropLiveWork()
                beginLiveWork()
            }
        case .phrase(let pcm):
            live?.heard(pcm)
        case .discarded:
            hearing = false
            if transcription != nil {
                phase = .transcribing
            } else if !sendHeard() {
                dropLiveWork()
                restAfterTurn()
            }
        case .ended(let pcm):
            if turnRunning { return } // voice interruption off: said over the assistant
            hearing = false
            live?.stoppedSpeaking()
            transcribe(pcm)
        }
    }

    private func transcribe(_ pcm: [Int16]) {
        phase = .transcribing
        let wav = wavData(pcm, sampleRate: PhraseDetector.sampleRate)
        let stt = makeSTT(settings.stt)
        let earlier = transcription
        let round = hearingRound
        var this: Task<Void, Never>?
        this = Task {
            await earlier?.value
            do {
                let text = try await stt.transcribe(wav: wav)
                guard round == hearingRound else { return }
                if !text.isEmpty { heardParts.append(text) }
            } catch {
                if round != hearingRound || isCancellation(error) { return }
                report(error)
            }
            guard transcription == this else { return } // more was said meanwhile; its transcription finishes the job
            transcription = nil
            if hearing {
                showWhatWasHeard()
            } else if !sendHeard() {
                dropLiveWork()
                restAfterTurn()
            }
        }
        transcription = this
    }

    private func showWhatWasHeard() {
        let text = heardParts.joined(separator: " ")
        guard !text.isEmpty else { return }
        live?.correctSaid(text)
        showLiveText(text)
    }

    /// Sends what has been heard, if anything.
    private func sendHeard() -> Bool {
        let text = heardParts.joined(separator: " ")
        guard !text.isEmpty else { return false }
        let earlier = setAside
        startTurn(text, sentWith: earlier)
        return true
    }

    #if DEBUG
    func hearForTesting(_ event: PhraseDetector.Event) {
        micOn = true
        handle(event)
    }

    func feedForTesting(_ data: Data) {
        audio.ignoresMicrophone = true
        let pcm = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        Task.detached { [audio] in
            var at = 0
            while at < pcm.count {
                audio.feed(Array(pcm[at..<min(at + 320, pcm.count)]))
                at += 320
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
    #endif

    // MARK: - While the user talks

    private func beginLiveWork() {
        guard settings.workWhileTalking, settings.subagentEnabled, prepared == wantedPreparation else { return }
        let phone = PhoneTools.agentTools(enabled: settings.profilePhoneTools.filter(PhoneTools.readsOnly))
        let taken = Set(phone.map(\.def.name))
        let reading = phone + mcpTools.filter { $0.readOnly != false && !taken.contains($0.def.name) }.map { AgentTool.mcp($0) }
        let choice = settings.subagent.serverID == nil ? settings.main : settings.subagent
        guard !reading.isEmpty, let subagent = try? client(for: choice, missing: "") else { return }
        live = LiveWork(planner: subagent, subagent: subagent, tools: reading, stt: makeSTT(settings.stt), subagentInstructions: settings.subagentInstructions, onText: { [weak self] text in
            self?.showLiveText(text)
        })
    }

    private func showLiveText(_ text: String) {
        if let liveItem, let i = items.firstIndex(where: { $0.id == liveItem }) {
            items[i].text = text
        } else {
            let item = ChatItem(kind: .user, text: text)
            liveItem = item.id
            items.append(item)
        }
    }

    private func dropLiveWork() {
        live?.cancel()
        live = nil
        if let liveItem { items.removeAll { $0.id == liveItem } }
        liveItem = nil
    }

    private func restAfterTurn() {
        if turnRunning { return }
        phase = micOn ? .listening : .idle
    }

    // MARK: - One turn

    private func startTurn(_ text: String, shown: Bool = true, sentWith earlier: String = "") {
        let work = live
        let shownItem = liveItem
        live = nil
        liveItem = nil
        interrupt()
        let id = UUID()
        turnID = id
        partial = ""
        turnRunning = true
        var userItem: UUID?
        if let shownItem, let i = items.firstIndex(where: { $0.id == shownItem }) {
            items[i].text = text // what was heard piece by piece gives way to the transcript of the whole
            userItem = shownItem
        } else if shown {
            let item = ChatItem(kind: .user, text: text)
            items.append(item)
            userItem = item.id
        }
        let before = history
        let message = earlier.isEmpty ? text : earlier + " " + text
        setAside = ""
        history.append(.user(message))
        turn = Task { await runTurn(id: id, before: before, message: message, userItem: userItem, work: work) }
    }

    private func runTurn(id: UUID, before: [ChatMessage], message: String, userItem: UUID?, work: LiveWork?) async {
        defer { work?.cancel() }
        var answerItem: UUID?
        do {
            let spoken = settings.profile.speakReplies || carSession
            phase = .preparing
            let main = try client(for: settings.main, missing: "Choose the main agent's server and model in Settings.")
            try await prepare(main: main)
            guard id == turnID else { return }
            phase = .thinking
            if let work {
                let findings = await work.results(waitingAtMost: 20)
                guard id == turnID else { return }
                if !findings.isEmpty { history[history.count - 1].text += LiveWork.findingsNote(findings) }
            }

            if spoken {
                try audio.ensureRunning(mic: micOn)
                player = SpeechPlayer(audio: audio, tts: makeTTS(settings.tts)) { [weak self] message in
                    self?.report(AppError(tr("Text to speech: %@", message)))
                }
                audio.setSpeaking(true)
            }
            let splitter = SentenceSplitter()
            let system = AgentSetup.mainSystem(soul: soulPrompt, spoken: spoken, listening: micOn)
            let tools = try mainTools()
            let runner = AgentRunner(client: main, system: system, tools: tools, maxRounds: 8)
            let outcome = try await runner.run(messages: history, onText: { [weak self] delta in
                Task { @MainActor in
                    guard let self, id == self.turnID else { return }
                    self.partial += delta
                    answerItem = self.showAnswer(self.partial, in: answerItem)
                    if self.isSilentReply(self.partial) { return }
                    for sentence in splitter.push(delta) {
                        self.player?.say(sentence)
                        self.phase = .speaking
                    }
                }
            })
            // The text callbacks above were queued on this actor; let them land before the final pieces.
            await Task.yield()
            guard id == turnID else { return }

            if isSilentReply(outcome.text.isEmpty ? partial : outcome.text), micOn {
                history = before
                // A half-said sentence can look like this too, so nothing the user said disappears.
                if userItem != nil { setAside = String(message.suffix(2000)) }
                items.removeAll { $0.id == answerItem }
                player?.cancel()
                player = nil
            } else {
                history = outcome.messages
                answerItem = showAnswer(outcome.text, in: answerItem)
                for sentence in splitter.flush() {
                    player?.say(sentence)
                    phase = .speaking
                }
                await player?.finish()
            }
            guard id == turnID else { return }
        } catch {
            guard id == turnID else { return }
            // Starting anew helps only once: with no history left, it is the soul and tools that do not fit.
            if isContextLimit(error), !before.isEmpty {
                startAnew(from: history.last?.role == .user ? history[history.count - 1].text : message, userItem: userItem, answerItem: answerItem)
                return
            }
            if !isCancellation(error) { report(error) }
        }
        player = nil
        turnRunning = false
        audio.setSpeaking(false)
        audio.resetDetector()
        restAfterTurn()
    }

    /// The conversation no longer fits into the model: a new one with the user's last message. What was said stays on screen.
    private func startAnew(from message: String, userItem: UUID?, answerItem: UUID?) {
        player?.cancel()
        player = nil
        audio.setSpeaking(false)
        items.removeAll { $0.id == answerItem }
        let notice = ChatItem(kind: .notice, text: tr("The conversation no longer fit into the model, so a new one started with your last message."))
        items.insert(notice, at: items.firstIndex { $0.id == userItem } ?? items.endIndex)
        let id = UUID()
        turnID = id
        partial = ""
        history = [.user(message)]
        turn = Task { await runTurn(id: id, before: [], message: message, userItem: userItem, work: nil) }
    }

    /// Main agent's tools: with a subagent only `delegate`, without one the MCP tools themselves.
    private func mainTools() throws -> [AgentTool] {
        let phone = PhoneTools.agentTools(enabled: settings.profilePhoneTools)
        let taken = Set(phone.map(\.def.name))
        let available = phone + mcpTools.filter { !taken.contains($0.def.name) }.map { AgentTool.mcp($0) }
        guard settings.subagentEnabled else { return available }
        guard !available.isEmpty else { return [] }
        let choice = settings.subagent.serverID == nil ? settings.main : settings.subagent
        let sub = try client(for: choice, missing: "Choose the subagent's server and model in Settings.")
        let system = AgentSetup.subagentSystem(instructions: settings.subagentInstructions)
        let subTools = available
        let brief = settings.server(settings.main.serverID)?.api == .apple
        let delegate = AgentTool(def: AgentSetup.delegateDef(tools: subTools.map(\.def), brief: brief)) { arguments in
            let task = JSONValue.parse(arguments)?["task"]?.string ?? arguments
            do {
                let outcome = try await AgentRunner(client: sub, system: system, tools: subTools).run(messages: [.user(task)])
                return (outcome.text, false)
            } catch {
                return (error.localizedDescription, true)
            }
        }
        return [delegate]
    }

    private func client(for choice: ModelChoice, missing: String) throws -> LLMClient {
        guard let server = settings.server(choice.serverID), !choice.model.isEmpty else {
            throw AppError(missing)
        }
        return makeLLMClient(LLMConfig(api: server.api, baseURL: server.baseURL, apiKey: Keychain.get(server.keyAccount) ?? "", model: choice.model, extra: try parseExtraParams(choice.extraParams)))
    }

    private var wantedPreparation: Prepared {
        Prepared(profile: settings.activeProfileID, mcp: settings.profileMCP, soul: settings.profile.soul, revision: store.secretsRevision, phone: settings.profilePhoneTools)
    }

    /// Connects MCP and loads the soul, once per conversation and again after a settings change.
    private func prepare(main: LLMClient) async throws {
        let wanted = wantedPreparation
        if prepared == wanted { return }
        let store = self.store
        let servers = settings.profileMCP
        let headers = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, store.headers(of: $0)) })
        let result = await MCPTools.connect(servers) { headers[$0.id] ?? [:] }
        try Task.checkCancellation()
        mcpTools = result.tools
        for failure in result.failures { items.append(ChatItem(kind: .error, text: "MCP \(failure)")) }

        let soul = settings.profile.soul.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.profile.soul.loadViaMCP, !soul.isEmpty {
            soulPrompt = try await AgentSetup.loadSoul(instruction: soul, client: main, tools: mcpTools)
        } else {
            soulPrompt = soul
        }
        prepared = wanted
    }

    // MARK: - Showing

    private func isSilentReply(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && micOn && AgentSetup.silentReply.hasPrefix(t)
    }

    private func showAnswer(_ text: String, in item: UUID?) -> UUID? {
        if text.isEmpty || isSilentReply(text) { return item }
        let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let item, let i = items.firstIndex(where: { $0.id == item }) {
            items[i].text = shown
            return item
        }
        let new = ChatItem(kind: .assistant, text: shown)
        items.append(new)
        return new.id
    }

    private func report(_ error: Error) {
        items.append(ChatItem(kind: .error, text: error.localizedDescription))
        if carSession { Task { await audio.play(AudioFormats.problemTone) } }
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
