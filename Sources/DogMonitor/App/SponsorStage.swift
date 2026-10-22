#if !MAS   // 후원 친구 (Sponsor.swift): the direct build only
import AppKit
import SwiftUI

/// The courier: the app's own 젤리 (DogProfile.defaultDog, built in) who brings the frame when the 커서 친구 may not
/// (it is off, or it shows a pack or a photo character: sponsor content is never carried by those). It walks in from the
/// nearer side of the cursor's screen to the floor under the cursor, waits there and walks back out the same way
/// (under 동작 줄이기 it just shows and fades). Clicking it opens the frame. It is out only during an offer.
final class SponsorCourier {
    var onClick: (() -> Void)?
    private var panel: NSPanel?
    private let view = CourierView(frame: .zero)
    private let sprite = SpriteView(frame: .zero)
    private var walk: (right: [NSImage], left: [NSImage]) = ([], [])
    private var stand: (right: [NSImage], left: [NSImage]) = ([], [])
    private var size = CGSize(width: 68, height: 40)
    private var pixelSize: CGFloat = 0
    private var x: CGFloat = 0, floorY: CGFloat = 0, exitX: CGFloat = 0
    private var target: CGFloat?
    private var leaving = false
    private var facingLeft = false
    private var clock: TimeInterval = 0
    private var frame = 0
    private var shown: [NSImage] = []

    var isOut: Bool { panel?.isVisible == true }
    var walking: Bool { isOut && target != nil }
    var arrived: Bool { isOut && target == nil && !leaving }
    func head() -> CGPoint? { isOut && !leaving ? CGPoint(x: x + size.width / 2, y: floorY + size.height) : nil }

    /// In from the side nearer the cursor; false when there is no screen.
    func enter() -> Bool {
        let cursor = NSEvent.mouseLocation
        guard let b = (NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main)?.visibleFrame else { return false }
        load()
        let still = DesktopKit.reduceMotion, fromLeft = cursor.x < b.midX
        let spot = min(max(cursor.x, b.minX + 60), b.maxX - 60) - size.width / 2
        exitX = fromLeft ? b.minX - size.width - 2 : b.maxX + 2
        floorY = b.minY
        x = still ? spot : exitX
        target = still ? nil : spot
        leaving = false
        facingLeft = !fromLeft
        let p = panel ?? makePanel()
        panel = p
        p.alphaValue = 1
        layout(moving: !still)
        p.orderFrontRegardless()
        return true
    }

    /// Back out the way it came, with a heart first when the frame was opened.
    func leave(happy: Bool) {
        guard isOut, !leaving else { return }
        leaving = true
        let still = DesktopKit.reduceMotion
        if happy, let l = view.layer {
            FriendMark.pop("♥", color: .systemPink, over: sprite.frame, in: l, still: still, scale: panel?.backingScaleFactor ?? 2)
        }
        guard still else { target = exitX; return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel?.animator().alphaValue = 0 }) { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    func step(dt: TimeInterval) {
        guard isOut else { return }
        if let to = target {
            let d = to - x, most = BuddyMath.speed * CGFloat(dt)
            if abs(d) > 0.5 { facingLeft = d < 0 }
            x = abs(d) <= most ? to : x + (d < 0 ? -most : most)
            if x == to {
                target = nil
                if leaving { panel?.orderOut(nil); return }
            }
        }
        clock += dt
        if clock >= 0.12 { clock = 0; frame += 1 }
        layout(moving: target != nil)
    }

    private func load() {
        let px = MotionStore.shared.buddySize.pixelSize
        guard px != pixelSize else { return }
        pixelSize = px
        let cache = DogSpriteCache(profile: .defaultDog, pixelSize: px, style: .auto)   // always the built-in 젤리
        size = cache.imageSize
        let f = BuddyGait.frames(cache)
        func both(_ g: BuddyGait) -> (right: [NSImage], left: [NSImage]) { let r = f[g] ?? []; return (r, r.map(CursorBuddy.mirrored)) }
        walk = both(.walk)
        stand = both(.stand)
    }

    private func layout(moving: Bool) {
        guard let p = panel else { return }
        let set = moving || stand.right.isEmpty ? walk : stand
        let frames = facingLeft ? set.left : set.right
        if frames != shown { shown = frames; sprite.setFrames(frames); frame = 0 }
        if !frames.isEmpty, !DesktopKit.reduceMotion { sprite.show(frame % frames.count) }
        // Room over its head for the heart.
        let r = CGRect(x: x, y: floorY, width: size.width, height: size.height * 2)
        if p.frame != r { p.setFrame(r, display: false) }
        sprite.frame = CGRect(origin: .zero, size: size)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]   // never over a full-screen app
        p.sharingType = .none
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        view.wantsLayer = true
        view.addSubview(sprite)
        view.onClick = { [weak self] in self?.onClick?() }
        p.contentView = view
        return p
    }
}

// ponytail: the whole sprite box takes the click (its see-through corners too); AlphaHit as the 커서 친구 if it gets in the way
private final class CourierView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The covered frame over the carrier's head, drawn in code: a small wooden frame (44 x 36 pt) under a pastel cloth
/// with a ✦. Click it to open: the cloth lifts, flips off to the side and falls away. Right click: its menu. On hover a
/// line over it says 눌러서 열어 보기 with an 오늘은 그만 capsule. The panel is bigger than the frame (room for that line
/// and the falling cloth) but takes the mouse only over the frame, and the line while it shows.
final class SponsorFrame {
    static let size = CGSize(width: 44, height: 36)
    private static let panelSize = CGSize(width: 220, height: 92)
    /// The frame's bottom in the panel: room under it for the cloth to fall.
    private static let low: CGFloat = 26

    var onOpen: (() -> Void)?
    var onStop: (() -> Void)?
    var onMenu: ((NSEvent, NSView) -> Void)?
    private var panel: NSPanel?
    private let view = FrameView(frame: CGRect(origin: .zero, size: panelSize))
    private let art = CALayer(), cloth = CAShapeLayer()
    private var hint: NSView?
    private var hovering = false
    /// How long the cloth takes to come off.
    private(set) var revealTime: TimeInterval = 0.6

    private var frameRect: CGRect { CGRect(x: (Self.panelSize.width - Self.size.width) / 2, y: Self.low, width: Self.size.width, height: Self.size.height) }
    private var hintRect: CGRect { CGRect(x: 0, y: Self.low + Self.size.height + 4, width: Self.panelSize.width, height: 26) }

    /// The frame on screen.
    var rect: CGRect {
        guard let p = panel else { return .zero }
        return frameRect.offsetBy(dx: p.frame.minX, dy: p.frame.minY)
    }

    /// Its top middle while it shows (the explanation bubble points here).
    var top: CGPoint? { panel?.isVisible == true ? CGPoint(x: rect.midX, y: rect.maxY) : nil }

    func place(over head: CGPoint) {
        guard let p = panel else { return }
        let o = CGPoint(x: (head.x - Self.panelSize.width / 2).rounded(), y: (head.y + 1 - Self.low).rounded())
        if p.frame.origin != o { p.setFrameOrigin(o) }
    }

    /// Up over the head, popping in.
    func show() {
        let p = panel ?? makePanel()
        panel = p
        hovering = false
        hint?.isHidden = true
        cloth.removeAllAnimations()
        cloth.opacity = 1
        p.ignoresMouseEvents = true
        p.orderFrontRegardless()
        guard !DesktopKit.reduceMotion else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.4
        pop.toValue = 1
        pop.damping = 11
        pop.duration = pop.settlingDuration
        art.add(pop, forKey: "pop")
    }

    func hide() { panel?.orderOut(nil) }

    /// Called every tick while it waits: the hint line on hover, and the mouse only over what is drawn.
    func hover(_ cursor: CGPoint) {
        guard let p = panel, p.isVisible else { return }
        let local = CGPoint(x: cursor.x - p.frame.minX, y: cursor.y - p.frame.minY)
        let onFrame = frameRect.insetBy(dx: -3, dy: -3).contains(local)
        if onFrame { hovering = true } else if !p.frame.contains(cursor) || local.y < Self.low { hovering = false }
        if hint?.isHidden == hovering { hint?.isHidden = !hovering }
        let take = onFrame || hovering && hintRect.contains(local)
        if p.ignoresMouseEvents == take { p.ignoresMouseEvents = !take }
    }

    /// The cloth comes off (a crossfade under 동작 줄이기).
    func reveal() {
        hint?.isHidden = true
        panel?.ignoresMouseEvents = true
        let still = DesktopKit.reduceMotion
        revealTime = still ? 0.2 : 0.6
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cloth.opacity = 0
        CATransaction.commit()
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = still ? [1, 0] : [1, 1, 0]
        guard !still else { fade.duration = 0.2; cloth.add(fade, forKey: "off"); return }
        let p = cloth.position
        let path = CAKeyframeAnimation(keyPath: "position")
        path.values = [p, CGPoint(x: p.x + 8, y: p.y + 16), CGPoint(x: p.x + 46, y: p.y - 30)].map { NSValue(point: $0) }
        path.keyTimes = [0, 0.35, 1]
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = [0, -0.5, -1.9]
        turn.keyTimes = [0, 0.35, 1]
        let group = CAAnimationGroup()
        group.animations = [fade, path, turn]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        cloth.add(group, forKey: "off")
    }

    private func makePanel() -> NSPanel {
        let p = FramePanel(contentRect: CGRect(origin: .zero, size: Self.panelSize), styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]   // never over a full-screen app
        p.sharingType = .none
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        view.wantsLayer = true
        view.onClick = { [weak self] in self?.onOpen?() }
        view.onMenu = { [weak self] e, v in self?.onMenu?(e, v) }
        view.takes = { [weak self] p in self?.frameRect.insetBy(dx: -3, dy: -3).contains(p) ?? false }
        draw(in: view.layer)
        let h = FirstClickHost(rootView: FrameHint(stop: { [weak self] in self?.onStop?() }))
        h.frame = hintRect
        h.isHidden = true
        view.addSubview(h)
        hint = h
        p.contentView = view
        return p
    }

    /// The wooden frame, its pale picture and the cloth over it, in the panel's layer.
    private func draw(in root: CALayer?) {
        guard let root else { return }
        let r = frameRect, scale = NSScreen.main?.backingScaleFactor ?? 2
        art.frame = r
        art.anchorPoint = CGPoint(x: 0.5, y: 0)
        art.position = CGPoint(x: r.midX, y: r.minY)
        root.addSublayer(art)
        let wood = CAShapeLayer()
        wood.path = CGPath(roundedRect: CGRect(x: 1, y: 1, width: r.width - 2, height: 31), cornerWidth: 3, cornerHeight: 3, transform: nil)
        wood.fillColor = RGBColor(hex: "#C98B55").nsColor.cgColor
        wood.strokeColor = RGBColor(hex: "#8A5A3C").nsColor.cgColor
        wood.lineWidth = 1.5
        let picture = CAShapeLayer()
        picture.path = CGPath(rect: CGRect(x: 6, y: 6, width: r.width - 12, height: 21), transform: nil)
        picture.fillColor = RGBColor(hex: "#FFF6EC").nsColor.cgColor
        // The cloth: thrown over the frame's top edge, hanging down both sides to a wavy hem; the frame's foot and a strip
        // of its picture show under it.
        cloth.frame = CGRect(x: -3, y: 11, width: r.width + 6, height: r.height - 10)
        let w = cloth.bounds.width, h = cloth.bounds.height
        let c = CGMutablePath()
        c.move(to: CGPoint(x: 0, y: 2))
        for (i, x) in stride(from: w / 6, through: w, by: w / 6).enumerated() {
            c.addQuadCurve(to: CGPoint(x: x, y: i % 2 == 0 ? 0 : 3), control: CGPoint(x: x - w / 12, y: i % 2 == 0 ? -2 : 4))
        }
        c.addLine(to: CGPoint(x: w - 1, y: h - 6))
        c.addQuadCurve(to: CGPoint(x: w - 7, y: h), control: CGPoint(x: w - 1, y: h))
        c.addLine(to: CGPoint(x: 7, y: h))
        c.addQuadCurve(to: CGPoint(x: 1, y: h - 6), control: CGPoint(x: 1, y: h))
        c.closeSubpath()
        cloth.path = c
        cloth.fillColor = RGBColor(hex: "#F7B6CF").nsColor.cgColor
        cloth.strokeColor = RGBColor(hex: "#DE7FA4").nsColor.cgColor
        cloth.lineWidth = 1.2
        let folds = CAShapeLayer()
        let f = CGMutablePath()
        for (top, bottom) in [(0.42, 0.3), (0.6, 0.72)] as [(CGFloat, CGFloat)] {
            f.move(to: CGPoint(x: w * top, y: h - 4))
            f.addQuadCurve(to: CGPoint(x: w * bottom, y: 4), control: CGPoint(x: w * (top + bottom) / 2 + 2, y: h / 2))
        }
        folds.path = f
        folds.fillColor = nil
        folds.strokeColor = NSColor(white: 1, alpha: 0.55).cgColor
        folds.lineWidth = 1
        cloth.addSublayer(folds)
        let star = CATextLayer()
        star.string = "✦"
        star.fontSize = 13
        star.foregroundColor = NSColor.white.cgColor
        star.alignmentMode = .center
        star.contentsScale = scale
        star.frame = CGRect(x: 0, y: h * 0.22, width: w, height: 16)
        cloth.addSublayer(star)
        for l in [wood, picture] as [CALayer] { l.contentsScale = scale; art.addSublayer(l) }
        art.addSublayer(cloth)
    }

    /// QA renders only: the frame's layer as it waits.
    func qaLayer() -> CALayer {
        if panel == nil { panel = makePanel() }
        return view.layer ?? art
    }
}

private final class FramePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FrameView: NSView {
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent, NSView) -> Void)?
    var takes: ((CGPoint) -> Bool)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard takes?(p) ?? false else { return }
        if event.modifierFlags.contains(.control) { onMenu?(event, self) } else { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event, self) }
}

/// The line over the frame on hover.
private struct FrameHint: View {
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("눌러서 열어 보기").font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.2))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.95)))
            Button(action: stop) {
                Text("오늘은 그만").font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color(white: 0.35).opacity(0.9)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The card (300 x 168 pt): a small floating panel above where the frame was. It stays on the space it opened on (never
/// on a full-screen one), is left out of screen shares, can be dragged by its header, and plays no sound.
final class SponsorCardWindow {
    static let size = CGSize(width: 300, height: 168)
    private let panel: NSPanel
    private var grab: (mouse: CGPoint, origin: CGPoint)?

    init(center: SponsorCenter, from: CGRect) {
        panel = FramePanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.ignoresCycle]
        panel.sharingType = .none
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        let host = FirstClickHost(rootView: SponsorCardLive(center: center) { [weak self] ended in self?.drag(ended: ended) })
        host.frame = CGRect(origin: .zero, size: Self.size)
        panel.contentView = host
        let screen = NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) } ?? NSScreen.main
        panel.setFrameOrigin(BuddyMath.clamp(CGPoint(x: from.midX - Self.size.width / 2, y: from.maxY + 6), size: Self.size,
                                             in: screen?.visibleFrame ?? .zero))
        panel.orderFrontRegardless()
    }

    /// On screen, on the space in front, not covered.
    var inView: Bool { panel.isVisible && panel.isOnActiveSpace && panel.occlusionState.contains(.visible) }

    func close() { panel.orderOut(nil) }

    private func drag(ended: Bool) {
        guard !ended else { grab = nil; return }
        let m = NSEvent.mouseLocation, g = grab ?? (m, panel.frame.origin)
        grab = g
        panel.setFrameOrigin(CGPoint(x: g.origin.x + m.x - g.mouse.x, y: g.origin.y + m.y - g.mouse.y))
    }
}

/// The card while it shows, following SponsorCenter.
struct SponsorCardLive: View {
    @ObservedObject var center: SponsorCenter
    var drag: (Bool) -> Void

    var body: some View {
        if let card = center.card {
            SponsorCardView(card: card, watched: center.watched, paused: center.paused, done: center.doneText,
                            close: { center.close() }, visit: { center.visit() }, drag: drag)
        }
    }
}

/// 후원 친구's card: the service's colour on top with its emoji and name, two lines about it, its button, and a ring
/// round the X filling over the 15 seconds to the gift. Once full, the gift that opened.
struct SponsorCardView: View {
    let card: SponsorCard
    var watched: TimeInterval = 0
    var paused = false
    var done: (title: String, detail: String)?
    var close: () -> Void = {}
    var visit: () -> Void = {}
    var drag: ((Bool) -> Void)?
    @State private var bob = false
    @State private var shine = false
    @State private var shown = false
    private var still: Bool { DesktopKit.reduceMotion }

    var body: some View {
        let brand = WeatherArt.color(card.color), ink = WeatherArt.color(SponsorRules.ink(on: card.color))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: card.emoji).font(.system(size: 17))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white))
                    .offset(y: bob ? -2 : 1)
                    .accessibilityHidden(true)
                Text(verbatim: card.title.shown).font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                ring(ink)
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(brand.overlay(shimmer).clipped())
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2).onChanged { _ in drag?(false) }.onEnded { _ in drag?(true) })
            VStack(alignment: .leading, spacing: 0) {
                if let done {
                    Text(verbatim: done.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(verbatim: done.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).padding(.top, 3)
                } else {
                    Text(verbatim: card.pitch.shown).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    Button(action: visit) {
                        Text(verbatim: card.cta.shown).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(brand))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(card.title.shown)
                    Spacer(minLength: 0)
                    Text(verbatim: paused ? L("잠깐 멈췄어요. 다시 보면 이어져요") : L("후원 친구 · 제작자 서비스 소개"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            .padding(12)
        }
        .frame(width: SponsorCardWindow.size.width, height: SponsorCardWindow.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .scaleEffect(shown || still ? 1 : 0.6, anchor: .bottom)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(still ? nil : .spring(response: 0.25, dampingFraction: 0.7)) { shown = true }
            guard !still else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bob = true }
            withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false).delay(0.4)) { shine = true }
        }
    }

    /// A soft light sweeping over the header now and then.
    private var shimmer: some View {
        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.28), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
            .frame(width: 90)
            .rotationEffect(.degrees(18))
            .offset(x: shine ? 260 : -260)
            .opacity(still ? 0 : 1)
            .allowsHitTesting(false)
    }

    /// The X in a ring that fills toward the gift.
    private func ring(_ ink: Color) -> some View {
        let left = max(0, Int((SponsorCenter.viewSeconds - watched).rounded(.up)))
        return ZStack {
            Circle().stroke(ink.opacity(0.25), lineWidth: 2.5)
            Circle().trim(from: 0, to: done != nil ? 1 : watched / SponsorCenter.viewSeconds)
                .stroke(ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(still ? nil : .linear(duration: 0.1), value: watched)
                .accessibilityElement()
                .accessibilityLabel(done != nil ? L("선물을 받았어요") : L("선물까지 \(left)초"))
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(ink)
                    .frame(width: 22, height: 22).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("닫기"))
        }
        .frame(width: 26, height: 26)
    }
}
#endif
