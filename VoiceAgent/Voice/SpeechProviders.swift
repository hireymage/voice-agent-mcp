import AVFoundation
import Speech

// MARK: - Speech to text

protocol STTProvider: Sendable {
    func transcribe(wav: Data) async throws -> String
}

struct Multipart {
    let boundary = "voiceagent-\(UUID().uuidString)"
    private(set) var data = Data()

    mutating func field(_ name: String, _ value: String) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, type: String, _ bytes: Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        data.append(bytes)
        data.append(Data("\r\n".utf8))
    }

    func request(_ url: URL, headers: [String: String]) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = data + Data("--\(boundary)--\r\n".utf8)
        return r
    }
}

private func trimmedURL(_ s: String, what: String) throws -> URL {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    while t.hasSuffix("/") { t.removeLast() }
    guard let u = URL(string: t), u.scheme != nil else { throw AppError(tr("%@: set the server address in Settings.", what)) }
    return u
}

/// Sends the form and reads `{"text": …}` (or plain text) back.
private func transcriptRequest(_ form: Multipart, url: URL, headers: [String: String]) async throws -> String {
    let (data, response) = try await URLSession.shared.data(for: form.request(url, headers: headers))
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw HTTPFailure(status: status, body: String(decoding: data.prefix(4096), as: UTF8.self)) }
    let text = JSONValue.parse(data)?["text"]?.string ?? String(decoding: data, as: UTF8.self)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// OpenAI-compatible POST {base}/audio/transcriptions (OpenAI, Groq and compatible servers).
struct OpenAISTT: STTProvider {
    let s: STTSettings, key: String
    func transcribe(wav: Data) async throws -> String {
        var form = Multipart()
        form.file("file", filename: "speech.wav", type: "audio/wav", wav)
        form.field("model", s.model)
        form.field("response_format", "json")
        form.field("temperature", "0")
        if !s.language.isEmpty { form.field("language", s.language) }
        if !s.prompt.isEmpty { form.field("prompt", s.prompt) }
        let url = try trimmedURL(s.url, what: "Speech to text").appendingPathComponent("audio/transcriptions")
        return try await transcriptRequest(form, url: url, headers: key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"])
    }
}

/// whisper.cpp server: POST /inference with a multipart `file`.
struct WhisperCppSTT: STTProvider {
    let s: STTSettings, key: String
    func transcribe(wav: Data) async throws -> String {
        var form = Multipart()
        form.file("file", filename: "speech.wav", type: "audio/wav", wav)
        form.field("response_format", "json")
        form.field("temperature", "0")
        if !s.language.isEmpty { form.field("language", s.language) }
        if !s.prompt.isEmpty { form.field("prompt", s.prompt) }
        return try await transcriptRequest(form, url: try trimmedURL(s.url, what: "Speech to text"), headers: key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"])
    }
}

/// ElevenLabs Scribe: POST /v1/speech-to-text.
struct ElevenLabsSTT: STTProvider {
    let s: STTSettings, key: String
    func transcribe(wav: Data) async throws -> String {
        var form = Multipart()
        form.file("file", filename: "speech.wav", type: "audio/wav", wav)
        form.field("model_id", s.model)
        if !s.language.isEmpty { form.field("language_code", s.language) }
        return try await transcriptRequest(form, url: try trimmedURL(s.url, what: "Speech to text"), headers: ["xi-api-key": key])
    }
}

/// Apple's recognizer, on the device when the language allows it.
struct AppleSTT: STTProvider {
    let language: String

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    func transcribe(wav: Data) async throws -> String {
                let locale = Locale(identifier: language.isEmpty ? Localizer.speechLanguage : language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AppError(tr("Apple speech recognition is not available for %@.", locale.identifier))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let holder = RecognitionHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                holder.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        holder.finish { c.resume(returning: result.bestTranscription.formattedString) }
                    } else if let error {
                        // 1110: no speech in the audio. That is an empty phrase, not a failure.
                        let silence = (error as NSError).code == 1110
                        holder.finish { silence ? c.resume(returning: "") : c.resume(throwing: error) }
                    }
                }
            }
        } onCancel: { holder.cancel() }
    }
}

private final class RecognitionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var task: SFSpeechRecognitionTask?
    func finish(_ resume: () -> Void) {
        let first = lock.withLock { () -> Bool in let f = !done; done = true; return f }
        if first { resume() }
    }
    func cancel() { task?.cancel() }
}

func makeSTT(_ s: STTSettings) -> STTProvider {
    let key = Keychain.get(s.keyAccount) ?? ""
    switch s.kind {
    case .apple: return AppleSTT(language: s.language)
    case .openAI: return OpenAISTT(s: s, key: key)
    case .whisperCpp: return WhisperCppSTT(s: s, key: key)
    case .elevenLabs: return ElevenLabsSTT(s: s, key: key)
    }
}

// MARK: - Text to speech

protocol TTSProvider: Sendable {
    func synthesize(_ text: String) async throws -> AudioClip
}

/// A short wait and retry on HTTP 429: plans with low concurrency limits refuse prefetched sentences otherwise.
private func fetchAudio(_ request: URLRequest) async throws -> Data {
    for wait in [250, 600, 1200, 0] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        if status == 429, wait > 0 {
            try await Task.sleep(for: .milliseconds(wait))
            continue
        }
        throw HTTPFailure(status: status, body: String(decoding: data.prefix(4096), as: UTF8.self))
    }
    throw AppError("Text to speech: too many requests.")
}

/// OpenAI-compatible POST {base}/audio/speech, response_format wav.
struct OpenAITTS: TTSProvider {
    let s: TTSSettings, key: String
    func synthesize(_ text: String) async throws -> AudioClip {
        let url = try trimmedURL(s.url, what: "Text to speech").appendingPathComponent("audio/speech")
        let body: JSONValue = ["model": .string(s.model), "voice": .string(s.voice), "input": .string(text), "response_format": "wav"]
        var r = jsonRequest(url, body: body, headers: key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"])
        r.timeoutInterval = 60
        return try AudioFormats.decode(try await fetchAudio(r))
    }
}

/// Piper HTTP server: POST form {text, voice} returns WAV.
struct PiperTTS: TTSProvider {
    let s: TTSSettings
    func synthesize(_ text: String) async throws -> AudioClip {
        var r = URLRequest(url: try trimmedURL(s.url, what: "Text to speech"), timeoutInterval: 60)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/")
        let esc = { (v: String) in v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v }
        r.httpBody = Data("text=\(esc(text))&voice=\(esc(s.voice))".utf8)
        return try AudioFormats.decode(try await fetchAudio(r))
    }
}

/// ElevenLabs: POST /v1/text-to-speech/{voice}, raw 24 kHz PCM wrapped into WAV.
struct ElevenLabsTTS: TTSProvider {
    let s: TTSSettings, key: String
    private static let rate = 24000
    func synthesize(_ text: String) async throws -> AudioClip {
        guard !s.voice.isEmpty else { throw AppError("ElevenLabs: set the voice ID in Settings.") }
        let base = try trimmedURL(s.url, what: "Text to speech")
        guard var parts = URLComponents(url: base.appendingPathComponent("v1/text-to-speech").appendingPathComponent(s.voice), resolvingAgainstBaseURL: false) else { throw AppError("Invalid address.") }
        parts.queryItems = [URLQueryItem(name: "output_format", value: "pcm_\(Self.rate)")]
        var body: JSONValue = ["text": .string(text), "model_id": .string(s.model)]
        if !s.language.isEmpty { body = body.merging(["language_code": .string(s.language)]) }
        var r = jsonRequest(parts.url!, body: body, headers: ["xi-api-key": key, "Accept": "audio/pcm"])
        r.timeoutInterval = 60
        let raw = try await fetchAudio(r)
        let pcm = raw.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return try AudioFormats.decode(wavData(pcm, sampleRate: Self.rate))
    }
}

/// The phone's own voices. Rendered to a buffer, so they play through the same path as the servers' audio.
final class AppleTTS: TTSProvider, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private let voiceID: String
    private let language: String

    init(voiceID: String, language: String) {
        self.voiceID = voiceID
        self.language = language
    }

    func synthesize(_ text: String) async throws -> AudioClip {
        let voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? AVSpeechSynthesisVoice(language: language.isEmpty ? Localizer.speechLanguage : language)
        var raw = try await render(text, voice: voice, with: synth)
        if raw.isEmpty {
            // The system synthesizer sometimes returns nothing; a new one usually does not.
            try await Task.sleep(for: .milliseconds(150))
            raw = try await render(text, voice: voice, with: AVSpeechSynthesizer())
        }
        guard let first = raw.first else { throw AppError("Apple voice returned no audio.") }
        let frames = raw.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard let joined = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: frames) else { throw AppError("Out of memory for audio.") }
        for part in raw {
            let n = Int(part.frameLength), at = Int(joined.frameLength)
            if let src = part.floatChannelData?[0], let dst = joined.floatChannelData?[0] {
                memcpy(dst + at, src, n * MemoryLayout<Float>.size)
            } else if let src = part.int16ChannelData?[0], let dst = joined.int16ChannelData?[0] {
                memcpy(dst + at, src, n * MemoryLayout<Int16>.size)
            }
            joined.frameLength += part.frameLength
        }
        return AudioClip(buffer: try AudioFormats.convert(joined))
    }

    private func render(_ text: String, voice: AVSpeechSynthesisVoice?, with synthesizer: AVSpeechSynthesizer) async throws -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        return try await withCheckedThrowingContinuation { c in
            var parts: [AVAudioPCMBuffer] = []
            let once = RecognitionHolder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { once.finish { c.resume(throwing: AppError("Apple voice did not respond.")) } }
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { once.finish { c.resume(returning: parts) } } else { parts.append(pcm) }
            }
        }
    }
}

func makeTTS(_ s: TTSSettings) -> TTSProvider {
    let key = Keychain.get(s.keyAccount) ?? ""
    switch s.kind {
    case .apple: return AppleTTS(voiceID: s.voice, language: s.language)
    case .openAI: return OpenAITTS(s: s, key: key)
    case .piper: return PiperTTS(s: s)
    case .elevenLabs: return ElevenLabsTTS(s: s, key: key)
    }
}

/// Says sentences in order while they are prepared ahead, at most two at a time.
@MainActor
final class SpeechPlayer {
    private let audio: AudioIO
    private let tts: TTSProvider
    private let onError: (String) -> Void
    private var jobs: AsyncStream<Task<AudioClip, Error>>.Continuation?
    private var pump: Task<Void, Never>?
    private let limiter = Limiter(2)

    init(audio: AudioIO, tts: TTSProvider, onError: @escaping (String) -> Void) {
        self.audio = audio
        self.tts = tts
        self.onError = onError
        let (stream, continuation) = AsyncStream.makeStream(of: Task<AudioClip, Error>.self)
        jobs = continuation
        pump = Task { [audio] in
            var reported = false
            for await job in stream {
                if Task.isCancelled { job.cancel(); continue }
                do {
                    let clip = try await job.value
                    if Task.isCancelled { continue }
                    await audio.play(clip)
                } catch {
                    if !reported, !Task.isCancelled, !(error is CancellationError) {
                        reported = true
                        onError(error.localizedDescription)
                    }
                }
            }
        }
    }

    func say(_ text: String) {
        let tts = self.tts, limiter = self.limiter
        jobs?.yield(Task {
            await limiter.acquire()
            defer { Task { await limiter.release() } }
            return try await tts.synthesize(text)
        })
    }

    /// No more sentences; waits until everything has been heard.
    func finish() async {
        jobs?.finish()
        await pump?.value
    }

    func cancel() {
        jobs?.finish()
        pump?.cancel()
        audio.stopPlayback()
    }
}

private actor Limiter {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { free = n }
    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}
