import AppKit
import AVFoundation
import Combine

/// Shared pieces for the 데스크톱 친구 (커서 친구, 대롱대롱 친구, 날씨 창문). Everything but `reduceMotion` is pure and tested
/// (DesktopTests). Coordinates are screen points with y up, like NSWindow frames.
enum DesktopKit {
    /// macOS 손쉬운 사용 > 동작 줄이기: no speed growth, tilt, wind or idle motion, a still pose only.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Fires when 동작 줄이기 (or another display option) changes; re-read `reduceMotion` then.
    static var displayOptionsChanged: AnyPublisher<Void, Never> {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .map { _ in () }.eraseToAnyPublisher()
    }
    /// "춤춰 줘", "응원해 줘", a focus well done: every desktop friend joins in (커서 친구, 대롱대롱 친구, 풀밭 친구들).
    static let celebrate = PassthroughSubject<PoseCard, Never>()
}

/// One frame's alpha mask, for click-through on transparent pixels: the window takes the mouse only over the drawing.
struct AlphaHit: Equatable {
    let width: Int, height: Int
    /// Row-major, top row first, 0...255.
    let alpha: [UInt8]

    /// Pixels at or above this alpha (0...1) count as the drawing.
    static let threshold = 0.3

    init(width: Int, height: Int, alpha: [UInt8]) {
        precondition(alpha.count == width * height)
        self.width = width; self.height = height; self.alpha = alpha
    }

    /// The image's alpha at its own pixel size (nil for an empty image). Build once per frame, not per tick.
    init?(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0, cg.height > 0 else { return nil }
        var a = [UInt8](repeating: 0, count: cg.width * cg.height)
        let drawn = a.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))   // the context's memory is top row first
            return true
        }
        guard drawn else { return nil }
        self.init(width: cg.width, height: cg.height, alpha: a)
    }

    /// Whether `point` (in a view of `size`, y up, the frame stretched over it) lands on the drawing.
    func hits(_ point: CGPoint, in size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height else { return false }
        let x = Int(point.x / size.width * CGFloat(width))
        let y = Int((1 - point.y / size.height) * CGFloat(height))
        return Double(alpha[min(height - 1, y) * width + min(width - 1, x)]) >= Self.threshold * 255
    }
}

/// Turns mouse down/move/up into one single click, a double click or a drag. Feed it events and `poll` it once
/// `pollAt` has passed: a single click is only sure when no second click came within `doubleWindow`.
struct ClickRecognizer {
    enum Gesture: Equatable {
        case single(CGPoint), double(CGPoint)
        case dragBegan(CGPoint), dragged(CGPoint)
        /// `velocity` in points per second at release, zero when the hand stopped before letting go (a drop, not a throw).
        case dragEnded(CGPoint, velocity: CGVector)
    }

    static let doubleWindow: TimeInterval = 0.28
    /// Moving this far with the button down makes it a drag.
    static let slop: CGFloat = 4
    /// Held still this long before release: no throw.
    static let throwStale: TimeInterval = 0.1

    private var down: (p: CGPoint, t: TimeInterval)?
    private var pending: (p: CGPoint, t: TimeInterval)?   // a first click waiting for its pair
    private var second = false
    private var dragging = false
    private var last: (p: CGPoint, t: TimeInterval)?
    private var velocity = CGVector.zero

    /// When to call `poll` to get a waiting single click (nil: nothing waits).
    var pollAt: TimeInterval? { pending.map { $0.t + Self.doubleWindow } }

    /// A press; returns the earlier single click when its window ran out before anyone polled.
    mutating func mouseDown(_ p: CGPoint, at t: TimeInterval) -> [Gesture] {
        let late = poll(at: t)
        second = pending != nil
        down = (p, t); last = (p, t); velocity = .zero; dragging = false
        return late
    }

    mutating func mouseMoved(_ p: CGPoint, at t: TimeInterval) -> [Gesture] {
        guard let d = down else { return [] }
        if let l = last, t > l.t { velocity = CGVector(dx: (p.x - l.p.x) / (t - l.t), dy: (p.y - l.p.y) / (t - l.t)) }
        last = (p, t)
        if dragging { return [.dragged(p)] }
        guard hypot(p.x - d.p.x, p.y - d.p.y) > Self.slop else { return [] }
        dragging = true; pending = nil; second = false
        return [.dragBegan(d.p), .dragged(p)]
    }

    mutating func mouseUp(_ p: CGPoint, at t: TimeInterval) -> [Gesture] {
        guard down != nil else { return [] }
        down = nil
        if dragging {
            dragging = false
            let fresh = last.map { t - $0.t <= Self.throwStale } ?? false
            return [.dragEnded(p, velocity: fresh ? velocity : .zero)]
        }
        if second { second = false; pending = nil; return [.double(p)] }
        pending = (p, t)
        return []
    }

    /// The waiting single click once its double-click window is over.
    mutating func poll(at t: TimeInterval) -> [Gesture] {
        guard let w = pending, down == nil, t - w.t > Self.doubleWindow else { return [] }
        pending = nil
        return [.single(w.p)]
    }
}

/// A friend hanging from `anchor` on a springy string: a damped spring pendulum. Drag it (`grab`/`drag`),
/// let go with a throw (`release`), blow on it (`wind`). Step it every frame; stop the timer once `isSettled`.
struct Dangle {
    var anchor: CGPoint
    var restLength: CGFloat
    /// Spring and gravity per unit mass: it hangs `gravity / stiffness` below `restLength`.
    var stiffness: CGFloat = 60
    var gravity: CGFloat = 900
    /// Velocity lost per second (1/s); higher settles sooner.
    var damping: CGFloat = 1.8
    /// The string never gets longer than this many rest lengths.
    var maxStretch: CGFloat = 2.5
    /// A string that does not stretch: it swings on a fixed radius (`hangLength`) like a swing ride, no bounce.
    var taut = false
    static let maxThrow: CGFloat = 3000

    private(set) var position: CGPoint
    private(set) var velocity = CGVector.zero
    private(set) var held = false

    init(anchor: CGPoint, restLength: CGFloat) {
        self.anchor = anchor
        self.restLength = restLength
        position = .zero
        position = equilibrium
    }

    /// String length when it hangs still: rest plus the sag, but never past the longest string (a short string pins there).
    var hangLength: CGFloat { min(restLength + gravity / stiffness, restLength * maxStretch) }
    /// Where it rests with no wind.
    var equilibrium: CGPoint { CGPoint(x: anchor.x, y: anchor.y - hangLength) }
    /// Swing angle from straight down in radians, positive when it swings right (rotate the sprite by it).
    var angle: CGFloat { atan2(position.x - anchor.x, anchor.y - position.y) }
    /// String length over the hanging length (1 = hanging still): squash and stretch the sprite by it.
    var stretch: CGFloat { hypot(position.x - anchor.x, position.y - anchor.y) / hangLength }
    var isSettled: Bool {
        !held && hypot(velocity.dx, velocity.dy) < 2 && hypot(position.x - equilibrium.x, position.y - equilibrium.y) < 0.5
    }

    mutating func grab(at p: CGPoint) { held = true; drag(to: p) }
    mutating func drag(to p: CGPoint) { guard held else { return }; position = limited(p); velocity = .zero }
    /// Lets go; `velocity` from ClickRecognizer.dragEnded throws it.
    mutating func release(velocity v: CGVector = .zero) {
        held = false
        let s = hypot(v.dx, v.dy), k = s > Self.maxThrow ? Self.maxThrow / s : 1
        velocity = CGVector(dx: v.dx * k, dy: v.dy * k)
    }

    /// A push while it hangs free (a cursor brushing past, a cheer): adds `v`, the speed capped at `maxThrow`.
    mutating func nudge(_ v: CGVector) {
        guard !held else { return }
        release(velocity: CGVector(dx: velocity.dx + v.dx, dy: velocity.dy + v.dy))
    }

    /// A knock from a neighbour: moved by `d`, its velocity now `v`. Nothing while held.
    mutating func bump(by d: CGVector, velocity v: CGVector) {
        guard !held else { return }
        position = limited(CGPoint(x: position.x + d.dx, y: position.y + d.dy))
        velocity = v
        if taut { onCircle() }
    }

    /// Advances `dt` seconds (capped at 0.1). `wind`: sideways push in points per second squared, + to the right.
    mutating func step(dt: TimeInterval, wind: CGFloat = 0) {
        guard !held else { return }
        var left = min(0.1, max(0, dt))
        while left > 0 {   // fixed small steps: stable for any frame rate
            let h = CGFloat(min(left, 1.0 / 240)); left -= Double(h)
            let dx = position.x - anchor.x, dy = position.y - anchor.y
            let len = max(0.001, hypot(dx, dy))
            let pull = taut ? 0 : -stiffness * (len - restLength) / len
            velocity.dx += (pull * dx + wind - damping * velocity.dx) * h
            velocity.dy += (pull * dy - gravity - damping * velocity.dy) * h
            position = limited(CGPoint(x: position.x + velocity.dx * h, y: position.y + velocity.dy * h))
            if taut { onCircle() }
        }
    }

    /// Taut: back on the circle of `hangLength` round the anchor, the speed along the string gone.
    private mutating func onCircle() {
        let dx = position.x - anchor.x, dy = position.y - anchor.y, len = max(0.001, hypot(dx, dy))
        let ux = dx / len, uy = dy / len, r = hangLength
        position = CGPoint(x: anchor.x + ux * r, y: anchor.y + uy * r)
        let out = velocity.dx * ux + velocity.dy * uy
        velocity.dx -= out * ux; velocity.dy -= out * uy
    }

    /// Keeps `p` within the longest string; at the limit the outward speed goes.
    private mutating func limited(_ p: CGPoint) -> CGPoint {
        let dx = p.x - anchor.x, dy = p.y - anchor.y, len = hypot(dx, dy), most = restLength * maxStretch
        guard len > most else { return p }
        let ux = dx / len, uy = dy / len
        let out = velocity.dx * ux + velocity.dy * uy
        if out > 0 { velocity.dx -= out * ux; velocity.dy -= out * uy }
        return CGPoint(x: anchor.x + ux * most, y: anchor.y + uy * most)
    }
}

/// The cursor's speed and how often it shakes: fast left-right reversals within `window`.
struct CursorMotion {
    static let window: TimeInterval = 0.8
    /// Only reversals faster than this sideways count as shaking.
    static let shakeSpeed: CGFloat = 900
    /// This many reversals within `window` = being shaken.
    static let shakeFlips = 4
    static let maxSpeed: CGFloat = 6000

    /// Points per second from the last two samples, capped at `maxSpeed`.
    private(set) var speed: CGFloat = 0
    private(set) var velocity = CGVector.zero
    private var last: (p: CGPoint, t: TimeInterval)?
    private var side = 0
    private var flips: [TimeInterval] = []

    /// Fast reversals within `window` of the last sample.
    var directionChanges: Int { flips.count }
    var isShaking: Bool { flips.count >= Self.shakeFlips }

    /// One cursor sample; `t` monotonic seconds (systemUptime).
    mutating func feed(_ p: CGPoint, at t: TimeInterval) {
        defer { last = (p, t) }
        guard let l = last, t > l.t else { return }
        let dt = CGFloat(t - l.t)
        velocity = CGVector(dx: (p.x - l.p.x) / dt, dy: (p.y - l.p.y) / dt)
        speed = min(Self.maxSpeed, hypot(velocity.dx, velocity.dy))
        flips.removeAll { t - $0 > Self.window }
        guard abs(velocity.dx) > Self.shakeSpeed else { return }
        let now = velocity.dx > 0 ? 1 : -1
        if side != 0, now != side { flips.append(t) }
        side = now
    }

    /// Forget the shaking (after reacting to it).
    mutating func reset() { flips = []; side = 0 }
}

/// A small glass chime made in memory: no sound files. Each 대롱대롱 친구 rings its own note of one pentatonic scale,
/// so several at once still sound together.
enum ChimeSound {
    /// (frequency ratio to the note, loudness, decay per second). Our own bell-like overtones.
    typealias Partial = (ratio: Double, amp: Double, decay: Double)
    static let partials: [Partial] = [(1, 1, 2.4), (2.4, 0.42, 4.2), (4.1, 0.2, 7), (6.8, 0.08, 11)]
    /// A major pentatonic from E6, one per hanging slot.
    static let notes: [Double] = [1318.5, 1480, 1661.2, 1975.5, 2217.5]
    static let sampleRate = 44_100
    static let seconds = 1.6

    /// A mono 16-bit PCM WAV of decaying sine partials, with a 2 ms fade-in against the click.
    static func make(freq: Double, partials: [Partial] = partials, seconds: Double = seconds, sampleRate: Int = sampleRate) -> Data {
        let n = max(0, Int(seconds * Double(sampleRate)))
        let total = partials.reduce(0) { $0 + $1.amp }
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let t = Double(i) / Double(sampleRate)
            var v = 0.0
            for p in partials { v += p.amp * exp(-p.decay * t) * sin(2 * .pi * freq * p.ratio * t) }
            let s = Int16(max(-1, min(1, v / max(total, 1) * min(1, t / 0.002))) * 30_000)
            withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)   // PCM, mono
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        return wav + pcm
    }

    private static var players: [Int: AVAudioPlayer] = [:]
    private static var lastRing: TimeInterval = 0

    /// Rings note `index` (wrapped) at `volume` 0...1, at most every 0.15 s and never while the bubble is muted (meetings).
    static func play(_ index: Int, volume: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard volume > 0, now - lastRing >= 0.15, !SpeechBubbleCenter.shared.isMuted() else { return }
        lastRing = now
        let i = ((index % notes.count) + notes.count) % notes.count
        if players[i] == nil { players[i] = try? AVAudioPlayer(data: make(freq: notes[i])) }
        guard let p = players[i] else { return }
        p.volume = Float(min(1, volume))
        p.currentTime = 0
        p.play()
    }
}
