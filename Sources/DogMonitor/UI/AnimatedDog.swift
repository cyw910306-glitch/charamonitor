import AppKit
import SwiftUI

/// Keeps one large DogSpriteCache and rebuilds it only when the look or the character changes (the name does not count).
final class SpriteHolder: ObservableObject {
    private var key: SpriteLook?
    private var current: DogSpriteCache?

    /// Largest whole pixel size (at most 4) that keeps the sprite within about 120 x 72 pt.
    static let pixelSize: CGFloat = CGFloat(max(1, min(4, 120 / max(1, DogSpriteCache.canvasWidth),
                                                        72 / max(1, DogSpriteCache.canvasHeight))))

    /// The character selected in `settings`, as the menu bar shows it.
    func cache(for settings: AppSettings) -> DogSpriteCache {
        let look = SpriteLook(settings)
        if let current, key == look { return current }
        let fresh = DogSpriteCache(look, pixelSize: Self.pixelSize)
        key = look
        current = fresh
        return fresh
    }
}

/// Plays precomputed frames through a layer. Only `layer.contents` swaps per tick, and only while in a window.
struct AnimatedDog: NSViewRepresentable {
    let cache: DogSpriteCache
    let pose: DogPose
    let cpu: Double

    func makeNSView(context: Context) -> AnimatedSpriteView {
        let v = AnimatedSpriteView()
        v.setAccessibilityElement(false)
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: AnimatedSpriteView, context: Context) {
        // Quantized so small CPU wiggles do not restart the timer every second.
        let d = max(0.04, (DogSpriteCache.frameDuration(for: pose, cpu: cpu) * 50).rounded() / 50)
        v.play(cache.frames(for: pose), every: d, smooth: cache.smooth)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimatedSpriteView, context: Context) -> CGSize? {
        cache.imageSize
    }
}

/// Shows one precomputed frame as the backing layer's contents. `show(_:)` is a pointer swap, no redraw.
class SpriteView: NSView {
    private var images: [NSImage] = []
    private var contents: [Any] = []
    /// Illustration frames (an HD pack): drawn with high-quality interpolation, never nearest.
    private var smooth = false
    private(set) var index = 0
    var frameCount: Int { images.count }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.magnificationFilter = .nearest
        layer?.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { applyContents() }
    // Offscreen renders (cacheDisplay) take the drawing path.
    override func draw(_ dirtyRect: NSRect) {
        guard index < images.count else { return }
        NSGraphicsContext.current?.imageInterpolation = smooth ? .high : .none
        images[index].draw(in: bounds)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks belong to the container

    func setFrames(_ frames: [NSImage], smooth: Bool = false) {
        images = frames
        self.smooth = smooth
        layer?.magnificationFilter = smooth ? .linear : .nearest
        layer?.minificationFilter = smooth ? .trilinear : .linear
        index = 0
        rebuildContents()
    }

    func show(_ i: Int) {
        guard !contents.isEmpty else { return }
        index = i % contents.count
        applyContents()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildContents()
    }

    private func rebuildContents() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        // Baked under this view's appearance, so a light/dark frame (일러스트) matches the menu bar it sits on.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            contents = images.map { smooth ? (Self.bitmap($0, scale: scale) ?? $0) : $0.layerContents(forContentsScale: scale) }
        }
        applyContents()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildContents()
    }

    /// `image` rendered once at exactly its size x `scale` pixels with high-quality interpolation, so the layer never
    /// resamples an illustration (the menu bar takes the pack's made-ahead 2x copy as is).
    static func bitmap(_ image: NSImage, scale: CGFloat) -> CGImage? {
        let w = Int((image.size.width * scale).rounded()), h = Int((image.size.height * scale).rounded())
        guard w > 0, h > 0, let ctx = DogRenderer.context(width: w, height: h) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = g
        ctx.scaleBy(x: scale, y: scale)
        g.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: image.size))
        return ctx.makeImage()
    }

    private func applyContents() {
        guard index < contents.count else { return }
        layer?.contents = contents[index]
    }
}

/// SpriteView with its own frame timer, which runs only while the view is in a window.
final class AnimatedSpriteView: SpriteView {
    private var timer: Timer?
    private var step: TimeInterval = 0
    private var current: [NSImage] = []

    func play(_ frames: [NSImage], every d: TimeInterval, smooth: Bool = false) {
        guard frames != current || d != step else { return }
        if frames != current {
            current = frames
            setFrames(frames, smooth: smooth)
        }
        step = d
        restartTimer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard window != nil, frameCount > 1, step > 0 else { return }
        let t = Timer(timeInterval: step, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.show(self.index + 1)
        }
        t.tolerance = step * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }
}

/// Round owner photo, or nothing when there is none.
struct DogPhoto: View {
    let path: String?
    var size: CGFloat = 56

    var body: some View {
        if let img = PhotoLoader.image(at: path) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .accessibilityLabel("캐릭터 사진")
        }
    }
}
