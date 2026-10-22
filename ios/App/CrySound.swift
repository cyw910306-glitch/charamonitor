import AVFoundation
import CharaCore

/// 누르면 소리: a short cry made in memory, like the Mac's FriendCry: a dog barks (멍), a cat meows, every other
/// character chirps (뾱) at a pitch of its own. Plays as ambient sound, so the silent switch mutes it.
enum CrySound {
    enum Kind { case normal, dizzy, sulk, hop }
    enum Voice: Equatable { case bark, meow, chirp(Double) }

    static let sampleRate = 22_050

    static func kind(_ r: Reaction) -> Kind {
        switch r {
        case .dizzy: .dizzy
        case .pout: .sulk
        case .jump, .spin: .hop
        default: .normal
        }
    }

    static func voice(_ art: CharaArt) -> Voice {
        switch art.kind {
        case .dog: .bark
        case .cat: .meow
        default: .chirp(520 + Double(hash(art.id) % 581))
        }
    }

    /// FNV-1a 32 of `id`: the same on every launch (String.hashValue is not).
    static func hash(_ id: String) -> UInt32 {
        id.utf8.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    /// A mono 16-bit WAV of `voice` crying `kind`; `variant` (0...2) nudges the pitch so taps in a row differ.
    static func make(_ voice: Voice, _ kind: Kind, variant: Int = 0) -> Data {
        let base: Double, harmonics: [Double]
        switch voice {
        case .bark: (base, harmonics) = (480, [1, 0.7, 0.45, 0.3])
        case .meow: (base, harmonics) = (620, [1, 0.5, 0.25])
        case .chirp(let f): (base, harmonics) = (f, [1, 0.25])
        }
        let f0 = base * [1, 1.06, 0.94][((variant % 3) + 3) % 3]
        let smooth: (Double) -> Double = { u in pow(sin(.pi * u), 0.7) }
        var seconds: Double, pitch: (Double) -> Double, amp: (Double) -> Double = smooth
        switch (kind, voice) {
        case (.normal, .bark):   // 멍: two quick pulses, each dropping
            seconds = 0.26
            pitch = { u in 1.25 - 0.45 * (u < 0.5 ? u * 2 : u * 2 - 1) }
            amp = { u in let x = (u < 0.5 ? u * 2 : u * 2 - 1) / 0.8; return x < 1 ? pow(sin(.pi * x), 0.5) : 0 }
        case (.normal, .meow):   // 야옹: up, then down, with a little vibrato
            seconds = 0.42
            pitch = { u in (u < 0.4 ? 1 + u : 1.4 - 0.55 * (u - 0.4) / 0.6) * (1 + 0.03 * sin(2 * .pi * 6 * 0.42 * u)) }
        case (.normal, .chirp):   // 뾱: a quick rise
            seconds = 0.2
            pitch = { u in 1 + 0.6 * sin(.pi * u / 2) }
        case (.dizzy, _):   // 꾸잉~: wobbling down
            seconds = 0.45
            pitch = { u in (1.15 - 0.45 * u) * (1 + 0.08 * sin(2 * .pi * 5 * u)) }
        case (.sulk, _):   // 흥: low and short
            seconds = 0.16
            pitch = { u in 0.72 - 0.12 * u }
        case (.hop, _):   // 우우웁: rising
            seconds = 0.3
            pitch = { u in 0.8 + 0.7 * u * u }
        }
        let n = Int(seconds * Double(sampleRate)), total = harmonics.reduce(0, +)
        var pcm = Data(capacity: n * 2), phase = 0.0
        for i in 0..<n {
            let u = Double(i) / Double(n)
            phase += 2 * .pi * f0 * pitch(u) / Double(sampleRate)
            var v = 0.0
            for (k, a) in harmonics.enumerated() { v += a * sin(Double(k + 1) * phase) }
            let s = Int16(max(-1, min(1, v / total * amp(u))) * 26_000)
            withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return wav(pcm)
    }

    static func wav(_ pcm: Data) -> Data {
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)   // PCM, mono
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        return wav + pcm
    }

    private static var made: [String: AVAudioPlayer] = [:]
    private static var sessionReady = false

    /// `art` cries for `r`, when 소리 is on. Main thread.
    static func play(_ r: Reaction, art: CharaArt) {
        guard SharedState.flag(SharedState.soundKey) else { return }
        if !sessionReady {
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
            sessionReady = true
        }
        let voice = voice(art), kind = kind(r), variant = kind == .normal ? Int.random(in: 0..<3) : 0
        let key = "\(voice)-\(kind)-\(variant)"
        if made.count > 48 { made = [:] }
        guard let p = made[key] ?? (try? AVAudioPlayer(data: make(voice, kind, variant: variant))) else { return }
        made[key] = p
        p.volume = 0.5   // gentle: the made voices are bright
        p.currentTime = 0
        p.play()
    }
}
