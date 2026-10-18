import AppKit
import CoreImage
import CoreText

/// How a photo character is drawn: 실사 (the cut-out itself, smooth, at full resolution) or 도트 (pixelated), how tall it
/// stands in the bar and how strong its outline is. Saved in character.json; nil there means a character from before
/// 2.0, which was 도트 at 보통 with the thin outline.
struct PhotoLook: Codable, Equatable {
    enum Style: String, Codable, CaseIterable {
        case real, pixel
        var label: String { self == .real ? L("실사") : L("도트") }
    }

    enum Size: String, Codable, CaseIterable {
        case small, medium, large
        var label: String {
            switch self {
            case .small: return L("작게")
            case .medium: return L("보통")
            case .large: return L("크게")
            }
        }
        /// Subject height in points on the 20 pt canvas.
        var points: Int {
            switch self {
            case .small: return 14
            case .medium: return 17
            case .large: return 20
            }
        }
    }

    enum Outline: String, Codable, CaseIterable {
        case none, thin, bold
        var label: String {
            switch self {
            case .none: return L("없음")
            case .thin: return L("얇게")
            case .bold: return L("진하게")
            }
        }
        /// Ring width in points (실사), art pixels (도트).
        var width: CGFloat {
            switch self {
            case .none: return 0
            case .thin: return 0.5
            case .bold: return 1
            }
        }
    }

    var style = Style.real
    var size = Size.medium
    var outline = Outline.thin

    /// What every photo character saved before 2.0 looks like.
    static let legacy = PhotoLook(style: .pixel, size: .medium, outline: .thin)
}

/// A 실사 photo character: every frame is drawn straight from the 1024 px cut-outs with high-quality resampling at each
/// screen's real pixel size (so it is crisp at 1x, 2x and 3x and in big previews), and moved as a whole, smoothly:
/// lean, bob, squash and stretch, hops, plus vector effects (z, speed lines, sweat, a food bowl).
final class RealSprite: Equatable {
    /// Long side of the saved cut-outs.
    static let sourcePixels = 1024
    /// Canvas in points, shared with every other character.
    static let canvas = CGSize(width: DogSpriteCache.canvasWidth, height: DogSpriteCache.canvasHeight)
    /// Feet rest this far above the canvas bottom, room for the outline and the ground shadow.
    static let ground: CGFloat = 0.75
    /// Widest a standing subject gets, so effects and the lean still fit the 34 pt canvas.
    static let maxWidth: CGFloat = 28

    let sources: [CustomSlot: CGImage]
    let look: PhotoLook
    let flipped: Bool
    let lightRim: Bool
    private let outline: CGColor

    init(sources: [CustomSlot: CGImage], look: PhotoLook, flipped: Bool = false, lightRim: Bool = false) {
        self.sources = sources
        self.look = look
        self.flipped = flipped
        self.lightRim = lightRim
        outline = Self.outlineColor(sources[.normal] ?? sources.values.first)
    }

    // ponytail: pictures compare by slot and size only; CustomCharacter.frames (by value) already tells changed pictures apart.
    static func == (a: RealSprite, b: RealSprite) -> Bool {
        a.look == b.look && a.flipped == b.flipped && a.lightRim == b.lightRim
            && a.sources.mapValues { [$0.width, $0.height] } == b.sources.mapValues { [$0.width, $0.height] }
    }

    // MARK: Motions

    enum Effect: Hashable { case zz, speed, sweat, bowlEmpty, bowlFull, question, crumbs, sparkle }

    /// One frame's motion, in points and degrees.
    struct Motion: Equatable {
        var dx: CGFloat = 0, dy: CGFloat = 0   // up is positive
        var angle: CGFloat = 0                 // degrees, positive leans forward (the subject faces right)
        var sx: CGFloat = 1, sy: CGFloat = 1   // squash and stretch about the feet; sx < 0 turns round
        var lying = false
        var fx: Set<Effect> = []
        var phase = 0
    }

    /// Frame counts match the other characters: lying 3, walks 4, run 4, sprint 6, exhausted 6.
    static func motions(_ pose: DogPose) -> [Motion] {
        func m(_ f: (inout Motion) -> Void) -> Motion { var x = Motion(); f(&x); return x }
        switch pose {
        case .lying:
            // Lying on its side, breathing slowly, a z drifting up.
            return [1.0, 1.05, 1.0].enumerated().map { i, b in m { $0.lying = true; $0.sx = b; $0.fx = [.zz]; $0.phase = i } }
        case .slowWalk:
            return [2.0, 0, -2, 0].enumerated().map { i, a in m { $0.angle = a; $0.sy = i % 2 == 0 ? 0.99 : 1 } }
        case .walk:
            return [(0.0, 3.0), (0.5, 1), (0, -1), (0.5, 1)].enumerated().map { i, v in
                m { $0.dy = v.0; $0.angle = v.1 + 1; if i % 2 == 0 { $0.sy = 0.97; $0.sx = 1.02 } else { $0.sy = 1.02; $0.sx = 0.99 } }
            }
        case .fastWalk:
            return [(0.0, 5.0), (0.8, 2), (0, 0), (0.8, 2)].enumerated().map { i, v in
                m { $0.dy = v.0; $0.angle = v.1 + 1; if i % 2 == 0 { $0.sy = 0.95; $0.sx = 1.03 } else { $0.sy = 1.03; $0.sx = 0.98 } }
            }
        case .run:
            return [0.0, 1, 1.5, 0.5].enumerated().map { i, up in
                m {
                    $0.dx = 2; $0.dy = up; $0.angle = 8 + (i % 2 == 0 ? 1 : -1); $0.fx = [.speed]; $0.phase = i
                    if up == 0 { $0.sy = 0.9; $0.sx = 1.06 } else if up == 1.5 { $0.sy = 1.04; $0.sx = 0.98 }
                }
            }
        case .sprint:
            return [0.0, 1, 1.75, 1.75, 0.75, 0].enumerated().map { i, up in
                m {
                    $0.dx = 2.5; $0.dy = up; $0.angle = 12 + (up >= 1.75 ? 2 : 0); $0.fx = [.speed]; $0.phase = i
                    if up == 0 { $0.sy = i == 0 ? 0.88 : 0.94; $0.sx = i == 0 ? 1.08 : 1.04 }
                }
            }
        case .exhausted:
            return [0.0, 0.5, 0, -0.5, 0.5, 0].enumerated().map { i, s in
                m { $0.dx = s; $0.angle = 5; $0.sy = i % 3 == 2 ? 0.93 : 0.96; $0.sx = i % 3 == 2 ? 1.04 : 1.02; $0.fx = [.sweat]; $0.phase = i }
            }
        }
    }

    /// hungry 4 (looking around by an empty bowl), eat 4 (chewing over a full one), special 6 (a happy hop with a
    /// quick turn: only two frames are thin, so a tall photo never shows as a sliver for long).
    static func motions(_ extra: ExtraMotion) -> [Motion] {
        func m(_ f: (inout Motion) -> Void) -> Motion { var x = Motion(); f(&x); return x }
        switch extra {
        case .hungry:
            return [(1.0, 0.0), (1, -6), (-1, 0), (-1, -6)].enumerated().map { i, v in
                m { $0.sx = v.0; $0.angle = v.1; $0.fx = i % 2 == 1 ? [.bowlEmpty, .question] : [.bowlEmpty]; $0.phase = i }
            }
        case .eat:
            return [(10.0, 0.0), (15, 0.96), (10, 0), (15, 0.96)].enumerated().map { i, v in
                m {
                    $0.angle = v.0; if v.1 > 0 { $0.sy = v.1; $0.sx = 1.03 }
                    $0.fx = i % 2 == 1 ? [.bowlFull, .crumbs] : [.bowlFull]; $0.phase = i
                }
            }
        case .special:
            return [(0.0, 1.0), (1.2, 0.35), (2.2, -1), (2.2, -1), (1.2, 0.35), (0, 1)].enumerated().map { i, v in
                m { $0.dy = v.0; $0.sx = v.1; $0.fx = [.sparkle]; $0.phase = i; if i == 0 { $0.sy = 0.92; $0.sx = 1.05 } }
            }
        }
    }

    // MARK: Output

    /// Every pose at `pixelSize` points per canvas point, one bitmap per backing scale, in DogPose order: what
    /// DogSpriteCache shows for a 실사 character.
    func poseImages(pixelSize: CGFloat = 1, scales: [CGFloat] = [1, 2, 3]) -> [[NSImage]] {
        let r = Renderer(self)
        return DogPose.allCases.map { pose in Self.motions(pose).map { r.image(CustomSlot.forPose(pose), $0, pixelSize, scales) } }
    }

    /// One extra motion's frames, like `poseImages`. Hungry and eat use the 평소 picture, special the 바쁠 때 one.
    func extraImages(_ extra: ExtraMotion, pixelSize: CGFloat = 1, scales: [CGFloat] = [1, 2, 3]) -> [NSImage] {
        let r = Renderer(self)
        return Self.motions(extra).map { r.image(Self.slot(extra), $0, pixelSize, scales) }
    }

    /// The same frames as premultiplied RGBA on the custom canvas (68x40, 2 px per point), for code that only takes
    /// `CustomCharacter.frames`, and for sheet.png.
    func frames() -> [[[UInt8]]] {
        let r = Renderer(self)
        return DogPose.allCases.map { pose in Self.motions(pose).map { r.rgba(CustomSlot.forPose(pose), $0) } }
    }

    func extraFrames(_ extra: ExtraMotion) -> [[UInt8]] {
        let r = Renderer(self)
        return Self.motions(extra).map { r.rgba(Self.slot(extra), $0) }
    }

    static func slot(_ extra: ExtraMotion) -> CustomSlot { extra == .special ? .busy : .normal }

    /// The 평소 picture standing still, no effects, straight alpha on the 68x40 canvas: for QA measurements.
    func stillRGBA() -> [UInt8] {
        var px = Renderer(self).rgba(.normal, Motion())
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && px[i + 3] < 255 {
            for c in 0..<3 { px[i + c] = UInt8(min(255, Int(px[i + c]) * 255 / Int(px[i + 3]))) }
        }
        return px
    }

    // MARK: Cut-outs

    /// What is saved for a 실사 character: trimmed to the alpha bounding box plus a 2 px clear margin, at most 1024 px.
    static func source(_ cutout: CGImage) -> CGImage {
        let b = Bitmap(cutout)
        guard let box = CustomSprite.opaqueBounds(b) else { return cutout }
        let rect = CGRect(x: box.minX - 2, y: box.minY - 2, width: box.maxX - box.minX + 5, height: box.maxY - box.minY + 5)
        let trimmed: CGImage
        if rect.minX < 0 || rect.minY < 0 || rect.maxX > CGFloat(b.width) || rect.maxY > CGFloat(b.height) {
            // Touching an edge: pad onto a clear canvas so the margin is still there.
            guard let ctx = DogRenderer.context(width: Int(rect.width), height: Int(rect.height)) else { return cutout }
            ctx.draw(cutout, in: CGRect(x: -rect.minX, y: rect.maxY - CGFloat(b.height), width: CGFloat(b.width), height: CGFloat(b.height)))
            trimmed = ctx.makeImage() ?? cutout
        } else {
            trimmed = cutout.cropping(to: rect) ?? cutout
        }
        return CustomSprite.downscale(trimmed, maxPixel: sourcePixels)
    }

    /// Dark version of the subject's average colour, like the 도트 outline.
    static func outlineColor(_ image: CGImage?) -> CGColor {
        var avg = [0.4, 0.35, 0.3]
        if let image, let ctx = DogRenderer.context(width: 16, height: 16) {
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            if let data = ctx.data {
                let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * 16)
                var sum = [0.0, 0.0, 0.0], a = 0.0
                for y in 0..<16 { for x in 0..<16 {
                    let i = y * ctx.bytesPerRow + x * 4
                    for c in 0..<3 { sum[c] += Double(p[i + c]) }   // premultiplied: already weighted by alpha
                    a += Double(p[i + 3])
                } }
                if a > 0 { avg = sum.map { $0 / a } }
            }
        }
        return CGColor(srgbRed: 0.08 + avg[0] * 0.22, green: 0.06 + avg[1] * 0.22, blue: 0.09 + avg[2] * 0.22, alpha: 1)
    }

    // MARK: Drawing

    /// Draws frames; keeps each picture resampled once per pixel density, with its silhouette for the outline.
    private final class Renderer {
        let sprite: RealSprite
        private var prepared: [String: (image: CGImage, mask: CGImage, white: CGImage)] = [:]

        init(_ sprite: RealSprite) { self.sprite = sprite }

        func image(_ slot: CustomSlot, _ m: Motion, _ pixelSize: CGFloat, _ scales: [CGFloat]) -> NSImage {
            let size = NSSize(width: canvas.width * pixelSize, height: canvas.height * pixelSize)
            let image = NSImage(size: size)
            for scale in scales {
                guard let cg = draw(slot, m, pixelSize * scale) else { continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                rep.size = size
                image.addRepresentation(rep)
            }
            return image
        }

        func rgba(_ slot: CustomSlot, _ m: Motion) -> [UInt8] {
            let w = CustomSprite.w, h = CustomSprite.h
            var out = [UInt8](repeating: 0, count: w * h * 4)
            out.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                paint(ctx, slot, m, CGFloat(CustomSprite.density))
            }
            return out
        }

        /// One frame at `u` device pixels per canvas point.
        private func draw(_ slot: CustomSlot, _ m: Motion, _ u: CGFloat) -> CGImage? {
            let w = Int((canvas.width * u).rounded()), h = Int((canvas.height * u).rounded())
            guard let ctx = DogRenderer.context(width: w, height: h) else { return nil }
            paint(ctx, slot, m, u)
            return ctx.makeImage()
        }

        /// The subject's size in points: the chosen height, narrowed to `maxWidth`.
        func subjectSize(_ src: CGImage) -> CGSize {
            var hPt = CGFloat(sprite.look.size.points), wPt = hPt * CGFloat(src.width) / CGFloat(max(1, src.height))
            if wPt > maxWidth { hPt *= maxWidth / wPt; wPt = maxWidth }
            return CGSize(width: wPt, height: hPt)
        }

        private func paint(_ ctx: CGContext, _ slot: CustomSlot, _ m: Motion, _ u: CGFloat) {
            guard let pick = slot.source(among: Set(sprite.sources.keys)), let src = sprite.sources[pick] else { return }
            let size = subjectSize(src)
            let art = prepare(pick, src, size, u)
            ctx.scaleBy(x: u, y: u)
            ctx.interpolationQuality = .high
            ctx.setShouldAntialias(true)
            let (sw, sh) = (size.width, size.height)
            let bowl = m.fx.contains(.bowlEmpty) || m.fx.contains(.bowlFull)
            // By the bowl: the front edge just reaches its rim.
            let cx = bowl ? max(sw / 2, 27.5 - sw / 2) : canvas.width / 2 + m.dx, base = ground + m.dy
            // Bounds of the drawn subject on the canvas, for placing effects.
            var box = CGRect(x: cx - sw / 2, y: base, width: sw, height: sh)
            let tall = sh >= sw * 1.2   // near-square subjects (a penguin) settle low instead of rolling over

            if m.fx.contains(.speed) { speedLines(ctx, box, m.phase) }
            if sprite.look.outline != .none {
                // Ground contact shadow, smaller while airborne.
                let k = max(0.6, 1 - m.dy * 0.12)
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.16))
                ctx.fillEllipse(in: CGRect(x: cx - sw * 0.36 * k, y: ground - 0.55, width: sw * 0.72 * k, height: 1.1))
            }

            ctx.saveGState()
            ctx.translateBy(x: cx, y: base)
            if m.lying {
                // Settles low, head kept upright: rotating a sitting photo onto its side read as a toppled figurine.
                let (kx, ky): (CGFloat, CGFloat) = tall ? (1.12, 0.62) : (1.06, 0.78)
                if tall {   // a firmer contact shadow under the flattened body (origin is at cx, base here)
                    ctx.setFillColor(CGColor(gray: 0, alpha: 0.22))
                    ctx.fillEllipse(in: CGRect(x: -sw * 0.5, y: ground - base - 0.5, width: sw, height: 1))
                }
                ctx.scaleBy(x: kx * m.sx, y: ky / m.sx)
                box = CGRect(x: cx - sw * kx / 2, y: base, width: sw * kx, height: sh * ky)
            } else {
                ctx.rotate(by: -m.angle * .pi / 180)
                ctx.scaleBy(x: m.sx, y: m.sy)
                box.size.height *= m.sy
            }
            if sprite.flipped { ctx.scaleBy(x: -1, y: 1) }
            let rect = CGRect(x: -sw / 2, y: 0, width: sw, height: sh)
            let ring = sprite.look.outline.width
            if sprite.lightRim { rings(ctx, art.white, rect, ring + max(0.5, 1 / u), alpha: 0.55) }
            if ring > 0 { rings(ctx, art.mask, rect, max(ring, 1 / u), alpha: sprite.look.outline == .bold ? 0.95 : 0.8) }
            ctx.draw(art.image, in: rect)
            ctx.restoreGState()

            if bowl { self.bowl(ctx, full: m.fx.contains(.bowlFull)) }
            if m.fx.contains(.crumbs) { crumbs(ctx, m.phase) }
            if m.fx.contains(.zz) { zz(ctx, box, m.phase) }
            if m.fx.contains(.sweat) { sweat(ctx, box, m.phase) }
            if m.fx.contains(.question) { text(ctx, "?", size: 7, at: CGPoint(x: min(box.maxX + 0.2, canvas.width - 4), y: min(box.maxY - 5, canvas.height - 7)),
                                               color: CGColor(srgbRed: 0.96, green: 0.65, blue: 0.14, alpha: 1)) }
            if m.fx.contains(.sparkle) { sparkles(ctx, box, m.phase) }
        }

        /// The silhouette stamped in a ring around the subject, as one layer so overlaps do not darken.
        private func rings(_ ctx: CGContext, _ mask: CGImage, _ rect: CGRect, _ r: CGFloat, alpha: CGFloat) {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for k in 0..<12 {
                let a = CGFloat(k) * .pi / 6
                ctx.draw(mask, in: rect.offsetBy(dx: cos(a) * r, dy: sin(a) * r))
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        /// The picture at twice the device pixels it is drawn at (headroom for rotation), resampled by halving so a 1024 px
        /// cut-out does not alias on the way down to 40 px; plus its silhouette in the outline colour and in white.
        private func prepare(_ slot: CustomSlot, _ src: CGImage, _ size: CGSize, _ u: CGFloat) -> (image: CGImage, mask: CGImage, white: CGImage) {
            let key = "\(slot.rawValue)-\(u)"
            if let hit = prepared[key] { return hit }
            let tw = max(1, Int((size.width * u * 2).rounded(.up))), th = max(1, Int((size.height * u * 2).rounded(.up)))
            let image = lanczos(src, tw, th) ?? resample(src, tw, th) ?? src
            func tinted(_ color: CGColor) -> CGImage {
                guard let ctx = DogRenderer.context(width: image.width, height: image.height) else { return image }
                let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                ctx.draw(image, in: r)
                ctx.setBlendMode(.sourceIn)
                ctx.setFillColor(color)
                ctx.fill(r)
                return ctx.makeImage() ?? image
            }
            let out = (image, tinted(sprite.outline), tinted(CGColor(gray: 1, alpha: 1)))
            prepared[key] = out
            return out
        }

        /// Lanczos down to `w` x `h`, then a light unsharp mask: the drawn frame is a further 2:1 reduction, which softens it.
        private func lanczos(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage? {
            let input = CIImage(cgImage: img)
            let sy = CGFloat(h) / CGFloat(img.height), aspect = (CGFloat(w) / CGFloat(img.width)) / sy
            guard let scale = CIFilter(name: "CILanczosScaleTransform", parameters: [kCIInputImageKey: input, kCIInputScaleKey: sy,
                                                                                   kCIInputAspectRatioKey: aspect])?.outputImage,
                  let sharp = CIFilter(name: "CIUnsharpMask", parameters: [kCIInputImageKey: scale, kCIInputRadiusKey: 1.2,
                                                                          kCIInputIntensityKey: Renderer.sharpen])?.outputImage else { return nil }
            return Renderer.ci.createCGImage(sharp, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }

        private static let ci = CIContext(options: [.cacheIntermediates: false])
        /// Unsharp mask strength; QA-tuned (RealSpritePreview's sharpness near 1 without halos).
        private static let sharpen = 0.6

        private func resample(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage? {
            guard let ctx = DogRenderer.context(width: max(1, w), height: max(1, h)) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: max(1, w), height: max(1, h)))
            return ctx.makeImage()
        }

        // MARK: Effects (canvas points, y up)

        private func speedLines(_ ctx: CGContext, _ box: CGRect, _ phase: Int) {
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineWidth(0.8)
            ctx.setStrokeColor(CGColor(srgbRed: 150 / 255, green: 160 / 255, blue: 180 / 255, alpha: 0.95))
            for (k, f) in [0.3, 0.55, 0.8].enumerated() where k != 2 || phase % 2 == 0 {
                let y = box.minY + box.height * CGFloat(f)
                let end = box.minX + 1.2 - CGFloat((phase + k) % 2) * 1.2, len: CGFloat = k == 1 ? 5 : 3.5
                ctx.move(to: CGPoint(x: max(0.5, end - len), y: y))
                ctx.addLine(to: CGPoint(x: max(0.6, end), y: y))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        private func sweat(_ ctx: CGContext, _ box: CGRect, _ phase: Int) {
            let light = CGColor(srgbRed: 0x6C / 255, green: 0xC6 / 255, blue: 0xF7 / 255, alpha: 1)
            let dark = CGColor(srgbRed: 0x2C / 255, green: 0x8B / 255, blue: 0xD6 / 255, alpha: 1)
            let spots = [CGPoint(x: box.maxX + 0.4, y: box.maxY - 2.5 - CGFloat(phase % 3) * 1.1),
                         CGPoint(x: box.maxX + 2.6, y: box.maxY - 1 - CGFloat((phase + 1) % 3) * 1.1)]
            for p in spots {
                let c = CGPoint(x: min(canvas.width - 1.2, p.x), y: min(canvas.height - 2.2, p.y))
                let path = CGMutablePath()
                path.move(to: CGPoint(x: c.x, y: c.y + 2))
                path.addCurve(to: CGPoint(x: c.x, y: c.y - 0.9), control1: CGPoint(x: c.x + 1.3, y: c.y + 0.4), control2: CGPoint(x: c.x + 1.2, y: c.y - 0.9))
                path.addCurve(to: CGPoint(x: c.x, y: c.y + 2), control1: CGPoint(x: c.x - 1.2, y: c.y - 0.9), control2: CGPoint(x: c.x - 1.3, y: c.y + 0.4))
                ctx.addPath(path)
                ctx.setFillColor(light)
                ctx.setStrokeColor(dark)
                ctx.setLineWidth(0.35)
                ctx.drawPath(using: .fillStroke)
            }
        }

        private func zz(_ ctx: CGContext, _ box: CGRect, _ phase: Int) {
            let color = CGColor(srgbRed: 0x7E / 255, green: 0x9C / 255, blue: 0xCB / 255, alpha: 1)
            let x = min(canvas.width - 4.5, box.maxX + 0.5 + CGFloat(phase) * 0.6)
            let y = min(canvas.height - 5.5, box.maxY - 1 + CGFloat(phase) * 1.2)
            text(ctx, "z", size: 4.5 + CGFloat(phase), at: CGPoint(x: x, y: y), color: color)
        }

        private func bowl(_ ctx: CGContext, full: Bool) {
            let cx: CGFloat = 30.2, top: CGFloat = 3, rx: CGFloat = 3.2
            let body = CGMutablePath()
            body.move(to: CGPoint(x: cx - rx, y: top))
            body.addCurve(to: CGPoint(x: cx - 2.1, y: 0.35), control1: CGPoint(x: cx - rx, y: 1.4), control2: CGPoint(x: cx - 2.8, y: 0.35))
            body.addLine(to: CGPoint(x: cx + 2.1, y: 0.35))
            body.addCurve(to: CGPoint(x: cx + rx, y: top), control1: CGPoint(x: cx + 2.8, y: 0.35), control2: CGPoint(x: cx + rx, y: 1.4))
            body.closeSubpath()
            ctx.addPath(body)
            ctx.setFillColor(CGColor(srgbRed: 0.88, green: 0.32, blue: 0.29, alpha: 1))
            ctx.fillPath()
            let rim = CGRect(x: cx - rx, y: top - 0.75, width: rx * 2, height: 1.5)
            ctx.setFillColor(CGColor(srgbRed: 0.62, green: 0.18, blue: 0.16, alpha: 1))
            ctx.fillEllipse(in: rim)
            if full {
                ctx.setFillColor(CGColor(srgbRed: 0.66, green: 0.42, blue: 0.2, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: cx - 2.6, y: top - 0.3, width: 5.2, height: 2))
                ctx.setFillColor(CGColor(srgbRed: 0.46, green: 0.28, blue: 0.12, alpha: 1))
                for (dx, dy) in [(-1.3, 0.9), (0.2, 1.3), (1.4, 0.7)] as [(CGFloat, CGFloat)] {
                    ctx.fillEllipse(in: CGRect(x: cx + dx - 0.4, y: top + dy - 0.4, width: 0.8, height: 0.8))
                }
            }
        }

        private func crumbs(_ ctx: CGContext, _ phase: Int) {
            ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.34, blue: 0.15, alpha: 1))
            let spots: [(CGFloat, CGFloat)] = phase % 4 == 1 ? [(26.2, 5.6), (27.4, 6.6), (25.4, 4.4)] : [(26.6, 6.2), (25.6, 5.2)]
            for (x, y) in spots { ctx.fillEllipse(in: CGRect(x: x - 0.35, y: y - 0.35, width: 0.7, height: 0.7)) }
        }

        private func sparkles(_ ctx: CGContext, _ box: CGRect, _ phase: Int) {
            let spots = [CGPoint(x: box.minX - 1.5, y: box.maxY - 3), CGPoint(x: box.maxX + 1.5, y: box.maxY - 1),
                         CGPoint(x: box.maxX + 2, y: box.minY + 4), CGPoint(x: box.minX - 1, y: box.minY + 6)]
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.83, blue: 0.3, alpha: 1))
            ctx.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.6, blue: 0, alpha: 1))
            ctx.setLineWidth(0.3)
            for (k, p) in spots.enumerated() where (k + phase) % 2 == 0 {
                let c = CGPoint(x: min(canvas.width - 1.6, max(1.6, p.x)), y: min(canvas.height - 1.6, max(1.6, p.y)))
                let r: CGFloat = (k + phase) % 4 == 0 ? 1.6 : 1.1, q = r * 0.3
                let star = CGMutablePath()
                star.move(to: CGPoint(x: c.x, y: c.y + r))
                star.addLine(to: CGPoint(x: c.x + q, y: c.y + q)); star.addLine(to: CGPoint(x: c.x + r, y: c.y))
                star.addLine(to: CGPoint(x: c.x + q, y: c.y - q)); star.addLine(to: CGPoint(x: c.x, y: c.y - r))
                star.addLine(to: CGPoint(x: c.x - q, y: c.y - q)); star.addLine(to: CGPoint(x: c.x - r, y: c.y))
                star.addLine(to: CGPoint(x: c.x - q, y: c.y + q)); star.closeSubpath()
                ctx.addPath(star)
                ctx.drawPath(using: .fillStroke)
            }
        }

        /// Heavy rounded glyphs through Core Text, so it is safe off the main thread.
        private func text(_ ctx: CGContext, _ s: String, size: CGFloat, at p: CGPoint, color: CGColor) {
            let base = NSFont.systemFont(ofSize: size, weight: .heavy)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            let attr = NSAttributedString(string: s, attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.textPosition = p
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }
}
