import AVFoundation
import Speech
import XCTest
@testable import VoiceAgent

/// The iPhone app on a Mac: run with the destination "My Mac (Designed for iPad)". Skipped elsewhere.
final class MacProbeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.isiOSAppOnMac, "only on a Mac running the iPhone app")
    }

    private func speech(_ text: String, language: String) async throws -> [Int16] {
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        var out: [Int16] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !finished { finished = true; done.resume() }
                    return
                }
                let converter = AVAudioConverter(from: pcm.format, to: target)!
                let capacity = AVAudioFrameCount(Double(pcm.frameLength) * 16000 / pcm.format.sampleRate) + 16
                let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
                var given = false
                converter.convert(to: converted, error: nil) { _, status in
                    if given { status.pointee = .noDataNow; return nil }
                    given = true
                    status.pointee = .haveData
                    return pcm
                }
                let ch = converted.floatChannelData![0]
                out += (0..<Int(converted.frameLength)).map { Int16(max(-1, min(1, ch[$0])) * 32767) }
            }
        }
        return out
    }

    /// Voice processing used to stop the microphone on a Mac with -10875, and the retry right after it with -66628.
    func testMicrophoneStartsWithVoiceProcessing() throws {
        let audio = AudioIO()
        try audio.ensureRunning(mic: true)
        XCTAssertEqual(audio.micSetups.first, .voiceProcessingDirect, "the Mac keeps the echo cancellation")
        audio.release()
    }

    func testAppleSpeechRecognition() async throws {
        try XCTSkipUnless(SFSpeechRecognizer.authorizationStatus() == .authorized, "speech recognition not allowed yet")
        let pcm = try await speech("Dobrý den, toto je zkouška rozpoznávání řeči.", language: "cs-CZ")
        XCTAssertGreaterThan(SpeechCheck.confidence(pcm), 0.5)
        let text = try await AppleSTT(language: "cs-CZ").transcribe(wav: wavData(pcm, sampleRate: 16000))
        XCTAssertTrue(text.lowercased().contains("zkouška"), text)
    }
}
