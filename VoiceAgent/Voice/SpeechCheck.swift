import AVFoundation
import SoundAnalysis

/// Whether audio sounds like a person talking, from the iPhone's own sound classifier. Speech-to-text writes
/// words even for noise (Whisper's well-known "subtitles by" lines), so a word alone is not proof of speech.
enum SpeechCheck {
    /// The classifier's highest confidence for speech in any window of the clip, 0…1.
    static func confidence(_ pcm: [Int16], sampleRate: Int = PhraseDetector.sampleRate) -> Double {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return 0 }
        // The shortest window it allows, so half a second of speech is enough; a shorter clip is padded with silence.
        var window = 1.0
        if case .durationRange(let range) = request.windowDurationConstraint { window = max(range.start.seconds, 0.5) }
        request.windowDuration = CMTime(seconds: window, preferredTimescale: CMTimeScale(sampleRate))
        request.overlapFactor = 0.5
        let frames = max(pcm.count, Int(window * Double(sampleRate)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return 0 }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        for i in 0..<frames { out[i] = i < pcm.count ? Float(pcm[i]) / 32768 : 0 }
        let observer = Observer()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return 0 }
        analyzer.analyze(buffer, atAudioFramePosition: 0)
        analyzer.completeAnalysis()
        return observer.best
    }

    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        var best: Double { lock.withLock { value } }
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let speech = (result as? SNClassificationResult)?.classification(forIdentifier: "speech") else { return }
            lock.withLock { value = max(value, speech.confidence) }
        }
    }
}
