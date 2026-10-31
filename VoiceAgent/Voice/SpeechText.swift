import Foundation

/// Removes what a speech engine would read as symbols. No words are added or translated, so it works in any language.
func cleanForSpeech(_ text: String) -> String {
    var s = text
    let rules: [(String, String)] = [
        ("</?think>", ""),
        ("!\\[[^\\]]*\\]\\([^)]*\\)", ""),
        ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
        ("https?://\\S+", ""),
        ("`([^`]*)`", "$1"),
        ("(?m)^\\s{0,3}#{1,6}\\s+", ""),
        ("(?m)^\\s{0,3}>\\s?", ""),
        ("(?m)^\\s*[-*+•]\\s+", ""),
        ("(?m)^\\s*\\|.*\\|\\s*$", ""),
        ("[*_#`|~]", ""),
        ("[\\p{Extended_Pictographic}\\x{1F1E6}-\\x{1F1FF}\\x{1F3FB}-\\x{1F3FF}\\x{FE0F}\\x{200D}\\x{20E3}]", ""),
        ("\\s+([.,!?;:])", "$1"),
        ("\\s+", " "),
    ]
    for (pattern, template) in rules {
        s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isSpeakable(_ s: String) -> Bool { s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }

/// Cuts a streamed answer into pieces for the speech engine. A piece ends at sentence punctuation followed by a
/// space or at a line end; the first one may also end at a clause, so that the voice starts sooner. Code blocks are
/// not spoken. Language-neutral: no abbreviation lists, only "J. Smith" and "12. 3." style digits are protected.
final class SentenceSplitter {
    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", "»", "“", "”", ")", "]"]
    private var buf: [Character] = []
    private var inFence = false
    private var hold = ""
    private var emitted = false
    private let minChars: Int
    private let firstClauseChars: Int

    init(minChars: Int = 15, firstClauseChars: Int = 40) {
        self.minChars = minChars
        self.firstClauseChars = firstClauseChars
    }

    func push(_ delta: String) -> [String] {
        buf += Array(delta)
        return drain(final: false)
    }

    func flush() -> [String] {
        var out = drain(final: true)
        if !inFence { emit(buf, &out) }
        buf = []
        inFence = false
        if !hold.isEmpty {
            let s = cleanForSpeech(hold)
            hold = ""
            if isSpeakable(s) { out.append(s) }
        }
        return out
    }

    private func drain(final: Bool) -> [String] {
        var out: [String] = []
        var i = 0
        scan: while i < buf.count {
            if inFence {
                guard let end = find(fence, from: 0) else { buf = Array(buf.suffix(2)); return out }
                buf = Array(buf[(end + 3)...])
                inFence = false
                i = 0
                continue
            }
            let ch = buf[i]
            if ch == "`" {
                if !final, i + 3 > buf.count { break }
                if starts(fence, at: i) {
                    let eol = buf[(i + 3)...].firstIndex(of: "\n")
                    if eol == nil, !final { break }
                    emit(Array(buf[..<i]), &out)
                    buf = Array(buf[((eol ?? buf.count - 1) + 1)...])
                    inFence = true
                    i = 0
                    continue
                }
            }
            if ch == "\n" {
                cut(through: i, &out)
                i = 0
                continue
            }
            if !emitted, [",", ";", ":"].contains(ch), i + 1 >= firstClauseChars, i + 1 < buf.count, buf[i + 1].isWhitespace {
                cut(through: i, &out)
                i = 0
                continue
            }
            if Self.terminators.contains(ch) {
                var j = i + 1
                while j < buf.count, Self.terminators.contains(buf[j]) || Self.closers.contains(buf[j]) { j += 1 }
                if j >= buf.count {
                    if !final { break scan }
                } else if !buf[j].isWhitespace {
                    i = j
                    continue
                }
                if ch == ".", j == i + 1 {
                    switch periodEnds(dot: i, after: j, final: final) {
                    case .wait: break scan
                    case .no: i = j; continue
                    case .yes: break
                    }
                }
                cut(through: j - 1, &out)
                i = 0
                continue
            }
            i += 1
        }
        return out
    }

    private enum Verdict { case yes, no, wait }

    private func periodEnds(dot: Int, after: Int, final: Bool) -> Verdict {
        var start = dot
        while start > 0, buf[start - 1].isLetter || buf[start - 1].isNumber { start -= 1 }
        let word = buf[start..<dot]
        if word.count == 1, word.first!.isUppercase { return .no }
        if !word.isEmpty, word.allSatisfy(\.isNumber) {
            guard let next = buf[after...].first(where: { !$0.isWhitespace }) else { return final ? .yes : .wait }
            return next.isLowercase || next.isNumber ? .no : .yes
        }
        return .yes
    }

    private func cut(through end: Int, _ out: inout [String]) {
        emit(Array(buf[...end]), &out)
        buf = Array(buf[(end + 1)...])
    }

    private func emit(_ raw: [Character], _ out: inout [String]) {
        let text = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isSpeakable(cleanForSpeech(text)) else { return }
        let combined = hold.isEmpty ? text : "\(hold) \(text)"
        let spoken = cleanForSpeech(combined)
        if spoken.count < minChars { hold = combined; return }
        hold = ""
        emitted = true
        out.append(spoken)
    }

    private let fence: [Character] = ["`", "`", "`"]
    private func starts(_ p: [Character], at i: Int) -> Bool { i + p.count <= buf.count && Array(buf[i..<(i + p.count)]) == p }
    private func find(_ p: [Character], from: Int) -> Int? {
        guard buf.count >= p.count else { return nil }
        for i in from...(buf.count - p.count) where starts(p, at: i) { return i }
        return nil
    }
}

/// Finds phrases in 16 kHz mono audio by loudness against the measured background.
final class PhraseDetector {
    enum Event: Equatable { case started; case phrase([Int16]); case ended([Int16]); case discarded }

    static let sampleRate = 16000
    private static let frame = 320 // 20 ms
    private static let startFrames = 8
    private static let minVoicedFrames = 12
    private static let prerollFrames = 20
    private static let maxFrames = 60 * 50
    /// While the assistant talks and just after, speech has to start above this level (about −33 dBFS):
    /// what is left of its own voice stays below it, a person talking over it does not.
    private static let echoGate = 730.0
    // A piece of an utterance goes out at a short pause, once it is long enough to transcribe; never mid-word if it can be helped.
    private static let phrasePauseFrames = 10
    private static let minPhraseFrames = 35
    private static let minPhraseVoiced = 8
    private static let longPhraseFrames = 400
    private static let maxPhraseFrames = 600
    private static let echoTailFrames = 40

    var silenceMs = 800.0
    var sensitivity = 0.5
    /// Hand out pieces of the utterance while the user is still talking.
    var phrasesWanted = false
    /// While the assistant talks, the echo the phone could not cancel must not count as the user.
    var speaking = false

    private var pending: [Int16] = []
    private var floor = 100.0
    private var voicedRun = 0
    private var inSpeech = false
    private var silent = 0
    private var voiced = 0
    private var phrase: [Int16] = []
    private var preroll: [[Int16]] = []
    private var echoFrames = 0
    private var pieceStart = 0
    private var pieceVoiced = 0

    func reset() {
        pending = []
        voicedRun = 0
        inSpeech = false
        silent = 0
        voiced = 0
        phrase = []
        preroll = []
    }

    /// The phrase in progress when listening is turned off, if it had real speech in it.
    func finish() -> [Int16]? {
        defer { reset() }
        return inSpeech && voiced >= Self.minVoicedFrames ? phrase + pending : nil
    }

    func feed(_ samples: [Int16]) -> [Event] {
        pending += samples
        var events: [Event] = []
        var offset = 0
        while pending.count - offset >= Self.frame {
            process(Array(pending[offset..<(offset + Self.frame)]), &events)
            offset += Self.frame
        }
        if offset > 0 { pending.removeFirst(offset) }
        return events
    }

    private func cutPiece(_ events: inout [Event]) {
        let frames = (phrase.count - pieceStart) / Self.frame
        let atPause = silent == Self.phrasePauseFrames && frames >= Self.minPhraseFrames
        let tooLong = (frames >= Self.longPhraseFrames && silent > 0) || frames >= Self.maxPhraseFrames
        guard atPause || tooLong else { return }
        if pieceVoiced >= Self.minPhraseVoiced { events.append(.phrase(Array(phrase[pieceStart...]))) }
        pieceStart = phrase.count
        pieceVoiced = 0
    }

    private func process(_ f: [Int16], _ events: inout [Event]) {
        let rms = (f.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(f.count)).squareRoot()
        let ratio = 5 - 3 * sensitivity
        let minimum = 600 - 500 * sensitivity
        let threshold = max(minimum, floor * ratio)
        let voicedFrame = rms > threshold
        if speaking { echoFrames = Self.echoTailFrames } else if echoFrames > 0 { echoFrames -= 1 }

        if !inSpeech {
            // Only quiet frames say what the noise is; a voice must not raise the bar it has to clear.
            if !voicedFrame { floor += (rms - floor) * (rms > floor ? 0.03 : 0.2) }
            preroll.append(f)
            if preroll.count > Self.prerollFrames { preroll.removeFirst() }
            let startFrame = voicedFrame && (echoFrames == 0 || rms > Self.echoGate)
            voicedRun = startFrame ? voicedRun + 1 : max(0, voicedRun - 1)
            if voicedRun >= Self.startFrames {
                inSpeech = true
                phrase = preroll.flatMap { $0 }
                preroll = []
                voiced = voicedRun
                silent = 0
                pieceStart = 0
                pieceVoiced = voicedRun
                events.append(.started)
            }
            return
        }

        phrase += f
        if rms > threshold * 0.6 { voiced += 1; pieceVoiced += 1; silent = 0 } else { silent += 1 }
        if phrasesWanted { cutPiece(&events) }
        let silenceFrames = Int(silenceMs / 20)
        if silent >= silenceFrames || phrase.count >= Self.maxFrames * Self.frame {
            events.append(voiced >= Self.minVoicedFrames ? .ended(phrase) : .discarded)
            inSpeech = false
            phrase = []
            voicedRun = 0
        }
    }
}

func wavData(_ pcm: [Int16], sampleRate: Int) -> Data {
    var d = Data(capacity: 44 + pcm.count * 2)
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    d.append(contentsOf: "RIFF".utf8); u32(36 + pcm.count * 2)
    d.append(contentsOf: "WAVEfmt ".utf8); u32(16); u16(1); u16(1)
    u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
    d.append(contentsOf: "data".utf8); u32(pcm.count * 2)
    pcm.withUnsafeBufferPointer { p in
        p.withMemoryRebound(to: UInt8.self) { d.append($0) }
    }
    return d
}
