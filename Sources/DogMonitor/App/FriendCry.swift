import AppKit
import AVFoundation

/// 누르면 소리: a short cry when a friend is clicked. The character's own sound files (a pack's or a 내 캐릭터's
/// sounds/ folder) when it has some, else a voice made in memory like ChimeSound: a dog barks (멍), a cat meows, every
/// other character chirps (뾱) at a pitch of its own. Off by default (커서 친구 > 누르면 소리).
enum FriendCry {
    enum Kind: CaseIterable { case normal, dizzy, sulk, hop }
    enum Voice: Equatable { case bark, meow, chirp(Double) }

    static let sampleRate = 22_050
    /// Own sound files: these types, at most `maxFiles`, each at most `maxBytes` and `maxSeconds` long.
    static let extensions: Set<String> = ["wav", "m4a", "mp3", "aiff", "aif", "caf"]
    static let maxFiles = 10, maxBytes = 2 * 1024 * 1024
    static let maxSeconds: TimeInterval = 3

    /// The cry for a reaction: hop and spin whoop up, dizzy wobbles down, a pout is a low 흥.
    static func kind(_ r: Reaction) -> Kind {
        switch r {
        case .dizzy: .dizzy
        case .pout: .sulk
        case .jump, .spin, .party: .hop
        default: .normal
        }
    }

    /// FNV-1a 32 of `id`: the same on every launch (String.hashValue is not).
    static func hash(_ id: String) -> UInt32 {
        id.utf8.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    /// A chirp's base pitch for character `id`: 520 to 1100 Hz.
    static func pitch(_ id: String) -> Double { 520 + Double(hash(id) % 581) }

    // MARK: Making a voice

    /// A mono 16-bit WAV of `voice` crying `kind`; `variant` (0...2) nudges the pitch so clicks in a row differ.
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
        return ChimeSound.wav(pcm, sampleRate: sampleRate)
    }

    // MARK: Whose voice

    /// Who `character` is (an original's id; nil = the character chosen now): its voice, and the folder its own
    /// sound files would be in.
    static func source(character: String?) -> (voice: Voice, folder: URL?) {
        let s = AppSettings.shared
        if let id = character { return (.chirp(pitch(id)), packFolder(id)) }
        switch s.shownCharacter {
        case .dog: return (.bark, nil)
        case .cat: return (.meow, nil)
        case .custom:
            let id = s.activeCustom?.id
            return (.chirp(pitch(id?.uuidString ?? "custom")), id.map { customFolder($0) })
        case .original:
            let id = s.originalID ?? "original"
            return (.chirp(pitch(id)), packFolder(id))
        }
    }

    static func customFolder(_ id: UUID, store: CustomCharacterStore = .shared) -> URL {
        store.folder(id).appendingPathComponent("sounds", isDirectory: true)
    }
    /// Only a pack that loaded (so its id passed the pack rules and its folder is no link) has a sounds folder.
    static func packFolder(_ id: String) -> URL? {
        OriginalCatalog.character(id) is CharacterPack
            ? CharacterPack.defaultRoot.appendingPathComponent(id).appendingPathComponent("sounds", isDirectory: true) : nil
    }

    /// The usable sound files in `folder` (a real directory, no link): plain files (no links) of a known type and
    /// size that AVAudioPlayer opens and that last at most `maxSeconds`, by name, at most `maxFiles`.
    static func files(in folder: URL) -> [URL] { checked(in: folder).map(\.url) }

    private static func checked(in folder: URL) -> [(url: URL, player: AVAudioPlayer)] {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType == .typeDirectory else { return [] }
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        return Array(names.lazy.compactMap { n in
            let url = folder.appendingPathComponent(n)
            return player(url).map { (url, $0) }
        }.prefix(maxFiles))
    }

    /// One sound file by those rules.
    static func usable(_ url: URL) -> Bool { player(url) != nil }

    /// The opened player of a sound file by those rules, else nil.
    private static func player(_ url: URL) -> AVAudioPlayer? {
        guard extensions.contains(url.pathExtension.lowercased()),
              let a = try? FileManager.default.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType == .typeRegular,
              let size = a[.size] as? Int, size > 0, size <= maxBytes,
              let p = try? AVAudioPlayer(contentsOf: url), p.duration > 0, p.duration <= maxSeconds else { return nil }
        return p
    }

    /// 소리 파일 넣기: copies the usable ones of `urls` into `folder` while it has room; how many it has then.
    @discardableResult
    static func add(_ urls: [URL], to folder: URL) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let had = Set(files(in: folder).map(\.lastPathComponent))
        var have = had.count
        for url in urls where have < maxFiles && usable(url) {
            let dest = folder.appendingPathComponent(url.lastPathComponent)
            guard dest.standardizedFileURL != url.standardizedFileURL else { continue }   // already in there
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: url, to: dest)) != nil, !had.contains(dest.lastPathComponent) { have += 1 }   // a same-name file only replaces
        }
        forget()
        return files(in: folder).count
    }

    /// 소리 지우기.
    static func clear(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        forget()
    }

    // MARK: Playing

    /// At most one cry at a time per friend, and `perSecond` in all.
    struct Limiter {
        static let perSecond = 6
        private var recent: [TimeInterval] = []
        private var busyUntil: [String: TimeInterval] = [:]

        /// True (and counted) when `friend` may cry a sound `length` long at `t`.
        mutating func allow(_ friend: String, at t: TimeInterval, length: TimeInterval) -> Bool {
            recent.removeAll { t - $0 >= 1 }
            if busyUntil.count > 64 { busyUntil = busyUntil.filter { $0.value > t } }   // folder friends come and go
            guard recent.count < Self.perSecond, t >= busyUntil[friend, default: 0] else { return false }
            recent.append(t)
            busyUntil[friend] = t + length
            return true
        }
    }

    private static var limiter = Limiter()
    private static var made: [String: AVAudioPlayer] = [:]
    private static var own: [URL: [AVAudioPlayer]] = [:]

    /// The players of `folder`'s usable files, opened once (rate on).
    private static func ownPlayers(_ folder: URL?) -> [AVAudioPlayer] {
        guard let folder else { return [] }
        if let p = own[folder] { return p }
        let p = checked(in: folder).map(\.player)
        p.forEach { $0.enableRate = true }
        own[folder] = p
        return p
    }

    /// After 소리 파일 넣기 or 지우기: the files are looked at again.
    static func forget() { own = [:] }

    /// `friend` (a stable name: "buddy", "clone-<uuid>") cries for reaction `r` if 누르면 소리 is on.
    static func play(_ r: Reaction, friend: String, character: String? = nil) { play(kind(r), friend: friend, character: character) }

    static func play(_ kind: Kind, friend: String, character: String? = nil, preview: Bool = false) {
        let m = MotionStore.shared
        guard preview || m.buddyCry, m.buddyCryVolume > 0, AppSettings.shared.friendSounds, !SpeechBubbleCenter.shared.isMuted() else { return }
        let src = source(character: character)
        let p: AVAudioPlayer, rate: Float, volume: Double
        if let file = ownPlayers(src.folder).randomElement() {   // dizzy, sulk and hop flavour a file by its speed
            (p, volume) = (file, m.buddyCryVolume)
            rate = switch kind { case .normal: Float.random(in: 0.95...1.05); case .dizzy: 0.8; case .sulk: 0.75; case .hop: 1.3 }
        } else {
            let variant = kind == .normal ? Int.random(in: 0..<3) : 0
            let key = "\(src.voice)-\(kind)-\(variant)"
            if made.count > 48 { made = [:] }
            guard let mp = made[key] ?? (try? AVAudioPlayer(data: make(src.voice, kind, variant: variant))) else { return }
            made[key] = mp
            (p, rate, volume) = (mp, 1, m.buddyCryVolume * 0.6)   // gentle: the made voices are bright
        }
        guard !p.isPlaying else { return }   // friends with one voice share a player: let the cry finish
        guard limiter.allow(friend, at: ProcessInfo.processInfo.systemUptime, length: p.duration / Double(rate)) else { return }
        p.rate = rate
        p.volume = Float(volume)
        p.currentTime = 0
        p.play()
    }
}
