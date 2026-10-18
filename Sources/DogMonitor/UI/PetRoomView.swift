import AppKit
import SwiftUI

/// The 펫 키우기 room: PetRoomArt behind, the selected character walking on the floor in front, its evolution
/// accessory over the head. Everything at PetRoomArt.scale (3 pt per art px, the same as the dashboard sprite).
struct PetRoomView: View {
    let cache: DogSpriteCache
    let state: PetState
    let reaction: PetModel.Reaction?
    @StateObject private var walker = PetWalker()

    static let size = CGSize(width: CGFloat(PetRoomArt.width) * PetRoomArt.scale, height: CGFloat(PetRoomArt.height) * PetRoomArt.scale)

    var body: some View {
        let sprite = cache.imageSize
        let ground = Self.size.height - PetRoomArt.scale   // the character's feet, 1 art px above the bottom edge
        let top = ground - sprite.height
        let x = state.focus?.mode == .work ? (Self.size.width - sprite.width) / 2 : walker.x(range: Self.size.width - sprite.width)
        let frames = walker.shown(frames(), flipped: walker.facingLeft && !still)
        ZStack(alignment: .topLeading) {
            Image(decorative: PetRoomArt.room(wallpaper: state.wallpaper, floor: state.floor, slots: state.slots), scale: 1)
                .interpolation(.none).resizable()
                .frame(width: Self.size.width, height: Self.size.height)
            if !state.isAway, !frames.isEmpty {
                FramesPlayer(frames: frames, size: sprite, every: every, smooth: cache.smooth)
                    .frame(width: sprite.width, height: sprite.height)
                    .offset(x: x, y: top)
                if let acc = PetRoomArt.accessory(state.stage), let anchor = walker.anchor(frames) {
                    let s = PetRoomArt.scale
                    Image(decorative: acc.image, scale: 1).interpolation(.none).resizable()
                        .frame(width: CGFloat(acc.width) * s, height: CGFloat(acc.height) * s)
                        .offset(x: x + anchor.x * sprite.width - CGFloat(acc.width) * s / 2,
                                y: top + anchor.y * sprite.height - CGFloat(acc.height - 2) * s)
                        .accessibilityLabel("\(state.stage.title) 장식")
                }
                if state.focus?.mode == .work {
                    let d = PetRoomArt.desk
                    Image(decorative: d.image, scale: 1).interpolation(.none).resizable()
                        .frame(width: CGFloat(d.width) * PetRoomArt.scale, height: CGFloat(d.height) * PetRoomArt.scale)
                        .offset(x: (Self.size.width - CGFloat(d.width) * PetRoomArt.scale) / 2,
                                y: Self.size.height - CGFloat(d.height) * PetRoomArt.scale)
                }
                if let symbol = reactionSymbol {
                    Image(systemName: symbol.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(symbol.color)
                        .offset(x: x + sprite.width / 2 - 10, y: max(0, top - 22))
                        .transition(.opacity)
                }
            }
            if state.isAway { letter }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear { walker.start() }
        .onDisappear { walker.stop() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: What the character does

    private var hungry: Bool { state.food < 25 }
    private var sleepy: Bool { state.energy < 20 || state.focus?.mode == .rest }
    /// Standing in one place: eating, asleep, at the desk.
    private var still: Bool { reaction == .eat || sleepy || state.focus?.mode == .work }

    private func frames() -> [NSImage] {
        if reaction == .eat, let eat = cache.frames(forExtra: .eat) { return eat }
        if state.focus?.mode == .work { return cache.frames(for: .slowWalk) }
        if sleepy { return cache.frames(for: .lying) }
        if hungry, let h = cache.frames(forExtra: .hungry) { return h }
        let walk = cache.frames(for: .walk)
        return walker.paused ? Array(walk.prefix(1)) : walk
    }

    private var every: TimeInterval {
        if reaction == .eat { return DogSpriteCache.extraFrameDuration(.eat) }
        if sleepy { return DogSpriteCache.frameDuration(for: .lying, cpu: 0) }
        if hungry, cache.frames(forExtra: .hungry) != nil { return DogSpriteCache.extraFrameDuration(.hungry) }
        return DogSpriteCache.frameDuration(for: .walk, cpu: 0.2)
    }

    private var reactionSymbol: (name: String, color: Color)? {
        switch reaction {
        case .love: return ("heart.fill", .pink)
        case .wash: return ("sparkles", .cyan)
        case .eat, nil: return nil
        }
    }

    private var letter: some View {
        VStack(spacing: 6) {
            Image(systemName: "envelope.open.fill").font(.system(size: 22)).foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.4))
            Text("배가 너무 고파서 산책 나갔어요.\n밥을 주면 돌아올게요.")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(red: 0.35, green: 0.24, blue: 0.21))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 1, green: 0.97, blue: 0.92)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 0.35, green: 0.24, blue: 0.21).opacity(0.5)))
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var accessibilityText: String {
        if state.isAway { return L("펫 키우기 방. 캐릭터가 편지를 남기고 산책 나갔어요") }
        let doing = state.focus?.mode == .work ? L("책상에서 집중하는 중") : sleepy ? L("자는 중") : hungry ? L("배고파하는 중") : L("돌아다니는 중")
        return L("펫 키우기 방. 캐릭터가 \(doing)")
    }
}

/// Wanders the character left and right along the floor, with short stops. Runs only while the room is on screen.
final class PetWalker: ObservableObject {
    /// 0...1 along the floor.
    @Published private(set) var position = 0.5
    @Published private(set) var facingLeft = false
    @Published private(set) var paused = true
    private var target = 0.5
    private var wait = 8
    private var timer: Timer?
    private var mirrored: (key: [ObjectIdentifier], value: [NSImage]) = ([], [])
    /// Head points by image. The image is held here too, so its identifier cannot be reused by a later image while
    /// the entry lives; emptied whenever the mirrored set is made again (at most a few sets per room visit).
    private var anchors: [ObjectIdentifier: (image: NSImage, point: CGPoint?)] = [:]

    func x(range: CGFloat) -> CGFloat { (CGFloat(position) * max(0, range) / PetRoomArt.scale).rounded() * PetRoomArt.scale }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.step() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    deinit { timer?.invalidate() }

    private func step() {
        if wait > 0 {
            wait -= 1
            if wait == 0 {
                target = Double.random(in: 0...1)
                if abs(target - position) < 0.15 { target = position < 0.5 ? position + 0.4 : position - 0.4 }
                facingLeft = target < position
                paused = false
            }
            return
        }
        let stride = 0.012   // about one art px per step on the 372 pt room
        if abs(target - position) <= stride {
            position = target
            paused = true
            wait = Int.random(in: 10...35)
        } else {
            position += target > position ? stride : -stride
        }
    }

    /// The same frames facing left, made once per set (the art faces right).
    func shown(_ frames: [NSImage], flipped: Bool) -> [NSImage] {
        guard flipped else { return frames }
        let key = frames.map(ObjectIdentifier.init)
        if mirrored.key != key {
            mirrored = (key, frames.map(Self.mirror))
            anchors.removeAll()
        }
        return mirrored.value
    }

    /// Where the head is in `frames` (unit point, top of the head): the topmost drawn pixel in the half the character
    /// faces, so a raised tail does not get the crown.
    func anchor(_ frames: [NSImage]) -> CGPoint? {
        guard let first = frames.first else { return nil }
        let id = ObjectIdentifier(first)
        if let hit = anchors[id], hit.image === first { return hit.point }
        let found = Self.head(first, facingLeft: facingLeft && mirrored.value.contains { $0 === first })
        anchors[id] = (first, found)
        return found
    }

    static func head(_ image: NSImage, facingLeft: Bool) -> CGPoint? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = DogRenderer.context(width: cg.width, height: cg.height) else { return nil }
        let w = cg.width, h = cg.height
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h) else { return nil }
        func opaque(_ x: Int, _ y: Int) -> Bool { data[y * ctx.bytesPerRow + x * 4 + 3] > 0 }   // row 0 is the top
        var minX = w, maxX = -1
        for y in 0..<h { for x in 0..<w where opaque(x, y) { minX = min(minX, x); maxX = max(maxX, x) } }
        guard maxX >= minX else { return nil }
        let span = maxX - minX + 1
        let lo = facingLeft ? minX : minX + span * 2 / 5, hi = facingLeft ? maxX - span * 2 / 5 : maxX
        for y in 0..<h {
            let xs = (lo...hi).filter { opaque($0, y) }
            if let a = xs.first, let b = xs.last { return CGPoint(x: CGFloat(a + b) / 2 / CGFloat(w), y: CGFloat(y) / CGFloat(h)) }
        }
        return nil
    }

    static func mirror(_ image: NSImage) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            let t = NSAffineTransform()
            t.translateX(by: rect.width, yBy: 0)
            t.scaleX(by: -1, yBy: 1)
            t.concat()
            NSGraphicsContext.current?.imageInterpolation = .none
            image.draw(in: rect)
            return true
        }
    }
}
