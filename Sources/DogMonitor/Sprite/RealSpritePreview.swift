import AppKit
import SwiftUI

/// QA renders for photo characters (`--make-character <폴더> <그림> --style real|pixel`): cut-out, menu bar strips at
/// 1x/2x/3x on light and dark bars, a big preview drawn from the 1024 px source, and a fidelity measurement.
enum RealSpritePreview {
    static func make(_ path: String, to dir: URL, look: PhotoLook, chibi: Bool = true) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let start = Date()
        guard let photo = CustomSprite.load(url: URL(fileURLWithPath: path)),
              let cut = CustomSprite.checkedCutout(photo).map({ RealSprite.source($0.image) }) else { throw CocoaError(.fileReadCorruptFile) }
        try write(cut, dir, "cutout.png")
        let flip = CustomSprite.facesLeft(CustomSprite.base(cut, chibi: false))
        let photoFrames = CustomCharacter.render([.normal: cut], look: look, chibi: chibi, lightRim: false, flipped: flip)
        let poses: [[NSImage]], extras: [[NSImage]], big: [[NSImage]]
        if let real = photoFrames.real {
            poses = real.poseImages()
            extras = ExtraMotion.allCases.map { real.extraImages($0) }
            big = real.poseImages(pixelSize: 4, scales: [2]) + ExtraMotion.allCases.map { real.extraImages($0, pixelSize: 4, scales: [2]) }
        } else {
            let cache = DogSpriteCache(profile: .defaultDog, custom: photoFrames.frames, pixelSize: 1, style: .auto)
            poses = DogPose.allCases.map { cache.frames(for: $0) }
            extras = []
            let bigCache = DogSpriteCache(profile: .defaultDog, custom: photoFrames.frames, pixelSize: 4, style: .auto)
            big = DogPose.allCases.map { bigCache.frames(for: $0) }
        }
        for (name, gray) in [("light", 0.93), ("dark", 0.165)] {
            for scale in [1, 2, 3] {
                try write(strip(poses + extras, gray: gray, scale: scale), dir, "menubar-\(name)@\(scale)x.png")
            }
        }
        try write(sheet(big, scale: 2), dir, "preview-big@2x.png")
        try write(CustomCharacterStore.sheetImage(photoFrames.frames), dir, "sheet.png")
        let score = fidelity(cut, look: look, chibi: chibi)
        print("\(path): 사진 \(photo.width)x\(photo.height), 잘라낸 \(cut.width)x\(cut.height), \(look.style.label)·\(look.size.label)·\(look.outline.label), "
              + String(format: "색차 ΔE %.1f, 선명도 %.2f, %.2f초", score.deltaE, score.sharpness, Date().timeIntervalSince(start)))
    }

    /// How close the still subject at 2x comes to the cut-out resampled to the same box with Core Graphics' best filter:
    /// mean ΔE (Lab) over pixels both cover, and edge energy relative to that reference (1 = as sharp, lower = mushier).
    static func fidelity(_ cut: CGImage, look: PhotoLook, chibi: Bool) -> (deltaE: Double, sharpness: Double) {
        let still: Bitmap
        if look.style == .real {
            let sprite = RealSprite(sources: [.normal: cut], look: PhotoLook(style: .real, size: look.size, outline: .none))
            still = Bitmap(width: CustomSprite.w, height: CustomSprite.h, px: sprite.stillRGBA())
        } else {
            still = CustomSprite.base(cut, chibi: chibi, height: look.size.points * CustomSprite.density)
        }
        guard let box = CustomSprite.opaqueBounds(still) else { return (99, 0) }
        let bw = box.maxX - box.minX + 1, bh = box.maxY - box.minY + 1
        let trimmed = CustomSprite.opaqueBounds(Bitmap(cut)).flatMap { b in
            cut.cropping(to: CGRect(x: b.minX, y: b.minY, width: b.maxX - b.minX + 1, height: b.maxY - b.minY + 1))
        } ?? cut
        guard let ctx = DogRenderer.context(width: bw, height: bh) else { return (99, 0) }
        ctx.interpolationQuality = .high
        ctx.draw(trimmed, in: CGRect(x: 0, y: 0, width: bw, height: bh))
        let ref = Bitmap(ctx.makeImage()!)
        var de = 0.0, n = 0, gs = 0.0, gr = 0.0
        func lum(_ b: Bitmap, _ i: Int) -> Double { Lab(b.px[i], b.px[i + 1], b.px[i + 2]).l }
        for y in 0..<bh {
            for x in 0..<bw {
                let si = ((y + box.minY) * still.width + x + box.minX) * 4, ri = (y * bw + x) * 4
                guard still.px[si + 3] >= 200, ref.px[ri + 3] >= 200 else { continue }
                de += Lab(still.px[si], still.px[si + 1], still.px[si + 2]).dist(Lab(ref.px[ri], ref.px[ri + 1], ref.px[ri + 2])).squareRoot()
                n += 1
                if x + 1 < bw, still.px[si + 7] >= 200, ref.px[ri + 7] >= 200 {
                    gs += abs(lum(still, si + 4) - lum(still, si))
                    gr += abs(lum(ref, ri + 4) - lum(ref, ri))
                }
            }
        }
        return (n > 0 ? de / Double(n) : 99, gr > 0 ? gs / gr : 0)
    }

    /// Every frame side by side on a menu bar coloured strip, at one backing scale, one row.
    static func strip(_ rows: [[NSImage]], gray: Double, scale: Int) -> CGImage {
        let cw = DogSpriteCache.canvasWidth * scale, ch = DogSpriteCache.canvasHeight * scale, gap = 4 * scale
        let frames = rows.flatMap { $0.prefix(2) }
        let ctx = DogRenderer.context(width: frames.count * (cw + gap) + gap, height: ch + gap * 2)!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, f) in frames.enumerated() {
            guard let cg = rep(f, width: cw) else { continue }
            ctx.draw(cg, in: CGRect(x: gap + i * (cw + gap), y: gap, width: cw, height: ch))
        }
        return ctx.makeImage()!
    }

    /// Rows = poses, columns = frames, on white, at `scale` (the reps must exist at that size).
    static func sheet(_ rows: [[NSImage]], scale: Int) -> CGImage {
        guard let first = rows.first?.first else { return DogRenderer.context(width: 1, height: 1)!.makeImage()! }
        let cw = Int(first.size.width) * scale, ch = Int(first.size.height) * scale, gap = 6
        let cols = rows.map(\.count).max() ?? 1
        let ctx = DogRenderer.context(width: cols * (cw + gap) + gap, height: rows.count * (ch + gap) + gap)!
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (r, row) in rows.enumerated() {
            for (c, f) in row.enumerated() {
                guard let cg = rep(f, width: cw) else { continue }
                ctx.draw(cg, in: CGRect(x: gap + c * (cw + gap), y: ctx.height - (r + 1) * (ch + gap), width: cw, height: ch))
            }
        }
        return ctx.makeImage()!
    }

    /// The creator page with `cut` as its 평소 picture in `look`, light and dark, saved to a scratch store that is removed after.
    /// AppDefaults.store must already point at a throwaway suite.
    static func creator(_ cut: CGImage, look: PhotoLook, to dir: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-qa-\(UUID().uuidString)", isDirectory: true)
        defer { CreatorModel.qaInputs = [:]; try? FileManager.default.removeItem(at: root) }
        CreatorModel.qaInputs = [.normal: cut]
        QARender.fullHeight = true
        defer { QARender.fullHeight = false }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let view = CreatorLookHost(store: CustomCharacterStore(root: root), look: look)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
                window.setContentSize(host.fittingSize)
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            let bounds = host.bounds
            guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            window.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
            NSGraphicsContext.restoreGraphicsState()
            host.cacheDisplay(in: bounds, to: rep)
            window.orderOut(nil)
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("creator-\(suffix).png"))
        }
    }

    private static func rep(_ image: NSImage, width: Int) -> CGImage? {
        image.representations.compactMap { ($0 as? NSBitmapImageRep)?.cgImage }.first { $0.width == width }
    }

    private static func write(_ image: CGImage, _ dir: URL, _ name: String) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: dir.appendingPathComponent(name))
    }
}

/// The creator with a given look picked, for `RealSpritePreview.creator`.
private struct CreatorLookHost: View {
    let store: CustomCharacterStore
    let look: PhotoLook
    var body: some View {
        CharacterCreatorView(settings: .shared, store: store, editing: nil, initialLook: look) {}
            .frame(width: 400)
    }
}
