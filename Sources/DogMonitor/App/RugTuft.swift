import Accelerate
import AppKit
import simd

/// 러그 질감 리얼: a tufted (cut pile) rug. The picture is printed as pile: round yarn tufts about 7 texture pixels
/// across, each dyed a hair differently, darker in the gaps between and with a soft bright tip, colours meeting in a
/// slight blur. On 캐릭터 모양 a dark yarn outline hugs the drawing itself and a cream fur rim, rolled like a thick
/// edge, runs round it with hairs straying past the cut. The back is the pale backing with the design showing faintly
/// through, and two shadows are baked here too (a tight contact one, a wide soft one), so no frame ever blurs.
/// Built once per picture off the main thread (DesktopRug caches it), never per frame. Deterministic. Pure.
enum RugTuft {
    static let seed: UInt32 = 0x5EED_2026
    /// The dark yarn outline and the cream fur rim outside it, in texture pixels (2 per point).
    static let line: Float = 17, fur: Float = 14
    /// One tuft's size in texture pixels: big enough to read as yarn at desktop size.
    static let tuft: Float = 7
    static let cream = SIMD3<Float>(0.97, 0.94, 0.87)
    static let yarn = SIMD3<Float>(0.22, 0.14, 0.11)
    /// The underside's latex backing.
    static let lining = SIMD3<Float>(0.93, 0.91, 0.86)
    /// The shadows' room past the rug on every side, and their tent blurs (contact about 3 points, wide about 10).
    static let pad = 32, contactBlur = 13, wideBlur = 41

    /// What one picture becomes: the pile, the backing, and the two shadows' alpha (`pad` wider on every side).
    struct Faces {
        let front: CGImage, back: CGImage, contact: CGImage, wide: CGImage
    }

    // MARK: Noise

    /// 0...1 per whole (x, y), the same every run.
    static func hash(_ x: Int32, _ y: Int32, _ seed: UInt32 = seed) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8DA6_B343 ^ UInt32(bitPattern: y) &* 0xD816_3841 ^ seed &* 0xCB1A_B31F
        h ^= h >> 13; h &*= 0x5BD1_E995; h ^= h >> 15
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }

    /// Smooth value noise 0...1: `hash` on the whole grid, eased between.
    static func value(_ x: Float, _ y: Float, _ seed: UInt32 = seed) -> Float {
        let fx = x.rounded(.down), fy = y.rounded(.down), ix = Int32(fx), iy = Int32(fy)
        var u = x - fx, v = y - fy
        u = u * u * (3 - 2 * u); v = v * v * (3 - 2 * v)
        let a = hash(ix, iy, seed), b = hash(ix + 1, iy, seed), c = hash(ix, iy + 1, seed), d = hash(ix + 1, iy + 1, seed)
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }

    /// The tuft under texture pixel (x, y): `height` 0 in the gaps to 1 at a tuft's tip, and which tuft (`id`, 0...1).
    /// Tufts are round yarn ends on a jittered grid `size` apart, overlapping a little so the pile has no bald spots.
    static func tuftAt(_ x: Float, _ y: Float, size: Float = tuft, seed: UInt32 = seed) -> (height: Float, id: Float) {
        let cx = Int32((x / size).rounded(.down)), cy = Int32((y / size).rounded(.down)), r = size * 0.78
        // Blobs summed, not the nearest one taken: tufts melt into each other like soft yarn, no cobblestone seams.
        var sum: Float = 0, best: Float = 0, id: Float = 0
        for dy: Int32 in -1...1 { for dx: Int32 in -1...1 {
            let i = cx + dx, j = cy + dy
            let px = (Float(i) + 0.15 + 0.7 * hash(i, j, seed)) * size, py = (Float(j) + 0.15 + 0.7 * hash(i, j, seed &+ 1)) * size
            let d2 = ((x - px) * (x - px) + (y - py) * (y - py)) / (r * r)
            let h = max(0, 1 - d2)
            sum += h * h
            if h > best { best = h; id = hash(i, j, seed &+ 2) }
        } }
        return (min(1, sum), id)
    }

    /// How bright pile is at a tuft `height` 0...1 of tuft `id`: velvety, low contrast, 1 on average, a soft bright tip.
    static func pileLight(_ height: Float, id: Float) -> Float {
        let h = max(0, min(1, height))
        return 0.93 + 0.09 * h + 0.06 * pow(h, 8) + (id - 0.5) * 0.05
    }

    // MARK: Light

    /// Where the rim's roll is lit from: the upper left, like the scene's sun.
    static let light = simd_normalize(SIMD3<Float>(-0.45, 0.55, 0.7))

    /// How bright a bit of pile facing `n` (unit, +z up out of the rug) is: soft ambient, Lambert and a weak, wide
    /// sheen, scaled so flat pile is exactly 1.
    static func shade(_ n: SIMD3<Float>) -> Float {
        func raw(_ n: SIMD3<Float>) -> Float {
            let h = simd_normalize(light + SIMD3(0, 0, 1))
            return 0.45 + 0.55 * max(0, simd_dot(n, light)) + 0.06 * pow(max(0, simd_dot(n, h)), 12)
        }
        return raw(n) / raw(SIMD3(0, 0, 1))
    }

    // MARK: Textures

    /// `picture` (premultiplied RGBA, rows top down) tufted over the cut `mask` (nil: the whole face). The picture's
    /// drawn pixels are the art; with `rim`, the yarn outline hugs them and the cream fur fills the rest of the cut out to
    /// its edge (an opaque picture gets the band along the edge instead). `soft`: pixel art's pixel in texture pixels (0
    /// for a smooth picture): its stairs are rounded off first.
    static func faces(_ picture: CGImage, mask: RugMask?, rim: Bool, soft: Int) -> Faces? {
        guard var px = rgba(picture) else { return nil }
        let w = picture.width, h = picture.height
        if soft > 1 { px = blurred(rounded(px, w, h, soft), w, h, 3) }
        let (inside, depth) = cut(mask, w, h)
        let band = rim ? fur + line : 0
        // The art: drawn, and clear of the fur (so an opaque picture still gets its band at the edge).
        let art = (0..<(w * h)).map { i in inside[i] && px[i * 4 + 3] >= 128 && depth[i] >= band }
        let near = rim ? distance(art.map { !$0 }, w, h, outside: Float(w + h)) : [Float](repeating: 0, count: w * h)
        // Colour first (no light), blurred a touch so neighbouring yarns meet in fibres, not a ruled line.
        var flat = [UInt8](repeating: 0, count: w * h * 4)
        var kind = [UInt8](repeating: 0, count: w * h)   // 0 fur, 1 yarn, 2 picture
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            let wob = (value(Float(x) / 4, Float(y) / 4, seed &+ 11) - 0.5) * 2.4
            var c = cream
            if art[i] {
                let a = Float(px[i * 4 + 3]) / 255
                c = SIMD3(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) / 255 + cream * (1 - a)
                kind[i] = 2
            } else if rim, inside[i], near[i] + wob < line {
                c = yarn; kind[i] = 1
            }
            flat[i * 4] = UInt8(min(255, c.x * 255)); flat[i * 4 + 1] = UInt8(min(255, c.y * 255)); flat[i * 4 + 2] = UInt8(min(255, c.z * 255)); flat[i * 4 + 3] = 255
        } }
        flat = blurred(flat, w, h, 5)
        var out = [UInt8](repeating: 0, count: w * h * 4), under = out
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            guard inside[i] else { continue }
            let fx = Float(x), fy = Float(y)
            var c = SIMD3(Float(flat[i * 4]), Float(flat[i * 4 + 1]), Float(flat[i * 4 + 2])) / 255
            let isFur = kind[i] == 0
            // Fur is shaggier: smaller tufts that vary more.
            let t = tuftAt(fx, fy, size: isFur ? tuft * 0.75 : tuft, seed: isFur ? seed &+ 50 : seed)
            var k = pileLight(t.height, id: t.id)
            k += (hash(Int32(x), Int32(y), seed &+ 7) - 0.5) * 0.02   // single fibres
            k += (value((fx * 0.8 + fy * 0.6) / 2, (fy * 0.8 - fx * 0.6) / 14, seed &+ 3) - 0.5) * 0.05   // combed one way
            if isFur, depth[i] < fur * 1.6 {
                // The rim rolls over the edge: lit on the upper left, in shade on the lower right, dark right at the cut.
                func d(_ x: Int, _ y: Int) -> Float { depth[min(h - 1, max(0, y)) * w + min(w - 1, max(0, x))] }
                let gx = d(x + 2, y) - d(x - 2, y), gy = d(x, y + 2) - d(x, y - 2)
                let tt = min(1, depth[i] / (fur * 1.6)), slope = 0.8 * (1 - tt) * (1 - tt)
                k *= shade(simd_normalize(SIMD3<Float>(-gx * slope, gy * slope, 1))) * (0.88 + 0.12 * smooth(0, 4, depth[i]))
            }
            if rim, kind[i] == 2, distance1(kind, w, h, x, y) < 3 { k *= 0.94 }   // the pile tucks in against the outline
            let tint = SIMD3(hash(Int32(x / 7), Int32(y / 7), seed &+ 17), hash(Int32(x / 7), Int32(y / 7), seed &+ 19), hash(Int32(x / 7), Int32(y / 7), seed &+ 23)) - 0.5
            c = simd_clamp(c * k + tint * 0.012, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            out[i * 4] = UInt8(c.x * 255); out[i * 4 + 1] = UInt8(c.y * 255); out[i * 4 + 2] = UInt8(c.z * 255); out[i * 4 + 3] = 255
            // The back: the design faint through a woven backing, the fur rim wrapping round the edge.
            let weave: Float = (x % 6 < 1 || y % 6 < 1) ? 0.93 : 1
            var b = isFur && depth[i] < fur ? c : (lining * 0.82 + c * 0.18) * weave
            b = b * (1 + (hash(Int32(x), Int32(y), seed &+ 29) - 0.5) * 0.04)
            b = simd_clamp(b, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            under[i * 4] = UInt8(b.x * 255); under[i * 4 + 1] = UInt8(b.y * 255); under[i * 4 + 2] = UInt8(b.z * 255); under[i * 4 + 3] = 255
        } }
        // The shadows: the cut, black, `pad` wider all round, blurred.
        let pw = w + 2 * pad, ph = h + 2 * pad
        var cast = [UInt8](repeating: 0, count: pw * ph * 4)
        for y in 0..<h { for x in 0..<w where inside[y * w + x] { cast[((y + pad) * pw + x + pad) * 4 + 3] = 255 } }
        // A last soft pass: the pile reads velvety, and the cut's edge is antialiased.
        out = blurred(out, w, h, 3)
        guard let front = image(out, w, h), let back = image(under, w, h),
              let contact = image(blurred(cast, pw, ph, contactBlur), pw, ph), let wide = image(blurred(cast, pw, ph, wideBlur), pw, ph)
        else { return nil }
        return Faces(front: front, back: back, contact: contact, wide: wide)
    }

    /// How close (0...3 pixels) the nearest yarn pixel (`kind` 1) is to (x, y).
    private static func distance1(_ kind: [UInt8], _ w: Int, _ h: Int, _ x: Int, _ y: Int) -> Int {
        for r in 1...3 {
            for (dx, dy) in [(r, 0), (-r, 0), (0, r), (0, -r)] {
                let i = x + dx, j = y + dy
                if i >= 0, j >= 0, i < w, j < h, kind[j * w + i] == 1 { return r }
            }
        }
        return 4
    }

    /// Which texture pixels are rug (the cut, its fur straying a few pixels past it) and how deep inside the edge each is.
    static func cut(_ mask: RugMask?, _ w: Int, _ h: Int) -> (inside: [Bool], depth: [Float]) {
        var inside = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let fx = Float(x), fy = Float(y)
            // Stray hairs: thin, mostly outward strands of noise, a few pixels long.
            let hair = (value(fx / 1.3, fy / 1.3, seed &+ 41) - 0.5) * 0.5 + (value(fx / 6, fy / 6, seed &+ 43) - 0.5) * 0.25
            if let mask {
                let v = mask.value(u: (Double(x) + 0.5) / Double(w), v: 1 - (Double(y) + 0.5) / Double(h))
                inside[y * w + x] = v + hair * 0.25 >= 0.5
            } else {
                let edge = Float(min(x, y, w - 1 - x, h - 1 - y))
                inside[y * w + x] = edge + hair * 6 >= 2
            }
        } }
        return (inside, distance(inside, w, h))
    }

    /// How far each set pixel is from the nearest unset one, in pixels: a two pass chamfer. Off the image counts as
    /// `outside` (0: the image's edge is unset too).
    static func distance(_ on: [Bool], _ w: Int, _ h: Int, outside: Float = 0) -> [Float] {
        let far = Float(w + h), a: Float = 1, b: Float = 1.4142
        var d = on.map { $0 ? far : 0 }
        func at(_ x: Int, _ y: Int) -> Float { x < 0 || y < 0 || x >= w || y >= h ? outside : d[y * w + x] }
        for y in 0..<h { for x in 0..<w where d[y * w + x] > 0 {
            d[y * w + x] = min(d[y * w + x], at(x - 1, y) + a, at(x, y - 1) + a, at(x - 1, y - 1) + b, at(x + 1, y - 1) + b)
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) where d[y * w + x] > 0 {
            d[y * w + x] = min(d[y * w + x], at(x + 1, y) + a, at(x, y + 1) + a, at(x + 1, y + 1) + b, at(x - 1, y + 1) + b)
        } }
        return d
    }

    static func smooth(_ lo: Float, _ hi: Float, _ v: Float) -> Float {
        let t = min(1, max(0, (v - lo) / (hi - lo)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Pixels

    static func rgba(_ cg: CGImage) -> [UInt8]? {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    static func image(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Pixel art scaled up nearest (`cell` texture pixels per art pixel) with its corners rounded: each pixel takes
    /// whichever of the colours half a cell around it is closest to the blurred picture there, so a stair step becomes
    /// a curve and the colours stay the art's own (a blur alone smears them).
    static func rounded(_ px: [UInt8], _ w: Int, _ h: Int, _ cell: Int) -> [UInt8] {
        let r = max(1, cell / 2), soft = blurred(px, w, h, 2 * r + 1)
        var out = px
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            var best = i, bestD = Int.max
            for (dx, dy) in [(0, 0), (r, 0), (-r, 0), (0, r), (0, -r)] {
                let j = (min(h - 1, max(0, y + dy)) * w + min(w - 1, max(0, x + dx))) * 4
                var d = 0
                for k in 0..<4 { let e = Int(px[j + k]) - Int(soft[i + k]); d += e * e }
                if d < bestD { bestD = d; best = j }
            }
            for k in 0..<4 { out[i + k] = px[best + k] }
        } }
        return out
    }

    /// A `size` by `size` tent blur (odd; the four channels alike).
    static func blurred(_ px: [UInt8], _ w: Int, _ h: Int, _ size: Int) -> [UInt8] {
        var src = px, out = px
        src.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { o in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var b = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                _ = vImageTentConvolve_ARGB8888(&a, &b, nil, 0, 0, UInt32(size | 1), UInt32(size | 1), nil, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }
}

/// 내 이미지 러그: a picture of the user's own, kept as one PNG in the app's folder. A cut-out PNG keeps its own shape;
/// a photo has its subject cut out on this Mac (CustomSprite's 배경 제거), or stays a rectangle when no clear subject
/// is found.
enum RugPhoto {
    static let maxBytes = 30_000_000, maxPixel = 1024, minPixel = 16
    /// A small file can still unpack to a giant picture: anything over this many pixels is refused before decoding.
    static let maxArea = 100_000_000

    enum Problem: Error, Equatable {
        case tooBig, notImage, tooSmall, tooLarge, unreadable, unsaved

        var message: String {
            switch self {
            case .tooBig: return L("30MB보다 작은 이미지를 골라 주세요")
            case .notImage: return L("열 수 없는 이미지예요. PNG나 JPEG를 골라 주세요")
            case .tooSmall: return L("너무 작은 이미지예요")
            case .tooLarge: return L("해상도가 너무 큰 이미지예요")
            case .unreadable: return L("파일을 읽지 못했어요. 권한이나 위치를 확인해 주세요")
            case .unsaved: return L("이미지를 저장하지 못했어요. 디스크 공간을 확인해 주세요")
            }
        }
    }

    /// Where the picture is kept (tests point it elsewhere).
    static var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DogMonitor/RugPhoto.png")

    /// Checks `data` and makes the rug's picture of it, at most `maxPixel` on the long side. Slow (decoding and 배경
    /// 제거): off the main thread.
    static func prepare(_ data: Data, useVision: Bool = true) -> Result<CGImage, Problem> {
        guard data.count <= maxBytes else { return .failure(.tooBig) }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return .failure(.notImage) }
        // The header's size, read without decoding: a decompression bomb stops here.
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        if let w = props?[kCGImagePropertyPixelWidth] as? Int, let h = props?[kCGImagePropertyPixelHeight] as? Int, w * h > maxArea {
            return .failure(.tooLarge)
        }
        guard let image = CustomSprite.load(src, maxPixel: 2048) else { return .failure(.notImage) }
        guard min(image.width, image.height) >= minPixel else { return .failure(.tooSmall) }
        let cut = CustomSprite.checkedCutout(image, useVision: useVision)
        let kept = cut.flatMap { $0.unclear ? nil : $0.image } ?? image
        return .success(CustomSprite.downscale(kept, maxPixel: maxPixel))
    }

    /// Saves the picture at `from` as the rug's; the problem when it cannot. Slow: off the main thread.
    static func save(from: URL) -> Problem? {
        guard let data = try? Data(contentsOf: from, options: .mappedIfSafe) else { return .unreadable }
        switch prepare(data) {
        case .failure(let p): return p
        case .success(let image):
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return .unsaved }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: url, options: .atomic)
            } catch { return .unsaved }
            return nil
        }
    }

    /// When the saved picture last changed; nil when there is none.
    static var stamp: Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }

    static func load() -> NSImage? {
        guard let cg = CustomSprite.load(url: url, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
}
