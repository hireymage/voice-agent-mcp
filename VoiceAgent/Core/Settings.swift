import Foundation
import Observation
import Security

/// Tokens live only in the Keychain, never in the settings JSON or in logs.
enum Keychain {
    private static let service = "cz.hozzy.VoiceAgent"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum LLMAPI: String, Codable, CaseIterable, Identifiable {
    case openAIChat, openAIResponses, anthropic, gemini, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openAIChat: "OpenAI Chat Completions"
        case .openAIResponses: "OpenAI Responses"
        case .anthropic: "Anthropic Messages"
        case .gemini: "Google Gemini"
        case .apple: "Apple Foundation Models"
        }
    }
}

struct LLMServer: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var api = LLMAPI.openAIChat
    var baseURL = ""
    var keyAccount: String { "llm.\(id.uuidString)" }
}

/// Public endpoints only; a server on your own network has an address you type in.
struct LLMPreset: Identifiable {
    let name: String, api: LLMAPI, url: String
    var id: String { name }
    static let all = [
        LLMPreset(name: "OpenAI", api: .openAIResponses, url: "https://api.openai.com/v1"),
        LLMPreset(name: "Anthropic", api: .anthropic, url: "https://api.anthropic.com"),
        LLMPreset(name: "Google Gemini", api: .gemini, url: "https://generativelanguage.googleapis.com/v1beta"),
        LLMPreset(name: "OpenRouter", api: .openAIChat, url: "https://openrouter.ai/api/v1"),
        LLMPreset(name: "Groq", api: .openAIChat, url: "https://api.groq.com/openai/v1"),
        LLMPreset(name: "Mistral", api: .openAIChat, url: "https://api.mistral.ai/v1"),
        LLMPreset(name: "DeepSeek", api: .openAIChat, url: "https://api.deepseek.com/v1"),
        LLMPreset(name: "xAI", api: .openAIChat, url: "https://api.x.ai/v1"),
        LLMPreset(name: "Apple (on this device)", api: .apple, url: ""),
        LLMPreset(name: "Custom (Ollama, vLLM, LM Studio…)", api: .openAIChat, url: ""),
    ]
}

struct ModelChoice: Codable, Hashable {
    var serverID: UUID?
    var model = ""
    /// JSON object merged into every request body (temperature, reasoning_effort, max_tokens…).
    var extraParams = ""
}

struct MCPServer: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var url = ""
    var disabledTools: [String] = []
    var headersAccount: String { "mcp.\(id.uuidString).headers" }
}

struct SoulSettings: Codable, Hashable {
    var text = ""
    /// The text is an instruction: at the start of a conversation the model carries it out with the MCP tools,
    /// and what those tools return becomes the system prompt.
    var loadViaMCP = false
}

/// How much a model thinks before it answers. One scale for every server; each API gets its own parameters.
enum Thinking: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Nothing is sent and the model does what it does by default.
    case model, off, low, medium, high
    var id: String { rawValue }
    var label: String {
        switch self {
        case .model: tr("Model default")
        case .off: tr("Off")
        case .low: tr("Low")
        case .medium: tr("Medium")
        case .high: tr("High")
        }
    }
}

/// Who the agent is at the moment: its soul, the MCP servers it loads and whether it answers aloud.
/// Models and speech providers are shared by all profiles.
struct AgentProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var soul = SoulSettings()
    /// The subagent's own soul, set the same way as the main agent's.
    var subagentSoul = SoulSettings()
    var mainThinking = Thinking.model
    var subagentThinking = Thinking.model
    var speakReplies = true
    var mcpServers: [UUID] = []
    /// The agent greets first, so that everything is loaded before the user says anything.
    /// Off: nothing goes to the model until the user's first message.
    var alwaysReady = true

    var displayName: String { name.isEmpty ? tr("Unnamed") : name }
}

extension AgentProfile {
    /// Fields added in later versions fall back to their defaults instead of losing the settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        soul = try c.decodeIfPresent(SoulSettings.self, forKey: .soul) ?? SoulSettings()
        subagentSoul = try c.decodeIfPresent(SoulSettings.self, forKey: .subagentSoul) ?? SoulSettings()
        mainThinking = try c.decodeIfPresent(Thinking.self, forKey: .mainThinking) ?? .model
        subagentThinking = try c.decodeIfPresent(Thinking.self, forKey: .subagentThinking) ?? .model
        speakReplies = try c.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? true
        mcpServers = try c.decodeIfPresent([UUID].self, forKey: .mcpServers) ?? []
        alwaysReady = try c.decodeIfPresent(Bool.self, forKey: .alwaysReady) ?? true
    }
}

enum STTKind: String, Codable, CaseIterable, Identifiable {
    case apple, openAI, whisperCpp, elevenLabs
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: tr("Apple (on this device)")
        case .openAI: tr("OpenAI-compatible")
        case .whisperCpp: tr("whisper.cpp server")
        case .elevenLabs: "ElevenLabs"
        }
    }
}

/// One saved speech service, so that several of them, even of the same kind, each keep their own address and login.
protocol SpeechService: Identifiable, Hashable where ID == UUID {
    var name: String { get }
    var url: String { get }
    var kindLabel: String { get }
    var keyAccount: String { get }
}

extension SpeechService {
    var displayName: String { name.isEmpty ? kindLabel : name }
    /// Under the name: what tells this one apart, without repeating the name.
    var detail: String {
        [name.isEmpty ? nil : kindLabel, URL(string: url)?.host].compactMap { $0 }.joined(separator: " · ")
    }
}

struct STTSettings: SpeechService, Codable {
    var id = UUID()
    var name = ""
    var kind = STTKind.apple
    var url = ""
    var model = ""
    /// BCP-47 or ISO code. Empty: the phone's language for Apple, automatic for the servers.
    var language = ""
    var prompt = ""
    var keyAccount: String { "stt.\(id.uuidString)" }
    var kindLabel: String { kind.label }

    init() {}

    /// A new service of this kind, with the addresses and models its provider normally uses.
    init(kind: STTKind) {
        self.kind = kind
        switch kind {
        case .apple, .whisperCpp: break
        case .openAI: (url, model) = ("https://api.openai.com/v1", "whisper-1")
        case .elevenLabs: (url, model) = ("https://api.elevenlabs.io/v1/speech-to-text", "scribe_v1")
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(STTKind.self, forKey: .kind) ?? .apple
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    }
}

enum TTSKind: String, Codable, CaseIterable, Identifiable {
    case apple, openAI, piper, elevenLabs
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: tr("Apple (on this device)")
        case .openAI: tr("OpenAI-compatible")
        case .piper: tr("Piper HTTP server")
        case .elevenLabs: "ElevenLabs"
        }
    }
}

struct TTSSettings: SpeechService, Codable {
    var id = UUID()
    var name = ""
    var kind = TTSKind.apple
    var url = ""
    var model = ""
    var voice = ""
    var language = ""
    var keyAccount: String { "tts.\(id.uuidString)" }
    var kindLabel: String { kind.label }

    init() {}

    /// A new service of this kind, with the addresses and models its provider normally uses.
    init(kind: TTSKind) {
        self.kind = kind
        switch kind {
        case .apple, .piper: break
        case .openAI: (url, model, voice) = ("https://api.openai.com/v1", "gpt-4o-mini-tts", "alloy")
        case .elevenLabs: (url, model) = ("https://api.elevenlabs.io", "eleven_multilingual_v2")
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(TTSKind.self, forKey: .kind) ?? .apple
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
    }
}

struct VoiceSettings: Codable, Hashable {
    var bargeIn = true
    /// Interrupt only once speech-to-text has made a word of what was heard, not at the first sound.
    var bargeInOnWord = false
    var silenceMs = 800.0
    /// 0…1; higher hears quieter speech.
    var sensitivity = 0.5
}

extension VoiceSettings {
    /// Fields added in later versions fall back to their defaults instead of losing the settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bargeIn = try c.decodeIfPresent(Bool.self, forKey: .bargeIn) ?? true
        bargeInOnWord = try c.decodeIfPresent(Bool.self, forKey: .bargeInOnWord) ?? false
        silenceMs = try c.decodeIfPresent(Double.self, forKey: .silenceMs) ?? 800
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 0.5
    }
}

struct AppSettings: Codable, Hashable {
    var servers: [LLMServer] = []
    var main = ModelChoice()
    var subagentEnabled = true
    var subagent = ModelChoice()
    /// Only read from older settings: these instructions used to be shared, each profile now has its own subagent soul.
    var subagentInstructions = ""
    var mcp: [MCPServer] = []
    var profiles = [AgentProfile(name: tr("Default"))]
    var activeProfileID = UUID()
    /// There is always at least one of each.
    var sttServices = [STTSettings()]
    var activeSTT = UUID()
    var ttsServices = [TTSSettings()]
    var activeTTS = UUID()
    /// API keys used to be stored per provider; each service now has its own.
    var speechKeysMoved = false
    var voice = VoiceSettings()
    var language = AppLanguage.system
    /// The device's own tools the user has turned on. A profile gets them only if it has the device switched on.
    var phoneTools: [String] = []
    /// Subagents start looking things up while the user is still talking.
    var workWhileTalking = true
    /// The user has been told where their messages and speech go.
    var dataNoticeAccepted = false

    init() {
        activeProfileID = profiles[0].id
        activeSTT = sttServices[0].id
        activeTTS = ttsServices[0].id
    }

    private enum LegacyKeys: String, CodingKey { case soul, voice, stt, tts }
    /// The name Apple's model got in versions up to 1.26.45, in English and Czech.
    private static let iPhoneNames: Set<String> = ["Apple (on this iPhone)", "Apple (v tomto iPhonu)"]
    private struct LegacyVoice: Decodable { var speakReplies: Bool? }

    /// Fields added in later versions fall back to their defaults instead of losing the settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = try c.decodeIfPresent([LLMServer].self, forKey: .servers) ?? []
        // Apple's model was named after the iPhone; the app also runs on a Mac and an iPad.
        for i in servers.indices where servers[i].api == .apple && Self.iPhoneNames.contains(servers[i].name) {
            servers[i].name = tr("Apple (on this device)")
        }
        main = try c.decodeIfPresent(ModelChoice.self, forKey: .main) ?? ModelChoice()
        subagentEnabled = try c.decodeIfPresent(Bool.self, forKey: .subagentEnabled) ?? true
        subagent = try c.decodeIfPresent(ModelChoice.self, forKey: .subagent) ?? ModelChoice()
        subagentInstructions = try c.decodeIfPresent(String.self, forKey: .subagentInstructions) ?? ""
        mcp = try c.decodeIfPresent([MCPServer].self, forKey: .mcp) ?? []
        // Settings from before saved services: the one that was set becomes the first.
        let old = try decoder.container(keyedBy: LegacyKeys.self)
        let savedSTT = try c.decodeIfPresent([STTSettings].self, forKey: .sttServices) ?? []
        sttServices = savedSTT.isEmpty ? [try old.decodeIfPresent(STTSettings.self, forKey: .stt) ?? STTSettings()] : savedSTT
        let wantedSTT = try c.decodeIfPresent(UUID.self, forKey: .activeSTT)
        activeSTT = sttServices.first { $0.id == wantedSTT }?.id ?? sttServices[0].id
        let savedTTS = try c.decodeIfPresent([TTSSettings].self, forKey: .ttsServices) ?? []
        ttsServices = savedTTS.isEmpty ? [try old.decodeIfPresent(TTSSettings.self, forKey: .tts) ?? TTSSettings()] : savedTTS
        let wantedTTS = try c.decodeIfPresent(UUID.self, forKey: .activeTTS)
        activeTTS = ttsServices.first { $0.id == wantedTTS }?.id ?? ttsServices[0].id
        speechKeysMoved = try c.decodeIfPresent(Bool.self, forKey: .speechKeysMoved) ?? false
        voice = try c.decodeIfPresent(VoiceSettings.self, forKey: .voice) ?? VoiceSettings()
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        phoneTools = try c.decodeIfPresent([String].self, forKey: .phoneTools) ?? []
        workWhileTalking = try c.decodeIfPresent(Bool.self, forKey: .workWhileTalking) ?? true
        dataNoticeAccepted = try c.decodeIfPresent(Bool.self, forKey: .dataNoticeAccepted) ?? false
        let saved = try c.decodeIfPresent([AgentProfile].self, forKey: .profiles) ?? []
        if saved.isEmpty {
            // Settings from before profiles: what was set for the whole app becomes the first profile.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            var first = AgentProfile(name: tr("Default"), mcpServers: mcp.map(\.id))
            first.soul = try legacy.decodeIfPresent(SoulSettings.self, forKey: .soul) ?? SoulSettings()
            first.speakReplies = try legacy.decodeIfPresent(LegacyVoice.self, forKey: .voice)?.speakReplies ?? true
            profiles = [first]
        } else {
            profiles = saved
        }
        let active = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        activeProfileID = profiles.first { $0.id == active }?.id ?? profiles[0].id
        // The shared subagent instructions applied to every profile, so every profile gets them.
        if !subagentInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for i in profiles.indices where profiles[i].subagentSoul.text.isEmpty { profiles[i].subagentSoul.text = subagentInstructions }
            subagentInstructions = ""
        }
    }

    func server(_ id: UUID?) -> LLMServer? { servers.first { $0.id == id } }

    /// The speech service in use.
    var stt: STTSettings {
        get { sttServices.first { $0.id == activeSTT } ?? sttServices[0] }
        set {
            if let i = sttServices.firstIndex(where: { $0.id == newValue.id }) { sttServices[i] = newValue }
        }
    }

    var tts: TTSSettings {
        get { ttsServices.first { $0.id == activeTTS } ?? ttsServices[0] }
        set {
            if let i = ttsServices.firstIndex(where: { $0.id == newValue.id }) { ttsServices[i] = newValue }
        }
    }

    /// Every key saved under the old per-provider name goes on working: with the service that has that provider,
    /// or with a new one when its address was not kept. The old entries stay, so going back to an older version works.
    mutating func moveOldSpeechKeys() {
        speechKeysMoved = true
        for kind in STTKind.allCases {
            guard let key = Keychain.get("stt.\(kind.rawValue)"), !key.isEmpty else { continue }
            if !sttServices.contains(where: { $0.kind == kind }) { sttServices.append(STTSettings(kind: kind)) }
            for s in sttServices where s.kind == kind { Keychain.set(s.keyAccount, key) }
        }
        for kind in TTSKind.allCases {
            guard let key = Keychain.get("tts.\(kind.rawValue)"), !key.isEmpty else { continue }
            if !ttsServices.contains(where: { $0.kind == kind }) { ttsServices.append(TTSSettings(kind: kind)) }
            for s in ttsServices where s.kind == kind { Keychain.set(s.keyAccount, key) }
        }
    }

    /// The active profile.
    var profile: AgentProfile {
        get { profiles.first { $0.id == activeProfileID } ?? profiles[0] }
        set {
            if let i = profiles.firstIndex(where: { $0.id == newValue.id }) { profiles[i] = newValue }
        }
    }

    /// The MCP servers the active profile loads.
    var profileMCP: [MCPServer] { profileMCP(of: profile) }
    func profileMCP(of profile: AgentProfile) -> [MCPServer] { mcp.filter { profile.mcpServers.contains($0.id) } }

    /// The device tools the active profile has.
    var profilePhoneTools: [String] { profile.mcpServers.contains(PhoneTools.serverID) ? phoneTools : [] }

    /// A tool you have just turned on is meant for the profile you are in, as a server you add is.
    mutating func turnOnPhoneTool(_ name: String) {
        if !phoneTools.contains(name) { phoneTools.append(name) }
        if !profile.mcpServers.contains(PhoneTools.serverID) { profile.mcpServers.append(PhoneTools.serverID) }
    }

    /// A server you have just added is meant for the profile you are in.
    mutating func addToActiveProfile(_ server: MCPServer) {
        if !profile.mcpServers.contains(server.id) { profile.mcpServers.append(server.id) }
    }
}

@MainActor @Observable
final class SettingsStore {
    private static let key = "settings.v1"
    private let defaults: UserDefaults

    var settings: AppSettings {
        didSet {
            if let d = try? JSONEncoder().encode(settings) { defaults.set(d, forKey: Self.key) }
            if oldValue.language != settings.language { Localizer.remember(settings.language) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(AppSettings.self, from: d) {
            settings = s
        } else {
            settings = AppSettings()
        }
        if !settings.speechKeysMoved {
            settings.moveOldSpeechKeys()
            if let d = try? JSONEncoder().encode(settings) { defaults.set(d, forKey: Self.key) }
        }
        Localizer.use(settings.language)
    }

    func headers(of server: MCPServer) -> [String: String] {
        guard let raw = Keychain.get(server.headersAccount), let d = raw.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    /// Changes when a token that is not part of `settings` changes, so that connections are made again.
    private(set) var secretsRevision = 0

    func setHeaders(_ headers: [String: String], of server: MCPServer) {
        secretsRevision += 1
        let d = (try? JSONEncoder().encode(headers)) ?? Data()
        Keychain.set(server.headersAccount, headers.isEmpty ? "" : String(decoding: d, as: UTF8.self))
    }

    /// Imports the `{"mcpServers": {…}}` format of Pi, Claude and others. The app cannot run local (stdio)
    /// servers, so those are reported back instead of being added.
    @discardableResult
    func importMCP(json: String) throws -> (added: [String], skipped: [String]) {
        guard let root = JSONValue.parse(json) else { throw AppError("That is not valid JSON.") }
        guard let list = (root["mcpServers"] ?? root).object else { throw AppError("Expected an \"mcpServers\" object.") }
        var added: [String] = [], skipped: [String] = []
        for (name, entry) in list.sorted(by: { $0.key < $1.key }) {
            guard let url = entry["url"]?.string, !url.isEmpty else { skipped.append(name); continue }
            var server = settings.mcp.first { $0.name == name } ?? MCPServer(name: name)
            server.url = url
            if let i = settings.mcp.firstIndex(where: { $0.id == server.id }) { settings.mcp[i] = server } else { settings.mcp.append(server) }
            settings.addToActiveProfile(server)
            var headers: [String: String] = [:]
            for (k, v) in entry["headers"]?.object ?? [:] { if let s = v.string { headers[k] = s } }
            setHeaders(headers, of: server)
            added.append(name)
        }
        return (added, skipped)
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = tr(message) }
    var errorDescription: String? { message }
}
