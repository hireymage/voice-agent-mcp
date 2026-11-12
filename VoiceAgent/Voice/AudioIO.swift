import AVFoundation

/// A piece of speech ready to play. Decoded once and only read afterwards.
struct AudioClip: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

enum AudioFormats {
    static let playback = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

    /// Short signals for when nothing on a screen should have to be read.
    static let listeningTone = tone(hz: 880, ms: 120)
    static let problemTone = tone(hz: 330, ms: 300)

    static func tone(hz: Double, ms: Double) -> AudioClip {
        let frames = AVAudioFrameCount(playback.sampleRate * ms / 1000)
        let buffer = AVAudioPCMBuffer(pcmFormat: playback, frameCapacity: frames)!
        buffer.frameLength = frames
        let fade = Double(frames) / 10 // avoids clicks at both ends
        for i in 0..<Int(frames) {
            let envelope = min(1, min(Double(i), Double(frames) - Double(i)) / fade)
            buffer.floatChannelData![0][i] = Float(sin(2 * .pi * hz * Double(i) / playback.sampleRate) * envelope * 0.4)
        }
        return AudioClip(buffer: buffer)
    }

    static func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format == playback { return input }
        guard let converter = AVAudioConverter(from: input.format, to: playback) else { throw AppError("Audio format not supported.") }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * playback.sampleRate / input.format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: playback, frameCapacity: capacity) else { throw AppError("Out of memory for audio.") }
        var fed = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let failure { throw failure }
        return output
    }

    /// Decodes WAV, MP3, AAC or FLAC bytes from a speech server.
    static func decode(_ data: Data) throws -> AudioClip {
        let ext: String
        switch data.prefix(4) {
        case Data("RIFF".utf8): ext = "wav"
        case Data("fLaC".utf8): ext = "flac"
        default: ext = data.prefix(3) == Data("ID3".utf8) || data.first == 0xFF ? "mp3" : "wav"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try (ext == "wav" ? fixedWavHeader(data) : data).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw AppError("Out of memory for audio.") }
        try file.read(into: buffer)
        return AudioClip(buffer: try convert(buffer))
    }

    /// Servers that stream WAV write placeholder sizes into the header, which the decoder rejects.
    /// A size that fits the file stays: what follows the audio is not audio, and Piper's server adds a line of text there.
    static func fixedWavHeader(_ data: Data) -> Data {
        guard data.count > 44, let dataTag = data.range(of: Data("data".utf8), in: 12..<min(data.count, 4096)), dataTag.lowerBound - data.startIndex + 8 <= data.count else { return data }
        let declared = (0..<4).reduce(0) { $0 | Int(data[dataTag.upperBound + $1]) << (8 * $1) }
        if declared > 0, dataTag.lowerBound - data.startIndex + 8 + declared <= data.count { return data }
        var d = data
        func put(_ value: Int, at offset: Int) {
            var v = UInt32(value).littleEndian
            withUnsafeBytes(of: &v) { d.replaceSubrange(d.startIndex + offset..<d.startIndex + offset + 4, with: $0) }
        }
        let tag = dataTag.lowerBound - data.startIndex
        put(data.count - 8, at: 4)
        put(data.count - tag - 8, at: tag + 4)
        return d
    }
}

private final class Finished: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() { lock.withLock { done = true } }
    var value: Bool { lock.withLock { done } }
}

/// Microphone and speaker on one engine, so the phone's voice processing can remove its own speech from the mic.
final class AudioIO {
    var onEvent: ((PhraseDetector.Event) -> Void)?
    /// In CarPlay the car owns the route and the app sets the session up the way Apple asks for voice apps.
    var car = false

    private var engine: AVAudioEngine?
    private let player = AVAudioPlayerNode()
    private let detector = PhraseDetector()
    private let lock = NSLock()
    private var micWanted = false
    /// False from the moment an engine is built until sound really goes through it.
    private var outputReady = false
    private var warmUpID = 0
    private var runningForCar = false
    private var carry: [Float] = []
    private var observers: [NSObjectProtocol] = []
    private var configObserver: NSObjectProtocol?
    private var engineListens = false
    /// On a Mac the voice processing engine is kept and started again. Released, it is torn down for about a
    /// second, and every engine started meanwhile fails (-50), including the next attempts.
    private var keptVoiceEngine: AVAudioEngine?
    /// How the microphone is set up, best first. A way that kept the engine from starting is not tried again.
    /// On a Mac running the iPhone app, voice processing starts only with the player wired straight to the output.
    enum MicSetup { case voiceProcessing, voiceProcessingDirect, plain }
    private(set) var micSetups: [MicSetup] = ProcessInfo.processInfo.isiOSAppOnMac
        ? [.voiceProcessingDirect, .plain] : [.voiceProcessing, .voiceProcessingDirect, .plain]

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.restart() }
        })
    }

    func configure(silenceMs: Double, sensitivity: Double, phrases: Bool) {
        lock.withLock {
            detector.silenceMs = silenceMs
            detector.sensitivity = sensitivity
            detector.phrasesWanted = phrases
        }
    }

    func setSpeaking(_ speaking: Bool) { lock.withLock { detector.speaking = speaking } }
    func resetDetector() { lock.withLock { detector.reset() } }
    #if DEBUG
    /// For trying real speech in the simulator: the audio goes in as if from the microphone.
    var ignoresMicrophone = false
    func feed(_ pcm: [Int16]) {
        let events = lock.withLock { detector.feed(pcm) }
        guard !events.isEmpty, let onEvent else { return }
        DispatchQueue.main.async { events.forEach(onEvent) }
    }
    #endif

    func finishPhrase() -> [Int16]? { lock.withLock { detector.finish() } }
    /// The engine runs with the microphone.
    var listening: Bool { engineListens && engine?.isRunning == true }
    /// The engine runs, with or without the microphone.
    var running: Bool { engine?.isRunning == true }
    func currentPhrase() -> [Int16]? { lock.withLock { detector.current() } }

    /// Starts the engine if needed. Turning the microphone on or off rebuilds it (voice processing is fixed at setup).
    func ensureRunning(mic: Bool) throws {
        if engine?.isRunning == true, micWanted == mic, runningForCar == car { return }
        stop()
        micWanted = mic
        runningForCar = car
        let session = AVAudioSession.sharedInstance()
        if car {
            try session.setCategory(.playAndRecord, mode: .default)
        } else if mic {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio)
        }
        try session.setActive(true)
        guard mic else {
            // A released voice processing engine is torn down for about a second on a Mac, and until then the speaker
            // alone fails to start (-50). Keep trying for up to three seconds.
            for attempt in 0..<12 {
                do { return try startEngine(mic: false, setup: .plain) } catch where attempt < 11 {
                    stop()
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            return
        }
        // A failed start can be the device still rebuilding after the previous engine (-66628 on a Mac), so each way
        // gets a second try after a pause before a worse one is used.
        for (i, setup) in micSetups.enumerated() {
            for attempt in 0..<2 {
                do {
                    try startEngine(mic: true, setup: setup)
                    micSetups = Array(micSetups[i...])
                    return
                } catch {
                    stop()
                    if attempt == 1, setup == .voiceProcessingDirect { keptVoiceEngine = nil }
                    if i == micSetups.count - 1, attempt == 1 { throw error }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
    }

    private func startEngine(mic: Bool, setup: MicSetup) throws {
        let keep = mic && setup == .voiceProcessingDirect
        let engine = (keep ? keptVoiceEngine : nil) ?? AVAudioEngine()
        if keep { keptVoiceEngine = engine }
        // Held at once, so that stop() takes the player and the tap back from an engine that fails to start.
        self.engine = engine
        engineListens = mic
        if mic, setup != .plain, !engine.inputNode.isVoiceProcessingEnabled { try? engine.inputNode.setVoiceProcessingEnabled(true) }
        engine.attach(player)
        // Voice processing on a Mac refuses to start (-10875, "client-side input and output formats do not match")
        // while the main mixer feeds the output; the player going straight to the output starts.
        let direct = mic && setup == .voiceProcessingDirect
        engine.connect(player, to: direct ? engine.outputNode : engine.mainMixerNode, format: AudioFormats.playback)
        if mic {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw AppError("No microphone is available.") }
            resetDetector()
            carry = []
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.heard(buffer)
            }
        }
        let tapped = mic ? engine.inputNode.outputFormat(forBus: 0) : nil
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.configurationChanged(engine, tapped: tapped)
        }
        engine.prepare()
        try engine.start()
        player.play()
        warmUp()
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        player.stop()
        // Only an engine that listened has an input node to clean up: asking another one for it creates one, and on
        // a Mac that rebuilds the audio device and keeps the next start failing.
        if engineListens { engine?.inputNode.removeTap(onBus: 0) }
        engineListens = false
        engine?.stop()
        if let engine { engine.detach(player) }
        engine = nil
    }

    /// Stops and hands the audio back, so that whatever the car was playing resumes.
    func release() {
        stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Starting an engine itself reports a change, so a change alone is no reason to rebuild: that never ends and
    /// no audio gets through. Rebuild only when the route gave the microphone another format.
    /// A new engine drops what it gets first: the output is not up yet although the engine says it runs, so the
    /// first sentence after opening the app would go unheard. Silence goes first, and speech waits until it has played.
    private func warmUp() {
        let silence = AVAudioPCMBuffer(pcmFormat: AudioFormats.playback, frameCapacity: 19200)!
        silence.frameLength = 19200
        if let channel = silence.floatChannelData?[0] { memset(channel, 0, 19200 * MemoryLayout<Float>.size) }
        let id = lock.withLock { () -> Int in
            outputReady = false
            warmUpID += 1
            return warmUpID
        }
        player.scheduleBuffer(silence, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { if self.warmUpID == id { self.outputReady = true } }
        }
    }

    /// Also finishes whatever was waiting on the player, so a stuck output never holds up a whole answer.
    private func resetPlayer() {
        player.stop()
        if engine?.isRunning == true { player.play() }
    }

    private func waitForOutput() async {
        for _ in 0..<40 {
            if lock.withLock({ outputReady }) || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        resetPlayer()
    }

    private func configurationChanged(_ changed: AVAudioEngine, tapped: AVAudioFormat?) {
        guard changed === engine, !changed.isRunning else { return }
        if let tapped {
            let now = changed.inputNode.outputFormat(forBus: 0)
            if now.sampleRate != tapped.sampleRate || now.channelCount != tapped.channelCount {
                restart()
                return
            }
        }
        do {
            // The player keeps its old timeline across a stopped engine and would wait for it forever: start it anew.
            player.stop()
            try changed.start()
            player.play()
            warmUp()
        } catch {
            restart()
        }
    }

    private func restart() {
        let mic = micWanted
        stop()
        try? ensureRunning(mic: mic)
    }

    /// Returns when the clip has been heard, or at once when playback is stopped.
    func play(_ clip: AudioClip) async {
        await waitForOutput()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            guard engine != nil else { done.resume(); return }
            let secs = Double(clip.buffer.frameLength) / clip.buffer.format.sampleRate
            let finished = Finished()
            player.scheduleBuffer(clip.buffer, completionCallbackType: .dataPlayedBack) { _ in
                finished.set()
                done.resume()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + secs + 3) { [weak self] in
                if !finished.value {
                    self?.resetPlayer()
                }
            }
            if !player.isPlaying { player.play() }
        }
    }

    func stopPlayback() {
        player.stop()
        if engine?.isRunning == true { player.play() }
    }

    /// Audio thread. Box-averages channel 0 down to 16 kHz for the detector and the speech-to-text servers.
    private func heard(_ buffer: AVAudioPCMBuffer) {
        #if DEBUG
        if ignoresMicrophone { return }
        #endif
        guard let channel = buffer.floatChannelData?[0] else { return }
        let ratio = buffer.format.sampleRate / Double(PhraseDetector.sampleRate)
        carry.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let outCount = Int(Double(carry.count) / ratio)
        guard outCount > 0 else { return }
        var pcm = [Int16](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let from = Int(Double(i) * ratio), to = max(from + 1, Int(Double(i + 1) * ratio))
            var sum: Float = 0
            for j in from..<min(to, carry.count) { sum += carry[j] }
            let v = sum / Float(to - from)
            pcm[i] = Int16(max(-1, min(1, v)) * 32767)
        }
        carry.removeFirst(min(carry.count, Int(Double(outCount) * ratio)))
        let events = lock.withLock { detector.feed(pcm) }
        guard !events.isEmpty, let onEvent else { return }
        DispatchQueue.main.async { events.forEach(onEvent) }
    }
}
