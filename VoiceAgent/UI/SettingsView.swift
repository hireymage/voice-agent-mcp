import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Bindable var store: SettingsStore
    let conversation: ConversationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Picker("Language", selection: $store.settings.language) {
                        ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                }
                Section("Models") {
                    row("LLM servers", value: "\(store.settings.servers.count)") { LLMServersView(store: store) }
                    row("Main agent", value: store.settings.main.model) {
                        Form {
                            ModelChoiceSection(store: store, choice: $store.settings.main, title: "Main agent", sameAsMain: false)
                        }
                        .navigationTitle("Main agent")
                    }
                    row("Subagent", value: subagentBadge) { SubagentView(store: store) }
                }
                Section {
                    row("iPhone", value: "\(store.settings.phoneTools.count)") { PhoneToolsView(store: store) }
                    row("MCP servers", value: "\(store.settings.mcp.count)") { MCPServersView(store: store) }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("The agent's only tools are the ones on these servers. Each profile chooses which of them it loads.")
                }
                Section("Agent") {
                    row("Profiles", value: store.settings.profile.displayName) { ProfilesView(store: store, conversation: conversation) }
                }
                Section("Voice") {
                    row("Speech to text", value: store.settings.stt.displayName) { STTView(store: store, conversation: conversation) }
                    row("Text to speech", value: store.settings.tts.displayName) { TTSView(store: store, conversation: conversation) }
                    NavigationLink("Conversation") { VoiceOptionsView(store: store) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .id(store.settings.language)
    }

    private func row<Destination: View>(_ title: LocalizedStringKey, value: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            LabeledContent(title) { Text(verbatim: value).lineLimit(1) }
        }
    }

    private var subagentBadge: String {
        guard store.settings.subagentEnabled else { return tr("Off") }
        return store.settings.subagent.serverID == nil ? tr("Same as main") : store.settings.subagent.model
    }
}

// MARK: - LLM servers

struct LLMServersView: View {
    @Bindable var store: SettingsStore
    @State private var added: UUID?

    var body: some View {
        List {
            ForEach($store.settings.servers) { $server in
                NavigationLink {
                    LLMServerEditor(store: store, server: $server)
                } label: {
                    VStack(alignment: .leading) {
                        Text(verbatim: server.name.isEmpty ? tr("Unnamed") : server.name)
                        Text(verbatim: server.api.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets {
                    let server = store.settings.servers[i]
                    Keychain.set(server.keyAccount, "")
                    if store.settings.main.serverID == server.id { store.settings.main = ModelChoice() }
                    if store.settings.subagent.serverID == server.id { store.settings.subagent = ModelChoice() }
                }
                store.settings.servers.remove(atOffsets: offsets)
            }
        }
        .overlay {
            if store.settings.servers.isEmpty {
                ContentUnavailableView("No servers", systemImage: "server.rack", description: Text("Add OpenAI, Anthropic, Gemini or any compatible server."))
            }
        }
        .navigationTitle("LLM servers")
        .toolbar {
            Menu("Add", systemImage: "plus") {
                ForEach(LLMPreset.all) { preset in
                    Button(tr(preset.name)) {
                        let custom = preset.url.isEmpty && preset.api != .apple
                        let server = LLMServer(name: custom ? "" : tr(preset.name), api: preset.api, baseURL: preset.url)
                        store.settings.servers.append(server)
                        added = server.id
                    }
                }
            }
        }
        .navigationDestination(item: $added) { id in
            if let i = store.settings.servers.firstIndex(where: { $0.id == id }) {
                LLMServerEditor(store: store, server: $store.settings.servers[i])
            }
        }
    }
}

struct LLMServerEditor: View {
    let store: SettingsStore
    @Binding var server: LLMServer
    @State private var key = ""
    @State private var models: [String] = []
    @State private var status = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $server.name)
                Picker("API", selection: $server.api) {
                    ForEach(LLMAPI.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                if server.api != .apple {
                    TextField("Base URL", text: $server.baseURL, prompt: Text("http://host:port/v1"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API key (optional for local servers)", text: $key)
                        .onChange(of: key) { _, value in Keychain.set(server.keyAccount, value) }
                }
            }
            Section {
                Button(testing ? "Connecting…" : "Test connection") { test() }
                    .disabled(testing)
                if !status.isEmpty { Text(verbatim: status).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("A test asks the server for its list of models.")
            }
            if !models.isEmpty {
                Section {
                    ForEach(models, id: \.self) { name in
                        Menu {
                            Button("Use for main agent") { use(name, as: \.main) }
                            if store.settings.subagentEnabled {
                                Button("Use for subagent") { use(name, as: \.subagent) }
                            }
                        } label: {
                            LabeledContent {
                                Text(verbatim: usage(of: name))
                            } label: {
                                Text(verbatim: name).font(.footnote).foregroundStyle(.primary)
                            }
                        }
                    }
                } header: {
                    Text("Models on this server")
                } footer: {
                    Text("Tap a model to use it.")
                }
            }
        }
        .navigationTitle(server.name.isEmpty ? tr("New server") : server.name)
        .onAppear { key = Keychain.get(server.keyAccount) ?? "" }
    }

    private func use(_ model: String, as role: WritableKeyPath<AppSettings, ModelChoice>) {
        store.settings[keyPath: role].serverID = server.id
        store.settings[keyPath: role].model = model
    }

    private func usage(of model: String) -> String {
        func uses(_ choice: ModelChoice) -> Bool { choice.serverID == server.id && choice.model == model }
        let names = [uses(store.settings.main) ? tr("Main") : nil, store.settings.subagentEnabled && uses(store.settings.subagent) ? tr("Subagent") : nil]
        return names.compactMap { $0 }.joined(separator: ", ")
    }

    private func test() {
        testing = true
        status = ""
        Task {
            do {
                models = try await listModels(api: server.api, baseURL: server.baseURL, apiKey: key)
                status = tr("Connected. Models: %d.", models.count)
            } catch {
                models = []
                status = error.localizedDescription
            }
            testing = false
        }
    }
}

struct ModelChoiceSection: View {
    let store: SettingsStore
    @Binding var choice: ModelChoice
    let title: LocalizedStringKey
    let sameAsMain: Bool

    var body: some View {
        Section(title) {
            Picker("Server", selection: $choice.serverID) {
                Text(sameAsMain ? "Same as main agent" : "None").tag(UUID?.none)
                ForEach(store.settings.servers) { Text(verbatim: $0.name.isEmpty ? tr("Unnamed") : $0.name).tag(UUID?.some($0.id)) }
            }
            if let server = store.settings.server(choice.serverID) {
                NavigationLink {
                    ModelPickerView(server: server, model: $choice.model)
                } label: {
                    LabeledContent("Model", value: choice.model.isEmpty ? tr("Choose") : choice.model)
                }
            } else if !sameAsMain {
                Text(store.settings.servers.isEmpty ? "Add a server under LLM servers first." : "Choose a server to see its models.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: choice.serverID) { choice.model = "" }
        .onAppear {
            // The main agent needs a server, and with only one there is nothing to ask.
            if !sameAsMain, choice.serverID == nil, store.settings.servers.count == 1 {
                choice.serverID = store.settings.servers[0].id
            }
        }
        if choice.serverID != nil {
            Section {
                MultilineField(title: "{\"temperature\": 0.3}", text: $choice.extraParams, lines: 1...8, literal: true)
            } header: {
                Text("Extra request parameters")
            } footer: {
                Text("Optional JSON merged into each request, for example reasoning_effort, max_tokens or chat_template_kwargs.")
            }
        }
    }
}

struct ModelPickerView: View {
    let server: LLMServer
    @Binding var model: String
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String] = []
    @State private var query = ""
    @State private var status = tr("Loading models…")
    @State private var typed = ""

    var body: some View {
        List {
            Section("Type a model name") {
                HStack {
                    TextField("Model ID", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use") { model = typed.trimmingCharacters(in: .whitespaces); dismiss() }
                        .buttonStyle(.borderless)
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section(status) {
                ForEach(models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { name in
                    Button {
                        model = name
                        dismiss()
                    } label: {
                        HStack {
                            Text(verbatim: name).foregroundStyle(.primary)
                            Spacer()
                            if name == model { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Model")
        .task {
            typed = model
            do {
                models = try await listModels(api: server.api, baseURL: server.baseURL, apiKey: Keychain.get(server.keyAccount) ?? "")
                status = tr("On this server")
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

struct SubagentView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Use a subagent", isOn: $store.settings.subagentEnabled)
            } footer: {
                Text(store.settings.subagentEnabled
                     ? "The main agent hands work to the subagent, and only the subagent uses the MCP tools."
                     : "The main agent uses the MCP tools itself.")
            }
            if store.settings.subagentEnabled {
                ModelChoiceSection(store: store, choice: $store.settings.subagent, title: "Model", sameAsMain: true)
                Section {
                    MultilineField(title: "Optional", text: $store.settings.subagentInstructions, lines: 3...10)
                } header: {
                    Text("Extra instructions for the subagent")
                }
            }
        }
        .navigationTitle("Subagent")
    }
}

// MARK: - MCP

struct MCPServersView: View {
    @Bindable var store: SettingsStore
    @State private var importing = false
    @State private var added: UUID?

    var body: some View {
        List {
            ForEach($store.settings.mcp) { $server in
                NavigationLink {
                    MCPServerEditor(store: store, server: $server)
                } label: {
                    VStack(alignment: .leading) {
                        Text(verbatim: server.name.isEmpty ? tr("Unnamed") : server.name)
                        Text(verbatim: server.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets { store.setHeaders([:], of: store.settings.mcp[i]) }
                for i in offsets {
                    let id = store.settings.mcp[i].id
                    for p in store.settings.profiles.indices { store.settings.profiles[p].mcpServers.removeAll { $0 == id } }
                }
                store.settings.mcp.remove(atOffsets: offsets)
            }
        }
        .overlay {
            if store.settings.mcp.isEmpty {
                ContentUnavailableView("No MCP servers", systemImage: "wrench.and.screwdriver", description: Text("Without MCP the agent has no tools."))
            }
        }
        .navigationTitle("MCP servers")
        .toolbar {
            Menu("Add", systemImage: "plus") {
                Button("Add server") {
                    let server = MCPServer()
                    store.settings.mcp.append(server)
                    store.settings.addToActiveProfile(server)
                    added = server.id
                }
                Button("Import mcp.json") { importing = true }
            }
        }
        .sheet(isPresented: $importing) { MCPImportView(store: store) }
        .navigationDestination(item: $added) { id in
            if let i = store.settings.mcp.firstIndex(where: { $0.id == id }) {
                MCPServerEditor(store: store, server: $store.settings.mcp[i])
            }
        }
    }
}

struct MCPImportView: View {
    let store: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PlainTextEditor(text: $text, literal: true)
                        .frame(minHeight: 200)
                } header: {
                    Text("Paste mcp.json")
                } footer: {
                    Text("HTTP servers are added with their headers, which are stored in the Keychain. Local (command) servers cannot run on iPhone and are skipped.")
                }
                if !result.isEmpty { Text(verbatim: result).font(.footnote) }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            let r = try store.importMCP(json: text)
                            text = ""
                            result = tr("Added: %@", r.added.joined(separator: ", "))
                            if !r.skipped.isEmpty { result += "\n" + tr("Skipped: %@", r.skipped.joined(separator: ", ")) }
                        } catch {
                            result = error.localizedDescription
                        }
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
    }
}

struct MCPServerEditor: View {
    let store: SettingsStore
    @Binding var server: MCPServer
    #if DEBUG
    var connectAtOnce = false
    #endif
    @State private var headers: [HeaderRow] = []
    @State private var tools: [MCPTool] = []
    @State private var status = ""
    @State private var testing = false

    struct HeaderRow: Identifiable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $server.name)
                TextField("URL", text: $server.url, prompt: Text("https://host/mcp"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            Section {
                ForEach($headers) { $row in
                    VStack {
                        TextField("Header name", text: $row.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Value", text: $row.value)
                    }
                }
                .onDelete { headers.remove(atOffsets: $0); saveHeaders() }
                Button("Add header") { headers.append(HeaderRow(name: "Authorization")) }
            } header: {
                Text("Headers")
            } footer: {
                Text("For a bearer token use the name Authorization and the value Bearer followed by the token. Stored in the Keychain.")
            }
            .onChange(of: headers.map { "\($0.name)\u{0}\($0.value)" }) { saveHeaders() }
            Section {
                Button(testing ? "Connecting…" : "Connect and list tools") { test() }
                    .disabled(testing || server.url.isEmpty)
                if !status.isEmpty { Text(verbatim: status).font(.footnote).foregroundStyle(.secondary) }
            }
            if !tools.isEmpty {
                Section {
                    ForEach(tools, id: \.name) { tool in
                        Toggle(isOn: enabledBinding(tool.name)) {
                            VStack(alignment: .leading) {
                                Text(verbatim: tool.name)
                                if !tool.description.isEmpty {
                                    Text(verbatim: tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("A tool that is off does not exist for the agent.")
                }
            }
        }
        .navigationTitle(server.name.isEmpty ? tr("New server") : server.name)
        .onAppear {
            if headers.isEmpty {
                headers = store.headers(of: server).sorted { $0.key < $1.key }.map { HeaderRow(name: $0.key, value: $0.value) }
            }
            #if DEBUG
            if connectAtOnce { test() }
            #endif
        }
    }

    private func enabledBinding(_ name: String) -> Binding<Bool> {
        Binding {
            !server.disabledTools.contains(name)
        } set: { on in
            server.disabledTools.removeAll { $0 == name }
            if !on { server.disabledTools.append(name) }
        }
    }

    private func saveHeaders() {
        var out: [String: String] = [:]
        for row in headers where !row.name.isEmpty { out[row.name] = row.value }
        store.setHeaders(out, of: server)
    }

    private func test() {
        testing = true
        status = ""
        saveHeaders()
        let current = server
        let hdrs = store.headers(of: current)
        Task {
            do {
                guard let url = URL(string: current.url.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else { throw AppError("Invalid URL.") }
                tools = try await MCPClient(url: url, headers: hdrs).listTools()
                status = tr("Connected. Tools: %d.", tools.count)
            } catch {
                tools = []
                status = error.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: - Profiles

struct ProfilesView: View {
    @Bindable var store: SettingsStore
    let conversation: ConversationModel
    @State private var added: UUID?

    var body: some View {
        List {
            Section {
                ForEach($store.settings.profiles) { $profile in
                    NavigationLink {
                        ProfileEditor(store: store, conversation: conversation, profile: $profile)
                    } label: {
                        LabeledContent {
                            if profile.id == store.settings.activeProfileID { Image(systemName: "checkmark") }
                        } label: {
                            Text(verbatim: profile.displayName)
                            Text(verbatim: summary(of: profile))
                        }
                    }
                }
                .onDelete(perform: delete)
                .deleteDisabled(store.settings.profiles.count == 1)
            } footer: {
                Text("Switch profiles from the title of the conversation. Switching starts a new conversation.")
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            Button("Add", systemImage: "plus") {
                let profile = AgentProfile()
                store.settings.profiles.append(profile)
                added = profile.id
            }
        }
        .navigationDestination(item: $added) { id in
            if let i = store.settings.profiles.firstIndex(where: { $0.id == id }) {
                ProfileEditor(store: store, conversation: conversation, profile: $store.settings.profiles[i])
            }
        }
    }

    private func summary(of profile: AgentProfile) -> String {
        let servers = store.settings.profileMCP(of: profile).count + (profile.mcpServers.contains(PhoneTools.serverID) ? 1 : 0)
        return "\(servers) MCP · \(profile.speakReplies ? tr("Speaks") : tr("Text only"))"
    }

    private func delete(_ offsets: IndexSet) {
        let wasActive = offsets.contains { store.settings.profiles[$0].id == store.settings.activeProfileID }
        var rest = store.settings.profiles
        rest.remove(atOffsets: offsets)
        guard let first = rest.first else { return }
        if wasActive { conversation.switchProfile(to: first.id) }
        store.settings.profiles = rest
    }
}

struct ProfileEditor: View {
    let store: SettingsStore
    let conversation: ConversationModel
    @Binding var profile: AgentProfile

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                if profile.id == store.settings.activeProfileID {
                    Label("In use", systemImage: "checkmark").foregroundStyle(.secondary)
                } else {
                    Button("Use this profile") { conversation.switchProfile(to: profile.id) }
                }
            }
            Section("Agent") {
                NavigationLink {
                    SoulView(soul: $profile.soul, conversation: conversation)
                } label: {
                    LabeledContent("Soul", value: profile.soul.text.isEmpty ? tr("Empty") : profile.soul.loadViaMCP ? tr("Through MCP") : tr("Text"))
                }
            }
            Section {
                Toggle("iPhone", isOn: loads(PhoneTools.serverID))
                if profile.mcpServers.contains(PhoneTools.serverID), store.settings.phoneTools.isEmpty {
                    Text("No iPhone tools are on yet. Choose them under iPhone in Settings.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.settings.mcp) { server in
                    Toggle(server.name.isEmpty ? tr("Unnamed") : server.name, isOn: loads(server.id))
                }
                if store.settings.mcp.isEmpty {
                    Text("Add servers under MCP servers in Settings.").font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("MCP servers")
            } footer: {
                Text("The agent's only tools. Only the servers switched on here are loaded for this profile.")
            }
            Section {
                Toggle("Speak replies", isOn: $profile.speakReplies)
            } footer: {
                Text("Off means replies are text only.")
            }
            Section {
                Toggle("Always ready", isOn: $profile.alwaysReady)
            } footer: {
                Text("On, the agent greets you when the app opens and in every new conversation, so you know everything is loaded. Off, nothing goes to the model until your first message.")
            }
        }
        .navigationTitle(profile.displayName)
    }

    private func loads(_ server: UUID) -> Binding<Bool> {
        Binding {
            profile.mcpServers.contains(server)
        } set: { on in
            profile.mcpServers.removeAll { $0 == server }
            if on { profile.mcpServers.append(server) }
        }
    }
}

// MARK: - iPhone tools

struct PhoneToolsView: View {
    @Bindable var store: SettingsStore
    @State private var refused: PhoneTools.Area?

    var body: some View {
        Form {
            Section {
            } footer: {
                Text("Every tool is off until you turn it on. Turning one on also switches iPhone on in the profile you are using; other profiles choose for themselves. What a tool reads, such as your events or contacts, is sent to the AI model you chose.")
            }
            ForEach(PhoneTools.Area.allCases) { area in
                Section {
                    ForEach(PhoneTools.all.filter { $0.area == area }) { tool in
                        Toggle(tr(tool.title), isOn: binding(tool))
                    }
                    if refused == area {
                        Text("Access is off. Turn it on in iOS Settings.").font(.footnote).foregroundStyle(.red)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Open iOS Settings", destination: url)
                        }
                    }
                } header: {
                    Text(verbatim: area.title)
                }
            }
        }
        .navigationTitle("iPhone")
    }

    private func binding(_ tool: PhoneTools.Tool) -> Binding<Bool> {
        Binding {
            store.settings.phoneTools.contains(tool.name)
        } set: { on in
            guard on else {
                store.settings.phoneTools.removeAll { $0 == tool.name }
                return
            }
            // iOS asks at the moment the user turns on the first tool that needs it.
            Task {
                if await PhoneTools.requestAccess(tool.area) {
                    refused = nil
                    store.settings.turnOnPhoneTool(tool.name)
                } else {
                    refused = tool.area
                }
            }
        }
    }
}

// MARK: - Soul

struct SoulView: View {
    @Binding var soul: SoulSettings
    let conversation: ConversationModel

    var body: some View {
        Form {
            Section {
                PlainTextEditor(text: $soul.text)
                    .frame(minHeight: 220)
            } footer: {
                Text(soul.loadViaMCP
                     ? "An instruction for the model. Example: Call get_persona on the memory MCP server with the name Alex."
                     : "Who the agent is and how it behaves. Used as written.")
            }
            Section {
                Toggle("Load through MCP", isOn: $soul.loadViaMCP)
            } footer: {
                Text("At the start of a conversation the model carries out the text above with the MCP tools, and what the tools return becomes the soul. If nothing loads, the conversation shows an error; there is no fallback.")
            }
            Section {
                Button("Reload for the next message") { conversation.reloadSoul() }
            }
        }
        .navigationTitle("Soul")
    }
}

// MARK: - Speech

/// Saved services of one direction. Tapping one puts it to use and nothing in the others changes.
private struct SpeechServicesList<Service: SpeechService, Editor: View>: View {
    let title: LocalizedStringKey
    @Binding var services: [Service]
    @Binding var active: UUID
    let adding: [(label: String, make: () -> Service)]
    @ViewBuilder let editor: (Binding<Service>) -> Editor
    @State private var editing: UUID?

    var body: some View {
        List {
            Section {
                ForEach(services) { service in
                    HStack {
                        Button {
                            active = service.id
                        } label: {
                            HStack {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .opacity(service.id == active ? 1 : 0)
                                VStack(alignment: .leading) {
                                    Text(verbatim: service.displayName)
                                    if !service.detail.isEmpty {
                                        Text(verbatim: service.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button("Edit", systemImage: "info.circle") { editing = service.id }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    .deleteDisabled(services.count == 1)
                }
                .onDelete { offsets in
                    for i in offsets { Keychain.set(services[i].keyAccount, "") }
                    services.remove(atOffsets: offsets)
                    if !services.contains(where: { $0.id == active }) { active = services[0].id }
                }
            } footer: {
                Text("Tap a service to use it. Each one keeps its own address and login.")
            }
        }
        .navigationTitle(title)
        .toolbar {
            Menu("Add", systemImage: "plus") {
                ForEach(adding.indices, id: \.self) { i in
                    Button(adding[i].label) {
                        let service = adding[i].make()
                        services.append(service)
                        active = service.id
                        editing = service.id
                    }
                }
            }
        }
        .navigationDestination(item: $editing) { id in
            if let i = services.firstIndex(where: { $0.id == id }) {
                editor($services[i])
            }
        }
    }
}

struct STTView: View {
    @Bindable var store: SettingsStore
    let conversation: ConversationModel

    var body: some View {
        SpeechServicesList(
            title: "Speech to text",
            services: $store.settings.sttServices,
            active: $store.settings.activeSTT,
            adding: STTKind.allCases.map { kind in (kind.label, { STTSettings(kind: kind) }) }
        ) { STTEditor(service: $0, conversation: conversation) }
    }
}

struct STTEditor: View {
    @Binding var service: STTSettings
    let conversation: ConversationModel
    @State private var key = ""
    private enum TestState { case idle, listening, transcribing }
    @State private var testState = TestState.idle
    @State private var heard = ""
    @State private var status = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $service.name, prompt: Text(verbatim: service.kind.label))
                LabeledContent("Provider", value: service.kind.label)
            }
            Section {
                if service.kind != .apple {
                    TextField("URL", text: $service.url, prompt: Text(service.kind == .whisperCpp ? "http://host:port/inference" : "https://…"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API key (optional for local servers)", text: $key)
                        .onChange(of: key) { _, v in Keychain.set(service.keyAccount, v) }
                }
                if service.kind == .openAI || service.kind == .elevenLabs {
                    TextField("Model", text: $service.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField("Language (empty: automatic)", text: $service.language, prompt: Text(verbatim: "en"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if service.kind == .openAI || service.kind == .whisperCpp {
                    MultilineField(title: "Vocabulary hint (names, terms)", text: $service.prompt)
                }
            }
            Section {
                switch testState {
                case .idle: Button("Test speech recognition", action: test)
                case .listening: Button("Listening… Tap to stop") { conversation.stopTranscriptionTest() }
                case .transcribing: Text("Transcribing…").foregroundStyle(.secondary)
                }
                if !heard.isEmpty { Text(verbatim: heard).textSelection(.enabled) }
                if !status.isEmpty { Text(verbatim: status).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("Say something. It ends by itself after a pause and nothing goes to the agent.")
            }
        }
        .navigationTitle(service.displayName)
        .onAppear { key = Keychain.get(service.keyAccount) ?? "" }
        .onDisappear { conversation.cancelTranscriptionTest() }
    }

    private func test() {
        testState = .listening
        heard = ""
        status = ""
        Task {
            do {
                let text = try await conversation.testTranscription(with: service) { testState = .transcribing }
                if text.isEmpty { status = tr("Nothing was heard.") } else { heard = text }
            } catch {
                status = error.localizedDescription
            }
            testState = .idle
        }
    }
}

struct TTSView: View {
    @Bindable var store: SettingsStore
    let conversation: ConversationModel

    var body: some View {
        SpeechServicesList(
            title: "Text to speech",
            services: $store.settings.ttsServices,
            active: $store.settings.activeTTS,
            adding: TTSKind.allCases.map { kind in (kind.label, { TTSSettings(kind: kind) }) }
        ) { TTSEditor(service: $0, conversation: conversation) }
    }
}

private struct TTSEditor: View {
    @Binding var service: TTSSettings
    let conversation: ConversationModel
    @State private var key = ""
    @State private var sample = ""
    @State private var status = ""
    @State private var testing = false

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $service.name, prompt: Text(verbatim: service.kind.label))
                LabeledContent("Provider", value: service.kind.label)
            }
            Section {
                switch service.kind {
                case .apple:
                    Picker("Voice", selection: $service.voice) {
                        Text("Default").tag("")
                        ForEach(voices, id: \.identifier) { Text(verbatim: "\($0.name) (\($0.language))").tag($0.identifier) }
                    }
                    .pickerStyle(.navigationLink)
                case .piper:
                    urlField("http://host:port/api/tts")
                    plainField("Voice", $service.voice)
                case .openAI:
                    urlField("https://api.openai.com/v1")
                    keyField
                    plainField("Model", $service.model)
                    plainField("Voice", $service.voice)
                case .elevenLabs:
                    urlField("https://api.elevenlabs.io")
                    keyField
                    plainField("Model", $service.model)
                    plainField("Voice ID", $service.voice)
                    plainField("Language (optional)", $service.language)
                }
            }
            Section {
                MultilineField(title: "Sentence to say", text: $sample)
                Button(testing ? "Speaking…" : "Test voice") {
                    testing = true
                    status = ""
                    Task {
                        do { try await conversation.testSpeech(sample, with: service) }
                        catch { status = error.localizedDescription }
                        testing = false
                    }
                }
                .disabled(testing || sample.trimmingCharacters(in: .whitespaces).isEmpty)
                if !status.isEmpty { Text(verbatim: status).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(service.displayName)
        .onAppear { key = Keychain.get(service.keyAccount) ?? "" }
    }

    private func urlField(_ prompt: String) -> some View {
        TextField("URL", text: $service.url, prompt: Text(prompt))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
    }

    private func plainField(_ title: LocalizedStringKey, _ value: Binding<String>) -> some View {
        TextField(title, text: value)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private var keyField: some View {
        SecureField("API key", text: $key)
            .onChange(of: key) { _, v in Keychain.set(service.keyAccount, v) }
    }
}

struct VoiceOptionsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Interrupt by speaking", isOn: $store.settings.voice.bargeIn)
            } footer: {
                Text("When interrupting is on, speaking over the agent stops it.")
            }
            Section {
                Toggle("Work while I talk", isOn: $store.settings.workWhileTalking)
            } footer: {
                Text("Subagents start reading and looking things up while you are still talking, so answers come sooner. It uses more model calls. Anything that changes something waits until you finish. Takes effect the next time you turn the microphone on.")
            }
            Section("End of phrase after \(Int(store.settings.voice.silenceMs)) ms of silence") {
                Slider(value: $store.settings.voice.silenceMs, in: 300...2500, step: 100)
            }
            Section("Microphone sensitivity") {
                Slider(value: $store.settings.voice.sensitivity, in: 0...1)
            }
        }
        .navigationTitle("Conversation")
    }
}
