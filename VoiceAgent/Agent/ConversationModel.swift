import AVFoundation
import Observation
import UIKit

struct ChatItem: Identifiable, Hashable {
    enum Kind { case user, assistant, notice, error }
    let id = UUID()
    let kind: Kind
    var text: String

    /// The conversation as plain text to copy or share: what the user and the agent said, in order, each with who
    /// said it. Notices and errors of the app are left out.
    static func transcript(_ items: [ChatItem], user: String, agent: String) -> String {
        items.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch item.kind {
            case .user: return "\(user): \(text)"
            case .assistant: return "\(agent): \(text)"
            case .notice, .error: return nil
            }
        }.joined(separator: "\n\n")
    }
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
    /// The agent called end_conversation: the microphone turns off once its goodbye has been said.
    private var endAfterTurn = false
    private(set) var phase = Phase.idle
    private(set) var micOn = false
    private(set) var carSession = false
    private var greeted = false
    private var live: LiveWork? { didSet { if live == nil { liveSubagents = 0 } } }
    /// Subagents at work now, shown next to the state. One that was stopped no longer counts.
    var activeSubagents: Int { delegated.count + liveSubagents + workSubagents + queuedSubagents }
    private var delegated: Set<UUID> = []
    private var liveSubagents = 0
    /// Work started while the user talked, still finishing after the turn has taken it over.
    private var workSubagents = 0
    /// Subagents already looking up what a waiting message asks.
    private var queuedWork: LiveWork? { didSet { if queuedWork == nil { queuedSubagents = 0 } } }
    private var queuedSubagents = 0
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
    /// Interrupting on the first word: listens to the speech that started while the agent talks.
    private var wordWatch: Task<Void, Never>?
    private var wordWatchEnded: [Int16]?
    /// Messages that came while the agent was still working on the last one, before it said anything: that work,
    /// subagents included, goes on, and these go out together once it has answered.
    private var queued: [String] = []
    /// Subagents working in the background, and the reports of those that finished, waiting for a quiet moment.
    private var background: [UUID: Task<Void, Never>] = [:]
    private var reports: [String] = []
    /// The tasks of the subagents still at work, so the same one does not start twice.
    private var runningTasks: [UUID: String] = [:]
    /// The microphone was turned on while an answer was read aloud; it starts listening once the answer is done.
    private var micJoinPending = false
    /// The turn only passes on subagents' reports: the agent may stay silent, a report it no longer needs to tell.
    private var reportsOnlyTurn = false
    private var hearingOverWork = false
    /// How much the audio sounds like speech, 0…1; tests replace it.
    var speechConfidence: @Sendable ([Int16]) -> Double = { SpeechCheck.confidence($0) }
    private var turnID = UUID()
    private var partial = ""
    private var turnRunning = false
    var isTurnRunning: Bool { turnRunning }
    private var turnSpeaking = false

    // What the current connections and soul were prepared from; a settings change prepares them again.
    private struct Prepared: Equatable { let profile: UUID; let mcp: [MCPServer]; let soul: SoulSettings; let subagentSoul: SoulSettings; let revision: Int; let phone: [String] }
    private var prepared: Prepared?
    private var mcpTools: [BoundTool] = []
    /// The MCP tools the profile gives its agents; loading the soul sees them all.
    private var agentMCP: [BoundTool] {
        let profile = settings.profile
        return mcpTools.filter { t in t.serverID.map { profile.gets(tool: t.remoteName, of: $0) } ?? true }
    }
    private var soulPrompt = ""
    private var subagentPrompt = ""

    init(store: SettingsStore) {
        self.store = store
        audio.onEvent = { [weak self] in self?.handle($0) }
    }

    var settings: AppSettings { store.settings }

    // MARK: - Actions

    func newConversation() {
        dropLiveWork()
        interrupt()
        queued = []
        queuedWork?.cancel()
        queuedWork = nil
        background.values.forEach { $0.cancel() }
        background = [:]
        delegated = []
        runningTasks = [:]
        reports = []
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
        stopWordWatch()
        workSubagents = 0 // stopped work no longer counts, even while its request is still being torn down
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
        // Only listening stops: an answer being worked on or read aloud goes on, and the engine with it until it is
        // done (restAfterTurn stops it then). Stopping the answer is the stop button's job.
        if !turnRunning { audio.stop() }
        UIApplication.shared.isIdleTimerDisabled = false
        restAfterTurn()
        if let unfinished {
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
                // Turning the microphone on rebuilds the engine, which cut off the answer being read aloud, and the
                // agent's own voice then counted as the user speaking over it and stopped the work too. While an
                // answer is under way the microphone joins once it is done (restAfterTurn).
                if turnRunning, audio.running, !audio.listening {
                    micJoinPending = true
                } else {
                    try audio.ensureRunning(mic: true)
                }
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
            if turnRunning, partial.isEmpty {
                // Nothing said yet: this speech becomes the next message and the work on the last one goes on.
                hearingOverWork = true
            } else if turnRunning {
                if !settings.voice.bargeIn { return }
                if settings.voice.bargeInOnWord {
                    watchForWord()
                    return
                }
                interrupt()
            }
            hearing = true
            phase = .hearing
            // Going on before the last words were transcribed is one message, not a new one that replaces them.
            if turnRunning {
                // no work while talking for a message that waits for its turn
            } else if transcription != nil || !heardParts.isEmpty {
                live?.resumedSpeaking()
            } else {
                dropLiveWork()
                beginLiveWork()
            }
        case .phrase(let pcm):
            live?.heard(pcm)
        case .discarded:
            if turnRunning, wordWatch != nil {
                stopWordWatch()
                return
            }
            if turnRunning, hearingOverWork {
                hearingOverWork = false
                hearing = false
                if transcription == nil { phase = .thinking }
                return
            }
            hearing = false
            if transcription != nil {
                phase = .transcribing
            } else if !sendHeard() {
                dropLiveWork()
                restAfterTurn()
            }
        case .ended(let pcm):
            if turnRunning, !hearingOverWork {
                if wordWatch != nil { wordWatchEnded = pcm } // the watch makes the last check on all of it
                return // otherwise voice interruption is off: said over the assistant
            }
            let strict = hearingOverWork && settings.voice.bargeInOnWord
            hearingOverWork = false
            hearing = false
            live?.stoppedSpeaking()
            transcribe(pcm, onlySpeech: strict)
        }
    }

    /// The agent goes on talking while what is heard is transcribed every half second. The first word stops it and
    /// the speech goes on as a message; speech that ends without a word (a cough, noise) changes nothing.
    private func watchForWord() {
        stopWordWatch()
        let stt = makeSTT(settings.stt)
        let speech = speechConfidence
        let turn = turnID
        var this: Task<Void, Never>?
        this = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard turnRunning, turnID == turn, wordWatch == this else { return }
                let ended = wordWatchEnded
                guard let pcm = ended ?? audio.currentPhrase() else { continue }
                if ended == nil, pcm.count < PhraseDetector.sampleRate / 2 { continue }
                async let sounds = Task.detached { speech(pcm) }.value
                let text = (try? await stt.transcribe(wav: wavData(pcm, sampleRate: PhraseDetector.sampleRate))) ?? ""
                // Whisper writes whole sentences for noise, so the word counts only if the audio is speech too.
                let isSpeech = await sounds >= 0.5
                guard turnRunning, turnID == turn, wordWatch == this else { return }
                if AgentSetup.hasWords(text), isSpeech {
                    stopWordWatch()
                    interrupt()
                    if ended != nil {
                        heardParts = [text]
                        _ = sendHeard()
                    } else {
                        hearing = true
                        phase = .hearing
                        dropLiveWork()
                        beginLiveWork()
                    }
                    return
                }
                if ended != nil {
                    stopWordWatch()
                    return
                }
            }
        }
        wordWatch = this
    }

    private func stopWordWatch() {
        wordWatch?.cancel()
        wordWatch = nil
        wordWatchEnded = nil
    }

    /// `onlySpeech`: Whisper writes sentences for noise, so the text counts only if the audio sounds like speech.
    private func transcribe(_ pcm: [Int16], onlySpeech: Bool = false) {
        phase = .transcribing
        let wav = wavData(pcm, sampleRate: PhraseDetector.sampleRate)
        let stt = makeSTT(settings.stt)
        let speech = speechConfidence
        let earlier = transcription
        let round = hearingRound
        var this: Task<Void, Never>?
        this = Task {
            await earlier?.value
            do {
                let text = try await stt.transcribe(wav: wav)
                let isSpeech = !onlySpeech ? true : await Task.detached { AgentSetup.hasWords(text) && speech(pcm) >= 0.5 }.value
                guard round == hearingRound else { return }
                if !text.isEmpty, isSpeech { heardParts.append(text) }
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

    /// For watching the chat follow a growing answer on a simulator: a question and a long answer, a word at a time.
    func streamForTesting(_ text: String, every: Duration = .milliseconds(150)) async {
        items.append(ChatItem(kind: .user, text: "Tell me more."))
        var item: UUID?
        var shown = ""
        for word in text.split(separator: " ") {
            shown += (shown.isEmpty ? "" : " ") + word
            item = showAnswer(shown, in: item)
            try? await Task.sleep(for: every)
        }
    }
    #endif

    // MARK: - While the user talks

    private func beginLiveWork() {
        guard settings.workWhileTalking else { return }
        live = makeLiveWork()
        live?.onRunning = { [weak self] in self?.liveSubagents = $0 }
    }

    /// Subagents that start on what can be looked up before the main agent gets the message. Reading only.
    private func makeLiveWork() -> LiveWork? {
        guard settings.subagentEnabled, prepared == wantedPreparation else { return nil }
        let phone = PhoneTools.agentTools(enabled: settings.profilePhoneTools.filter(PhoneTools.readsOnly))
        let taken = Set(phone.map(\.def.name))
        let reading = phone + agentMCP.filter { $0.readOnly != false && !taken.contains($0.def.name) }.map { AgentTool.mcp($0) }
        let choice = settings.subagent.serverID == nil ? settings.main : settings.subagent
        guard !reading.isEmpty, let subagent = try? client(for: choice, thinking: settings.profile.subagentThinking, missing: "") else { return nil }
        return LiveWork(planner: subagent, subagent: subagent, tools: reading, stt: makeSTT(settings.stt), subagentInstructions: subagentPrompt, lazy: settings.subagentLoadsToolsOnDemand, onText: { [weak self] text in
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
        // The microphone went off while the agent was answering: the engine that listened stops once it is done.
        if !turnRunning, !micOn, speechTest == nil, audio.listening { audio.stop() }
        // The microphone went on while the agent was answering: it starts listening now that the answer is done.
        if micJoinPending, !turnRunning {
            micJoinPending = false
            if micOn {
                do {
                    try audio.ensureRunning(mic: true)
                } catch {
                    micOn = false
                    report(error)
                }
            }
        }
        if turnRunning {
            if phase == .hearing || phase == .transcribing { phase = .thinking } // speech over the work led to nothing
            return
        }
        if !hearing, transcription == nil { phase = micOn ? .listening : .idle }
        sendWhatWaits()
    }

    // MARK: - One turn

    private func startTurn(_ text: String, shown: Bool = true, sentWith earlier: String = "") {
        // Nothing answered yet: the work on the last message goes on and this one waits for its turn.
        if turnRunning, partial.isEmpty, shown {
            dropLiveWork()
            items.append(ChatItem(kind: .user, text: text))
            queued.append(earlier.isEmpty ? text : earlier + " " + text)
            setAside = ""
            phase = .thinking
            // Its own subagents start now, beside the ones still working on the earlier message.
            if queuedWork == nil {
                queuedWork = makeLiveWork()
                queuedWork?.onRunning = { [weak self] in self?.queuedSubagents = $0 }
            }
            queuedWork?.consider(queued.joined(separator: "\n\n"))
            return
        }
        let work = live
        let shownItem = liveItem
        live = nil
        liveItem = nil
        interrupt()
        reportsOnlyTurn = text.isEmpty && earlier.isEmpty && queued.isEmpty && !reports.isEmpty
        work?.onRunning = { [weak self] in self?.workSubagents = $0 }
        let id = UUID()
        turnID = id
        partial = ""
        turnRunning = true
        endAfterTurn = false
        var userItem: UUID?
        if let shownItem, let i = items.firstIndex(where: { $0.id == shownItem }) {
            items[i].text = text // what was heard piece by piece gives way to the transcript of the whole
            userItem = shownItem
        } else if shown {
            let item = ChatItem(kind: .user, text: text)
            items.append(item)
            userItem = item.id
        }
        var message = earlier.isEmpty ? text : earlier + " " + text
        if !queued.isEmpty {
            message = (queued + [message]).joined(separator: "\n\n")
            queued = []
        }
        if !reports.isEmpty {
            message = AgentSetup.backgroundReports(reports) + (message.isEmpty ? "" : "\n\n" + message)
            reports = []
        }
        message = AgentSetup.stamped(message)
        // The last message got no answer before this one stopped the work on it (Stop, or speaking over it): both go
        // as one message, or the model answers only the newer one (and some APIs refuse two user messages in a row).
        if history.last?.role == .user {
            message = history.removeLast().text + "\n\n" + message
        }
        let before = history
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
            let main = try client(for: settings.main, thinking: settings.profile.mainThinking, missing: "Choose the main agent's server and model in Settings.")
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

            if isSilentReply(outcome.text.isEmpty ? partial : outcome.text) {
                if reportsOnlyTurn {
                    // The agent knows it got the reports and chose not to tell them; the conversation keeps that.
                    history = outcome.messages
                } else {
                    history = before
                    // A half-said sentence can look like this too, so nothing the user said disappears.
                    if userItem != nil { setAside = String(AgentSetup.unstamped(message).suffix(2000)) }
                }
                items.removeAll { $0.id == answerItem }
                player?.cancel()
                player = nil
            } else {
                history = outcome.messages
                // Everything that was read aloud stays on screen, the text of earlier tool rounds too.
                answerItem = showAnswer(partial.isEmpty ? outcome.text : partial, in: answerItem)
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
        // The goodbye has been said. A message the user finished meanwhile started a new turn, and that keeps the call going.
        if endAfterTurn, micOn, !turnRunning { endByVoice() }
    }

    /// The agent said goodbye: the microphone turns off, and what it picked up during the goodbye (its own echo, noise,
    /// a phrase cut short) is dropped instead of being sent.
    private func endByVoice() {
        endAfterTurn = false
        interrupt()
        hearing = false
        _ = audio.finishPhrase()
        dropLiveWork()
        micOn = false
        audio.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        items.append(ChatItem(kind: .notice, text: tr("The conversation ended. Tap the microphone to talk again.")))
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

    /// The main agent's own tool for ending the spoken conversation; it stays with the main agent, never the subagent.
    private var endTools: [AgentTool] {
        guard settings.voice.endByVoice, micOn else { return [] }
        return [AgentTool(def: AgentSetup.endDef, finishes: true) { [weak self] _ in
            await self?.endAfterThisTurn()
            return (AgentSetup.endAccepted, false)
        }]
    }

    private func endAfterThisTurn() { endAfterTurn = true }

    /// Main agent's tools: with a subagent only `delegate`, without one the MCP tools themselves.
    private func mainTools() throws -> [AgentTool] {
        let phone = PhoneTools.agentTools(enabled: settings.profilePhoneTools)
        let taken = Set(phone.map(\.def.name))
        let available = phone + agentMCP.filter { !taken.contains($0.def.name) }.map { AgentTool.mcp($0) }
        guard settings.subagentEnabled else { return available + endTools }
        guard !available.isEmpty else { return endTools }
        let choice = settings.subagent.serverID == nil ? settings.main : settings.subagent
        let sub = try client(for: choice, thinking: settings.profile.subagentThinking, missing: "Choose the subagent's server and model in Settings.")
        let system = AgentSetup.subagentSystem(instructions: subagentPrompt)
        let subTools = available
        let lazy = settings.subagentLoadsToolsOnDemand
        let brief = settings.server(settings.main.serverID)?.api == .apple
        let delegate = AgentTool(def: AgentSetup.delegateDef(tools: subTools.map(\.def), brief: brief)) { [weak self] arguments in
            let task = JSONValue.parse(arguments)?["task"]?.string ?? arguments
            guard let self else { return (AgentSetup.delegateStarted, false) }
            if await self.isRunning(task) { return (AgentSetup.delegateAlreadyRunning, false) }
            let others = await Array(self.runningTasks.values)
            // The main agent does not wait: it answers the user, and the report comes later as its own message.
            await self.startInBackground(task, runner: AgentRunner(client: sub, system: system, tools: subTools, lazy: lazy))
            return (AgentSetup.delegateStarted(alsoRunning: others), false)
        }
        // A small model may call one of the subagent's tools itself, knowing it by name from the description of
        // `delegate`; the call goes to the subagent as its task instead of failing or showing up as text.
        let redirects = subTools.map { tool in
            AgentTool(def: tool.def, hidden: true) { [weak self] arguments in
                guard let self else { return (AgentSetup.delegateStarted, false) }
                let asked = await self.lastUserWords
                let task = "The user said: \(asked)\nDo what they asked. Start with the tool \(tool.def.name) and the arguments \(arguments.isEmpty ? "{}" : arguments), and report the result."
                if await self.isRunning(task) { return (AgentSetup.delegateAlreadyRunning, false) }
                let others = await Array(self.runningTasks.values)
                await self.startInBackground(task, runner: AgentRunner(client: sub, system: system, tools: subTools, lazy: lazy))
                return (AgentSetup.delegateStarted(alsoRunning: others), false)
            }
        }
        return [delegate] + endTools + redirects
    }

    /// The last thing the user said, without the clock readings.
    private var lastUserWords: String {
        AgentSetup.unstamped(history.last { $0.role == .user }?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same task, apart from case and spacing, is already at work.
    private func isRunning(_ task: String) -> Bool {
        let key = Self.taskKey(task)
        return runningTasks.values.contains { Self.taskKey($0) == key }
    }

    private static func taskKey(_ task: String) -> String {
        task.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func startInBackground(_ task: String, runner: AgentRunner) {
        let run = UUID()
        delegated.insert(run)
        runningTasks[run] = task
        background[run] = Task { [weak self] in
            var report: String
            do {
                report = try await runner.run(messages: [.user(AgentSetup.stamped(task))]).text
            } catch {
                report = tr("Failed: %@", error.localizedDescription)
            }
            guard let self, !Task.isCancelled else { return }
            self.delegated.remove(run)
            self.runningTasks[run] = nil
            self.background[run] = nil
            self.reports.append("Task: \(task)\nReport: \(report)")
            self.restAfterTurn()
        }
    }

    /// Reports and waiting messages go to the main agent when nobody is talking and nothing is being said.
    private func sendWhatWaits() {
        guard !turnRunning, !hearing, transcription == nil, !queued.isEmpty || !reports.isEmpty else { return }
        let next = queued.joined(separator: "\n\n")
        queued = []
        live = queuedWork // what its subagents found goes with it
        queuedWork = nil
        startTurn(next, shown: false)
    }

    private func client(for choice: ModelChoice, thinking: Thinking, missing: String) throws -> LLMClient {
        guard let server = settings.server(choice.serverID), !choice.model.isEmpty else {
            throw AppError(missing)
        }
        return makeLLMClient(LLMConfig(api: server.api, baseURL: server.baseURL, apiKey: Keychain.get(server.keyAccount) ?? "", model: choice.model, extra: try parseExtraParams(choice.extraParams), thinking: thinking))
    }

    private var wantedPreparation: Prepared {
        Prepared(profile: settings.activeProfileID, mcp: settings.profileMCP, soul: settings.profile.soul, subagentSoul: settings.profile.subagentSoul, revision: store.secretsRevision, phone: settings.profilePhoneTools)
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
        let subagentSoul = settings.profile.subagentSoul
        let subText = subagentSoul.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if subagentSoul.loadViaMCP, !subText.isEmpty, settings.subagentEnabled {
            let choice = settings.subagent.serverID == nil ? settings.main : settings.subagent
            let sub = (try? client(for: choice, thinking: settings.profile.subagentThinking, missing: "")) ?? main
            subagentPrompt = try await AgentSetup.loadSoul(instruction: subText, client: sub, tools: mcpTools)
        } else {
            subagentPrompt = subagentSoul.loadViaMCP ? "" : subText
        }
        prepared = wanted
    }

    // MARK: - Showing

    private func isSilentReply(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && (micOn || reportsOnlyTurn) && AgentSetup.silentReply.hasPrefix(t)
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
