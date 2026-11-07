import SwiftUI

/// One conversation for the phone and the car.
@MainActor
enum AppModel {
    static let store = SettingsStore()
    static let conversation = ConversationModel(store: store)
}

@main
struct VoiceAgentApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(store: AppModel.store, conversation: AppModel.conversation)
        }
    }
}

/// Everything below follows the language chosen in Settings, at once and without a restart.
private struct RootView: View {
    @Bindable var store: SettingsStore
    let conversation: ConversationModel

    var body: some View {
        screen
            .environment(\.locale, Locale(identifier: languageCode))
            .background(KeyboardDismissal())
            .task(id: store.settings.dataNoticeAccepted) { if greetsOnOpen { conversation.greetOnce() } }
            .sheet(isPresented: Binding(get: { !store.settings.dataNoticeAccepted }, set: { _ in })) {
                DataNoticeView { store.settings.dataNoticeAccepted = true }
                    .environment(\.locale, Locale(identifier: languageCode))
                    .interactiveDismissDisabled()
            }
    }

    private var greetsOnOpen: Bool {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "demoScreen") != nil || UserDefaults.standard.string(forKey: "autoSend") != nil || UserDefaults.standard.string(forKey: "autoMicSend") != nil { return false }
        #endif
        return true
    }

    @ViewBuilder private var screen: some View {
        #if DEBUG
        // For the store screenshots: -demoScreen settings|servers|profile|phone|tools
        switch UserDefaults.standard.string(forKey: "demoScreen") {
        case "settings": SettingsView(store: store, conversation: conversation)
        case "servers": NavigationStack { LLMServersView(store: store) }
        case "profile": NavigationStack { ProfileEditor(store: store, conversation: conversation, profile: $store.settings.profiles[0]) }
        case "phone": NavigationStack { PhoneToolsView(store: store) }
        case "tools": NavigationStack { MCPServerEditor(store: store, server: $store.settings.mcp[0], connectAtOnce: true) }
        case "stt": NavigationStack { STTEditor(service: $store.settings.sttServices[0], conversation: conversation) }
        default: ChatView(store: store, conversation: conversation)
        }
        #else
        ChatView(store: store, conversation: conversation)
        #endif
    }

    private var languageCode: String {
        _ = store.settings.language
        return Localizer.code
    }
}

/// Before anything is sent anywhere: the app has no server of its own, the user's chosen services get the data.
private struct DataNoticeView: View {
    let accept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "hand.raised.fill").font(.largeTitle).foregroundStyle(.tint)
            Text("Your data goes to the services you choose").font(.title2.bold())
            Text("Voice Agent has no server of its own. What you type or say, and what your tools return, is sent only to the AI model, speech and MCP services you set up, under their own privacy terms.")
            Text("Nothing goes to an AI service until you add one. Apple speech recognition, if you use it, follows Apple's terms. API keys stay in the Keychain on this iPhone.")
            Spacer()
            Button(action: accept) {
                Text("I understand").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
    }
}

struct ChatView: View {
    let store: SettingsStore
    let conversation: ConversationModel
    @State private var draft = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messages
                Divider()
                bottomBar
            }
            .navigationTitle("Voice Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New conversation", systemImage: "square.and.pencil") { conversation.startOver() }
                }
                ToolbarItem(placement: .principal) { profileMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: store, conversation: conversation)
            }
            #if DEBUG
            .task {
                // For trying a conversation on a simulator that cannot type: -autoSend "message"
                if let text = UserDefaults.standard.string(forKey: "autoSend") { conversation.send(text) }
                // Real speech as if from the microphone, for the simulator: -autoSpeakFile <16 kHz mono 16-bit raw PCM>
                if let path = UserDefaults.standard.string(forKey: "autoSpeakFile"), let data = FileManager.default.contents(atPath: path) {
                    conversation.greetOnce()
                    while conversation.isTurnRunning || conversation.phase == .idle && !conversation.micOn {
                        if !conversation.isTurnRunning, !conversation.micOn { conversation.toggleMic() }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    try? await Task.sleep(for: .seconds(1))
                    conversation.feedForTesting(data)
                }
                // The same with the microphone on: -autoMicSend "message"
                if let text = UserDefaults.standard.string(forKey: "autoMicSend") {
                    conversation.toggleMic()
                    try? await Task.sleep(for: .seconds(2))
                    conversation.send(text)
                }
            }
            #endif
        }
    }

    private var profileMenu: some View {
        Menu {
            Picker("Profile", selection: Binding(get: { store.settings.activeProfileID }, set: { conversation.switchProfile(to: $0) })) {
                ForEach(store.settings.profiles) { Text(verbatim: $0.displayName).tag($0.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: store.settings.profile.displayName).font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.primary)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a lazy stack guesses the heights of rows it has not laid out, and a growing answer then
                // makes the content jump up and down. A conversation lives only until the app closes.
                VStack(spacing: 10) {
                    if conversation.items.isEmpty { emptyHint }
                    ForEach(conversation.items) { item in
                        ChatBubble(item: item).id(item.id)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .modifier(FollowsTheEnd(itemCount: conversation.items.count, lastText: conversation.items.last?.text ?? "", lastID: conversation.items.last?.id, proxy: proxy))
        }
    }

    @ViewBuilder private var emptyHint: some View {
        let ready = store.settings.server(store.settings.main.serverID) != nil && !store.settings.main.model.isEmpty
        ContentUnavailableView {
            Label(ready ? "Ready" : "Set up a model", systemImage: ready ? "waveform" : "gearshape")
        } description: {
            Text(ready ? "Talk to the agent or type a message." : "Add an LLM server and choose the main agent's model in Settings.")
        } actions: {
            if !ready { Button("Open Settings") { showSettings = true } }
        }
        .padding(.top, 60)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text(verbatim: conversation.phase.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .overlay(alignment: .leading) {
                    if store.settings.subagentEnabled { SubagentCount(count: conversation.activeSubagents) }
                }
            HStack(spacing: 10) {
                MultilineField(title: "Message", text: $draft)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(.separator)))
                if !draft.isEmpty {
                    Button("Send", systemImage: "arrow.up.circle.fill", action: sendDraft)
                        .labelStyle(.iconOnly)
                        .font(.title)
                }
                if isBusy {
                    Button("Stop", systemImage: "stop.circle.fill") { conversation.interrupt() }
                        .labelStyle(.iconOnly)
                        .font(.title)
                        .tint(.orange)
                }
                Button(conversation.micOn ? "Stop listening" : "Start listening", systemImage: conversation.micOn ? "mic.fill" : "mic") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    conversation.toggleMic()
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .frame(width: 48, height: 48)
                .background(conversation.micOn ? Color.red : Color.accentColor, in: Circle())
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var isBusy: Bool {
        switch conversation.phase {
        case .preparing, .thinking, .speaking: true
        default: false
        }
    }

    private func sendDraft() {
        conversation.send(draft)
        draft = ""
    }
}

/// Keeps the end of the conversation in view while an answer grows, without scrolling for every piece of text:
/// the scroll view itself holds on to the end. Someone who scrolled up to read is left there until they come back.
private struct FollowsTheEnd: ViewModifier {
    let itemCount: Int
    let lastText: String
    let lastID: UUID?
    let proxy: ScrollViewProxy
    @State private var atEnd = true
    @State private var dragStart: CGFloat?

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .defaultScrollAnchor(atEnd ? .bottom : .top, for: .sizeChanges)
                // Only a finger decides, and only by really scrolling up. A new bubble makes the content longer for a
                // moment before the view follows, and a tap (say, to put the keyboard away) moves nothing; judging by
                // either switched following off for good.
                .onScrollPhaseChange { old, new, context in
                    let g = context.geometry
                    if old == .idle, new != .idle, new != .animating { dragStart = g.contentOffset.y }
                    guard new == .idle, [.tracking, .interacting, .decelerating].contains(old) else { return }
                    let nearEnd = g.contentOffset.y + g.containerSize.height - g.contentInsets.bottom >= g.contentSize.height - 80
                    if nearEnd {
                        atEnd = true
                    } else if let start = dragStart, g.contentOffset.y < start - 40 {
                        atEnd = false
                    }
                    dragStart = nil
                }
                .onChange(of: itemCount) { scrollToEnd() }
        } else {
            content.onChange(of: lastText) { scrollToEnd() }.onChange(of: itemCount) { scrollToEnd() }
        }
    }

    /// After the new bubble has been laid out, so the scroll goes to where it really ends.
    private func scrollToEnd() {
        atEnd = true
        guard let lastID else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

/// How many subagents are at work: grey at zero, in colour while any are.
private struct SubagentCount: View {
    let count: Int

    var body: some View {
        Text(verbatim: "\(count)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(count > 0 ? Color.white : Color.secondary)
            .frame(width: 20, height: 20)
            .background(Circle().fill(count > 0 ? Color.accentColor : Color(.tertiarySystemFill)))
            .animation(.default, value: count)
            .accessibilityLabel(Text("Subagents at work: \(count)"))
    }
}

struct ChatBubble: View {
    let item: ChatItem

    /// Models write bold, links and the like in Markdown; a reply that is not valid Markdown is shown as it is.
    private var formatted: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: item.text, options: options)) ?? AttributedString(item.text)
    }

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(verbatim: item.text)
                    .padding(10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack {
                Text(formatted)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)
                Spacer(minLength: 40)
            }
        case .notice:
            Text(verbatim: item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        case .error:
            Label { Text(verbatim: item.text) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
