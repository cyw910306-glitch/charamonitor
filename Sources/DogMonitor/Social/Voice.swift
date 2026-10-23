import AppKit
import AVFoundation

// 무전기: push to talk to one paired friend. The mic is open only while the talk button is held (30 s at most) and
// the button shows it; nothing listens otherwise. 16 kHz mono Int16 in 20 ms frames, no codec.
// ponytail: no hotkey (a global key path the app avoids) and one friend heard at a time; a Carbon hot key with a
// release event, and a mixer per friend, if people ask.

enum VoiceCodec {
    static let sampleRate = 16_000.0
    static let frameSamples = 320
    static let frameBytes = 640

    /// -1...1 floats to Int16 little-endian, clamped.
    static func encode(_ samples: [Float]) -> Data {
        var out = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: v) { out.append(contentsOf: $0) }
        }
        return out
    }

    static func decode(_ data: Data) -> [Float] {
        stride(from: 0, to: data.count - 1, by: 2).map { i in
            let v = Int16(bitPattern: UInt16(data[data.startIndex + i]) | UInt16(data[data.startIndex + i + 1]) << 8)
            return Float(v) / Float(Int16.max)
        }
    }
}

/// Cuts captured bytes into 640-byte frames; the rest waits for the next push.
struct VoiceChunker {
    private var pending = Data()

    mutating func push(_ d: Data) -> [Data] {
        pending.append(d)
        var out: [Data] = []
        while pending.count >= VoiceCodec.frameBytes {
            out.append(Data(pending.prefix(VoiceCodec.frameBytes)))
            pending.removeFirst(VoiceCodec.frameBytes)
        }
        return out
    }
}

/// The receive side's order: playback starts after 3 frames (60 ms); a frame older than the last played is dropped.
struct VoiceJitter {
    private var waiting: [(seq: UInt32, pcm: Data)] = []
    private(set) var last: UInt32?
    private(set) var started = false

    /// What to play now, in order.
    mutating func push(_ seq: UInt32, _ pcm: Data) -> [Data] {
        if let last, seq <= last { return [] }
        guard started else {
            waiting.append((seq, pcm))
            guard waiting.count >= 3 else { return [] }
            started = true
            let out = waiting.sorted { $0.seq < $1.seq }
            waiting = []
            last = out.last?.seq
            return out.map(\.pcm)
        }
        last = seq
        return [pcm]
    }
}

/// The hearing side's cap: one talk plays 30 s at most, and a frame is dropped while 0.5 s is already queued, so a
/// sender faster than playback never grows the queue or keeps the speaker busy.
struct VoiceBudget {
    static let maxQueued: TimeInterval = 0.5
    private var start: TimeInterval?
    private var playhead: TimeInterval = 0

    mutating func admit(now: TimeInterval) -> Bool {
        let begun = start ?? now
        start = begun
        guard now - begun < VoiceTalk.maxSeconds else { return false }
        playhead = max(playhead, now)
        guard playhead - now < Self.maxQueued else { return false }
        playhead += Double(VoiceCodec.frameSamples) / VoiceCodec.sampleRate
        return true
    }
}

/// The talk side. `live` is the friend hearing me (the button turns red "말하는 중").
final class VoiceTalk: ObservableObject {
    static let shared = VoiceTalk()
    static let maxSeconds: TimeInterval = 30
    @Published private(set) var live: String?
    private var engine: AVAudioEngine?
    private var chunker = VoiceChunker()
    /// Keeps counting across talks, so a talk right after the last one is never taken for its old frames.
    private var seq: UInt32 = 0
    private var cutoff: DispatchWorkItem?

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.end()
        }
    }

    static var allowed: Bool {
        PluginGate.isOpen(.walkieTalkie) && SocialBus.shared.defaults.bool(forKey: "social.voice") && SocialBus.shared.isOn
    }

    /// The button went down. The first press only asks for the mic.
    func begin(_ friendID: String) {
        guard live == nil, Self.allowed, SocialBus.shared.online.contains(friendID) else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: open(friendID)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            SpeechBubbleCenter.shared.say(text: L("마이크가 꺼져 있어요. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 캐릭모니터를 켜 주세요."),
                                          source: .system, aloud: false, repeats: true)
        }
    }

    private func open(_ friendID: String) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: VoiceCodec.sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: out) else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * VoiceCodec.sampleRate / inFormat.sampleRate) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: converted, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard let samples = converted.int16ChannelData?[0], converted.frameLength > 0 else { return }
            let data = Data(bytes: samples, count: Int(converted.frameLength) * 2)
            DispatchQueue.main.async { self?.captured(data) }
        }
        do { try engine.start() } catch { input.removeTap(onBus: 0); return }
        self.engine = engine
        chunker = VoiceChunker()
        live = friendID
        let cut = DispatchWorkItem { [weak self] in self?.end() }
        cutoff = cut
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxSeconds, execute: cut)
    }

    private func captured(_ data: Data) {
        guard let id = live else { return }
        for frame in chunker.push(data) {
            seq &+= 1
            SocialBus.shared.send(.voice(seq: seq, pcm: frame), to: id)
        }
    }

    /// Button up, window closed, app in the background, 30 s, or 근처 친구 off: the mic goes off at once.
    func end() {
        cutoff?.cancel(); cutoff = nil
        guard let id = live else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        live = nil
        SocialBus.shared.send(.voiceEnd, to: id)
    }
}

/// The hearing side: one engine while someone talks, stopped 1 s after their last frame.
final class VoicePlayer {
    static let shared = VoicePlayer()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var jitter = VoiceJitter()
    private var budget = VoiceBudget()
    private(set) var speaking: String?
    private var idle: DispatchWorkItem?
    /// A friend whose talk was dropped in a meeting, so the chat says it once per talk.
    private var noted: Set<String> = []
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceCodec.sampleRate, channels: 1, interleaved: false)!

    func receive(_ m: SocialMessage, from id: String) {
        guard VoiceTalk.allowed else { return }
        guard case let .voice(seq, pcm) = m else {
            noted.remove(id)
            if speaking == id {
                // The talk is over: the next one starts afresh (its frames may count from 1 again).
                jitter = VoiceJitter()
                budget = VoiceBudget()
                stopSoon(1)
            }
            return
        }
        guard pcm.count <= VoiceCodec.frameBytes, pcm.count % 2 == 0 else { return }
        if FriendVisit.quiet() {
            if noted.insert(id).inserted { SocialChat.shared.append(id, L("회의 중이라 무전을 듣지 않았어요"), mine: false, note: true) }
            return
        }
        if speaking != id {
            stop()
            speaking = id
            jitter = VoiceJitter()
            budget = VoiceBudget()
            let name = SocialBus.shared.friend(id)?.nickname ?? L("친구")
            _ = FriendVisit.shared.show(id, line: L("🔊 \(name) 말하는 중"), named: false)
        }
        let now = ProcessInfo.processInfo.systemUptime
        for frame in jitter.push(seq, pcm) where budget.admit(now: now) { play(frame) }
        stopSoon(1)
    }

    /// The friend went offline.
    func gone(_ id: String) { if speaking == id { stop() } }

    private func play(_ pcm: Data) {
        if engine == nil {
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: format)
            guard (try? e.start()) != nil else { return }
            p.play()
            engine = e
            player = p
        }
        let samples = VoiceCodec.decode(pcm)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        player?.scheduleBuffer(buffer)
    }

    private func stopSoon(_ seconds: TimeInterval) {
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func stop() {
        idle?.cancel(); idle = nil
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        speaking = nil
    }
}
