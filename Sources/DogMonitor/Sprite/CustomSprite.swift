import AppKit
import ImageIO
import Vision

/// The three pictures a custom character is made from. Raw values name the saved thumbnails.
enum CustomSlot: String, CaseIterable, Codable {
    case rest, normal, busy

    var label: String {
        switch self {
        case .rest: return L("쉴 때")
        case .normal: return L("평소")
        case .busy: return L("바쁠 때")
        }
    }

    /// Which picture each pose is drawn from.
    static func forPose(_ pose: DogPose) -> CustomSlot {
        switch pose {
        case .lying: return .rest
        case .slowWalk, .walk, .fastWalk, .run: return .normal
        case .sprint, .exhausted: return .busy
        }
    }

    /// The picture actually drawn for `slot` when only `filled` have one: itself, else 평소, 바쁠 때, 쉴 때.
    func source(among filled: Set<CustomSlot>) -> CustomSlot? {
        [self, .normal, .busy, .rest].first(where: filled.contains)
    }
}

/// Straight-alpha RGBA8 pixels, top row first.
struct Bitmap {
    let width: Int, height: Int
    var px: [UInt8]
    /// Pixel art that brings its own outline (CustomSprite.placedPixelArt), so `render` does not add a second one.
    var outlined = false

    init(width: Int, height: Int, px: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.px = px ?? [UInt8](repeating: 0, count: width * height * 4)
    }

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            // A context that cannot be made leaves the bitmap transparent rather than crashing.
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Un-premultiply so colours can be averaged and compared as they look.
        for i in stride(from: 0, to: data.count, by: 4) {
            let a = Int(data[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { data[i + c] = UInt8(min(255, Int(data[i + c]) * 255 / a)) }
        }
        self.init(width: w, height: h, px: data)
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 { px[(y * width + x) * 4 + 3] }

    /// Premultiplied copy for Core Graphics.
    var cgImage: CGImage { DogRenderer.cgImage(cgReady, width: width, height: height) }
}

/// Photo to menu bar sprite, entirely on this Mac: cut out the subject, pixelate onto the dog's canvas,
/// then animate the still procedurally so the busyness still shows.
enum CustomSprite {
    /// Art pixels per point: photos are drawn on a 68x40 canvas that fills the same 34x20 pt as the dog,
    /// so a Retina bar shows 4x the detail (1x screens get it downsampled).
    static let density = 2
    static let w = DogSpriteCache.canvasWidth * density, h = DogSpriteCache.canvasHeight * density
    /// Bottom art row of the dog's paw row; the outline sits one art row below.
    static let ground = DogPainter.ground * density + density - 1
    /// Subject size before the outline: 34 + 2 outline rows, leaving 3 art rows for the run hop.
    static let maxSubjectHeight = 34, maxSubjectWidth = 52
    /// Photos are pre-widened this much before pixelating, so tall subjects do not end up as 15 px sticks.
    static let widen = 1.15
    /// Photo colours after k-means, plus one for dark features (eyes, nose, mouth), outline and effects.
    static let maxColors = 14
    /// Pixel art keeps up to this many; the AI is asked for 12, so more means noise.
    static let maxArtColors = 24

    // MARK: Loading and cutout

    /// Loads PNG, JPEG, HEIC (anything ImageIO reads), EXIF-rotated, at most `maxPixel` on the long side: 2048, so a subject
    /// that fills only part of the photo still yields a full 1024 px 실사 cut-out.
    static func load(_ source: CGImageSource, maxPixel: Int = 2048) -> CGImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    static func load(url: URL, maxPixel: Int = 2048) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { load($0, maxPixel: maxPixel) }
    }
    static func load(data: Data) -> CGImage? { CGImageSourceCreateWithData(data as CFData, nil).flatMap { load($0) } }

    /// The subject alone, cropped to its bounds, at most 1024 px (RealSprite.sourcePixels; RealSprite.source adds the saved
    /// 2 px margin): what 실사 draws and what `base` pixelates. nil when nothing that looks like a subject is left.
    static func cutout(_ image: CGImage, useVision: Bool = true) -> CGImage? { checkedCutout(image, useVision: useVision)?.image }

    /// `cutout`, plus whether the subject is unclear: from a photo, the mask covers most of the frame or
    /// its box touches three or more borders (a landscape, a room), so the sprite will be a blob. `box` is the
    /// subject's bounds in `image`, top-left pixels.
    /// `aiArt`: a drawing from /api/character on flat magenta. It is keyed on that colour (a white flood fill would leak
    /// into white chests and paws), and put back on its own pixel grid at 1 px per art pixel when one shows.
    static func checkedCutout(_ image: CGImage, useVision: Bool = true, aiArt: Bool = false) -> (image: CGImage, unclear: Bool, box: CGRect)? {
        var bmp = Bitmap(image)
        var mask: [Bool]
        // Vision's soft edge, kept as alpha so a 실사 cut-out is not stair-stepped (nil: hard edges).
        var soft: [Float]?
        let cutAlready = hasTransparentBackground(bmp)
        if cutAlready {
            mask = (0..<(bmp.width * bmp.height)).map { bmp.px[$0 * 4 + 3] >= 128 }
        } else if aiArt, let key = magentaMask(bmp) {
            mask = key
        } else if useVision && !aiArt, let vision = visionMask(image, width: bmp.width, height: bmp.height) {
            mask = vision.map { $0 >= 0.5 }
            soft = vision
        } else {
            mask = floodFillMask(bmp)
        }
        // Pixel art joins its strands (an ahoge, a tail tip) at cell corners, so corners count as touching there.
        keepMainParts(&mask, bmp.width, bmp.height, corners: aiArt)
        guard let box = bounds(mask, bmp.width, bmp.height) else { return nil }
        let borders = [box.minX == 0, box.minY == 0, box.maxX == bmp.width - 1, box.maxY == bmp.height - 1].filter { $0 }.count
        let unclear = !cutAlready && (mask.filter { $0 }.count * 10 > mask.count * 7 || borders >= 3)
        for i in 0..<(bmp.width * bmp.height) where !mask[i] { bmp.px[i * 4 + 3] = 0 }
        // An already cut-out PNG keeps its own anti-aliased edge; a mask from Vision its soft edge.
        for i in 0..<(bmp.width * bmp.height) where mask[i] && !cutAlready {
            bmp.px[i * 4 + 3] = soft.map { UInt8(max(0, min(1, $0[i])) * 255) } ?? 255
        }
        let rect = CGRect(x: box.minX, y: box.minY, width: box.maxX - box.minX + 1, height: box.maxY - box.minY + 1)
        guard let cropped = bmp.cgImage.cropping(to: rect) else { return nil }
        if aiArt, let art = pixelGrid(hardened(Bitmap(cropped))) { return (art.cgImage, unclear, rect) }
        // An AI drawing without a clear grid is pixelated like before; a photo keeps up to 1024 px for 실사.
        return (downscale(cropped, maxPixel: aiArt ? 256 : RealSprite.sourcePixels), unclear, rect)
    }

    /// `box` grown by `margin` of its size on every side, clipped to the image: what the AI gets instead of the
    /// whole photo, so the subject fills its 512 px.
    static func crop(_ image: CGImage, around box: CGRect, margin: Double = 0.12) -> CGImage {
        let grown = box.insetBy(dx: -box.width * margin, dy: -box.height * margin).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return grown.isEmpty ? image : image.cropping(to: grown) ?? image
    }

    /// The background of an AI drawing: pixels close to #FF00FF, when most of the border is that colour.
    static func magentaMask(_ b: Bitmap) -> [Bool]? {
        func key(_ i: Int) -> Bool {
            let r = 255 - Int(b.px[i * 4]), g = Int(b.px[i * 4 + 1]), bl = 255 - Int(b.px[i * 4 + 2])
            return r * r + g * g + bl * bl < 60 * 60
        }
        let w = b.width, h = b.height
        var border: [Int] = []
        for x in 0..<w { border += [x, (h - 1) * w + x] }
        for y in 0..<h { border += [y * w, y * w + w - 1] }
        guard border.filter(key).count * 10 >= border.count * 6 else { return nil }
        return (0..<(w * h)).map { !key($0) }
    }

    /// AI pixel art back on its own grid, 1 px per art pixel: the grid's period and offset come from where the colour
    /// changes (each axis on its own, about 1 px of jitter allowed), and each cell takes its most common colour.
    /// nil when no clear grid shows or it would not fit the canvas; the caller then area-averages as for a photo.
    static func pixelGrid(_ b: Bitmap) -> Bitmap? {
        func differs(_ i: Int, _ j: Int) -> Bool {
            if (b.px[i * 4 + 3] >= 128) != (b.px[j * 4 + 3] >= 128) { return true }
            guard b.px[i * 4 + 3] >= 128 else { return false }
            return (0..<3).map { abs(Int(b.px[i * 4 + $0]) - Int(b.px[j * 4 + $0])) }.reduce(0, +) > 48
        }
        var ex = [Int](repeating: 0, count: b.width), ey = [Int](repeating: 0, count: b.height)
        for y in 0..<b.height {
            for x in 0..<b.width {
                let i = y * b.width + x
                if x > 0 && differs(i, i - 1) { ex[x] += 1 }
                if y > 0 && differs(i, i - b.width) { ey[y] += 1 }
            }
        }
        // The crop's own sides are the silhouette's outer edges: without them a sparse drawing also fits a grid twice
        // as coarse, shifted half a cell.
        ex.append(0); ey.append(0)
        for y in 0..<b.height {
            if b.alpha(0, y) >= 128 { ex[0] += 1 }
            if b.alpha(b.width - 1, y) >= 128 { ex[b.width] += 1 }
        }
        for x in 0..<b.width {
            if b.alpha(x, 0) >= 128 { ey[0] += 1 }
            if b.alpha(x, b.height - 1) >= 128 { ey[b.height] += 1 }
        }
        guard let gx = gridPeriod(ex), let gy = gridPeriod(ey) else { return nil }
        // Cells from one before the first grid line, so a partly cropped first column is not lost.
        let cols = Int((Double(b.width) - gx.offset) / gx.size) + 2, rows = Int((Double(b.height) - gy.offset) / gy.size) + 2
        var art = Bitmap(width: cols, height: rows)
        for r in 0..<rows {
            for c in 0..<cols {
                // The middle half of the cell only, away from soft edges.
                let x0 = gx.offset + Double(c - 1) * gx.size, y0 = gy.offset + Double(r - 1) * gy.size
                let xl = max(0, Int(x0 + gx.size * 0.25)), xh = min(b.width, Int((x0 + gx.size * 0.75).rounded(.up)))
                let yl = max(0, Int(y0 + gy.size * 0.25)), yh = min(b.height, Int((y0 + gy.size * 0.75).rounded(.up)))
                guard xl < xh, yl < yh else { continue }
                let xs = xl..<xh, ys = yl..<yh
                var buckets = [Int: [Int]](), n = 0
                for y in ys { for x in xs {
                    n += 1
                    let i = (y * b.width + x) * 4
                    guard b.px[i + 3] >= 128 else { continue }
                    let key = (Int(b.px[i]) / 16) * 256 + (Int(b.px[i + 1]) / 16) * 16 + Int(b.px[i + 2]) / 16
                    buckets[key, default: []].append(i)
                } }
                let opaque = buckets.values.map(\.count).reduce(0, +)
                guard opaque * 2 > n, let top = buckets.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }) else { continue }
                let o = (r * cols + c) * 4
                for k in 0..<3 { art.px[o + k] = UInt8(top.value.map { Int(b.px[$0 + k]) }.reduce(0, +) / top.value.count) }
                art.px[o + 3] = 255
            }
        }
        guard let box = opaqueBounds(art) else { return nil }
        let tw = box.maxX - box.minX + 1, th = box.maxY - box.minY + 1
        guard th >= 8, tw <= w, th <= h else { return nil }
        var out = Bitmap(width: tw, height: th)
        for y in 0..<th { for x in 0..<tw { for k in 0..<4 {
            out.px[(y * tw + x) * 4 + k] = art.px[((y + box.minY) * cols + x + box.minX) * 4 + k]
        } } }
        return out
    }

    /// The grid behind edge counts along one axis: the largest cell size (at least 6 px) whose lines, give or take
    /// 1 px, carry nearly as many of the edges as the best size does. Half the true size also hits every edge; twice
    /// it only half, so the largest good one is the real one.
    static func gridPeriod(_ edges: [Int]) -> (size: Double, offset: Double)? {
        let total = edges.reduce(0, +)
        guard total > 0, edges.count >= 48 else { return nil }
        let hits = edges.indices.filter { edges[$0] > 0 }
        var scores: [(size: Double, offset: Double, hit: Double)] = []
        for step in 60...min(960, edges.count * 10 / 4) {   // 6.0 to a quarter of the length, 0.1 px apart
            let size = Double(step) / 10, bins = step * 4 / 10 + 1   // 0.25 px phase bins
            var phase = [Int](repeating: 0, count: bins)
            for x in hits { phase[min(bins - 1, Int(Double(x).truncatingRemainder(dividingBy: size) * 4))] += edges[x] }
            var best = (0, 0)
            for start in 0..<bins {
                var sum = 0
                for d in -4...4 { sum += phase[(start + d + bins) % bins] }
                if sum > best.0 { best = (sum, start) }
            }
            scores.append((size, Double(best.1) / 4, Double(best.0) / Double(total)))
        }
        guard let top = scores.map(\.hit).max(), top >= 0.7 else { return nil }
        // Near the top size, sizes a hair off still score; take the best one right around it.
        guard let largest = scores.last(where: { $0.hit >= top * 0.9 }) else { return nil }
        let pick = scores.filter { abs($0.size - largest.size) <= largest.size * 0.03 }.max { $0.hit < $1.hit } ?? largest
        return (pick.size, pick.offset)
    }

    /// Already cut out (a PNG with a see-through border): trust its alpha.
    private static func hasTransparentBackground(_ b: Bitmap) -> Bool {
        var clear = 0, total = 0
        for x in 0..<b.width { total += 2; clear += (b.alpha(x, 0) < 128 ? 1 : 0) + (b.alpha(x, b.height - 1) < 128 ? 1 : 0) }
        for y in 0..<b.height { total += 2; clear += (b.alpha(0, y) < 128 ? 1 : 0) + (b.alpha(b.width - 1, y) < 128 ? 1 : 0) }
        return clear * 2 > total
    }

    /// Alpha snapped to 0 or 255, what the pixel-grid reader expects.
    static func hardened(_ b: Bitmap) -> Bitmap {
        var out = b
        for i in stride(from: 3, to: out.px.count, by: 4) { out.px[i] = out.px[i] >= 128 ? 255 : 0 }
        return out
    }

    /// Vision's subject lift (macOS 14+), 0 to 1 per pixel. nil on macOS 13, on failure, or when it finds no subject.
    private static func visionMask(_ image: CGImage, width: Int, height: Int) -> [Float]? {
        guard #available(macOS 14, *) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first, !obs.allInstances.isEmpty,
              let buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var mask = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width { mask[y * width + x] = row[x] }
        }
        return mask.contains { $0 >= 0.5 } ? mask : nil
    }

    /// Fallback cutout: grow the background in from every border pixel while colours stay close
    /// to the neighbour it came from and to the border's typical colour.
    static func floodFillMask(_ b: Bitmap, step: Int = 28, total: Int = 110) -> [Bool] {
        let w = b.width, h = b.height
        func dist(_ i: Int, _ j: Int) -> Int {
            abs(Int(b.px[i * 4]) - Int(b.px[j * 4])) + abs(Int(b.px[i * 4 + 1]) - Int(b.px[j * 4 + 1]))
                + abs(Int(b.px[i * 4 + 2]) - Int(b.px[j * 4 + 2]))
        }
        var border: [Int] = []
        for x in 0..<w { border += [x, (h - 1) * w + x] }
        for y in 0..<h { border += [y * w, y * w + w - 1] }
        // Median border colour, as a pixel index, is the reference for "still background".
        let ref = border.sorted { lum(b, $0) < lum(b, $1) }[border.count / 2]
        var background = [Bool](repeating: false, count: w * h)
        var queue: [Int] = []
        for i in border where !background[i] && dist(i, ref) < total { background[i] = true; queue.append(i) }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let j = ny * w + nx
                if !background[j] && dist(i, j) < step && dist(j, ref) < total { background[j] = true; queue.append(j) }
            }
        }
        return background.map { !$0 }
    }

    private static func lum(_ b: Bitmap, _ i: Int) -> Int { Int(b.px[i * 4]) * 3 + Int(b.px[i * 4 + 1]) * 6 + Int(b.px[i * 4 + 2]) }

    /// Drops specks: keeps connected parts at least 8% of the largest one.
    private static func keepMainParts(_ mask: inout [Bool], _ w: Int, _ h: Int, corners: Bool = false) {
        let steps = corners ? [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)] : [(-1, 0), (1, 0), (0, -1), (0, 1)]
        var label = [Int32](repeating: -1, count: w * h)
        var sizes: [Int] = []
        for start in 0..<(w * h) where mask[start] && label[start] < 0 {
            let id = Int32(sizes.count)
            var stack = [start], count = 0
            label[start] = id
            while let i = stack.popLast() {
                count += 1
                let x = i % w, y = i / w
                for (dx, dy) in steps where x + dx >= 0 && y + dy >= 0 && x + dx < w && y + dy < h {
                    let j = (y + dy) * w + x + dx
                    if mask[j] && label[j] < 0 { label[j] = id; stack.append(j) }
                }
            }
            sizes.append(count)
        }
        guard let big = sizes.max(), big > 0 else { return }
        for i in 0..<(w * h) where mask[i] && sizes[Int(label[i])] * 100 < big * 8 { mask[i] = false }
    }

    private static func bounds(_ mask: [Bool], _ w: Int, _ h: Int) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var r: (Int, Int, Int, Int)?
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                if let b = r { r = (min(b.0, x), max(b.1, x), min(b.2, y), max(b.3, y)) } else { r = (x, x, y, y) }
            }
        }
        return r.map { (minX: $0.0, maxX: $0.1, minY: $0.2, maxY: $0.3) }
    }

    static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > maxPixel else { return image }
        let s = Double(maxPixel) / Double(long)
        let w = max(1, Int((Double(image.width) * s).rounded())), h = max(1, Int((Double(image.height) * s).rounded()))
        guard let ctx = DogRenderer.context(width: w, height: h) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: Pixelating

    /// The cut-out subject as a canvas-sized sprite without outline: area-averaged, at most `maxColors`
    /// colours, hard alpha, centred, lowest row on the ground row.
    /// `height`: subject rows before the outline (PhotoLook.Size: 14, 17 or 20 pt, at `density` art px per point).
    static func base(_ cutout: CGImage, chibi: Bool = true, height: Int = maxSubjectHeight) -> Bitmap {
        if isPixelArt(cutout) { return placedPixelArt(Bitmap(cutout)) }
        let src = Bitmap(chibi ? chibified(cutout) : cutout)
        let maxH = max(8, min(h - 2, height))
        let s = min(Double(maxH) / Double(src.height), Double(maxSubjectWidth) / (Double(src.width) * widen))
        let tw = max(1, min(maxSubjectWidth, Int((Double(src.width) * s * widen).rounded())))
        let th = max(1, min(maxH, Int((Double(src.height) * s).rounded())))
        var small = Bitmap(width: tw, height: th)
        for ty in 0..<th {
            let y0 = ty * src.height / th, y1 = max(y0 + 1, (ty + 1) * src.height / th)
            for tx in 0..<tw {
                let x0 = tx * src.width / tw, x1 = max(x0 + 1, (tx + 1) * src.width / tw)
                var a = 0
                var inside: [Int] = []
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = (y * src.width + x) * 4
                        a += Int(src.px[i + 3])
                        if src.px[i + 3] >= 128 { inside.append(i) }
                    }
                }
                let n = (y1 - y0) * (x1 - x0)
                // Coverage just under half still counts, so thin legs and ears survive.
                guard a * 100 >= n * 255 * 42, !inside.isEmpty else { continue }
                let o = (ty * tw + tx) * 4
                let color = blockColor(src.px, inside)
                for c in 0..<3 { small.px[o + c] = color[c] }
                small.px[o + 3] = 255
            }
        }
        cleanSilhouette(&small)
        let features = quantize(&small, maxColors)
        despeckle(&small, keep: features)
        // Centre on the canvas by the opaque pixels, and stand them on the ground row.
        var out = Bitmap(width: w, height: h)
        guard let box = opaqueBounds(small) else { return out }
        let dx = (w - (box.maxX - box.minX + 1)) / 2 - box.minX, dy = ground - box.maxY
        for y in 0..<th {
            for x in 0..<tw where small.px[(y * tw + x) * 4 + 3] == 255 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                for c in 0..<4 { out.px[(ny * w + nx) * 4 + c] = small.px[(y * tw + x) * 4 + c] }
            }
        }
        return out
    }

    /// Already at sprite size: an AI drawing put back on its grid (or a hand-made sprite). No head growing, widening,
    /// resampling or colour clustering, which would blur its one-pixel lines.
    // ponytail: decided by size alone, so saved characters need no flag; a real photo is never cut out this small.
    static func isPixelArt(_ cutout: CGImage) -> Bool { cutout.width <= w && cutout.height <= h }

    /// Pixel art on the canvas: up to 20 rows as 2x2 blocks on the even grid, so the 1x bar (halved) shows it exactly,
    /// as dense as the hand-drawn characters; taller as is. Its own outline sits on the canvas's bottom row.
    static func placedPixelArt(_ src: Bitmap) -> Bitmap {
        var art = src
        for i in stride(from: 3, to: art.px.count, by: 4) { art.px[i] = art.px[i] >= 128 ? 255 : 0 }
        var out = Bitmap(width: w, height: h)
        out.outlined = true
        guard let box = opaqueBounds(art) else { return out }
        // Clean art keeps every colour (hand-drawn art has about 20, some only 6 apart); noisy AI art merges
        // its near-identical shades until it fits.
        var limit = 6
        while colorCount(art) > maxArtColors && limit <= 48 { mergeNearColors(&art, within: limit); limit += 6 }
        let bw = box.maxX - box.minX + 1, bh = box.maxY - box.minY + 1
        let k = bh * 2 <= h && bw * 2 <= w ? 2 : 1
        let left = (w / k - bw) / 2 * k, top = h - bh * k
        for y in 0..<bh {
            for x in 0..<bw where art.px[((y + box.minY) * art.width + x + box.minX) * 4 + 3] == 255 {
                let from = ((y + box.minY) * art.width + x + box.minX) * 4
                for dy in 0..<k { for dx in 0..<k {
                    let to = ((top + y * k + dy) * w + left + x * k + dx) * 4
                    for c in 0..<4 { out.px[to + c] = art.px[from + c] }
                } }
            }
        }
        return out
    }

    static func colorCount(_ b: Bitmap) -> Int {
        var colors = Set<[UInt8]>()
        for i in stride(from: 0, to: b.px.count, by: 4) where b.px[i + 3] == 255 { colors.insert(Array(b.px[i..<(i + 3)])) }
        return colors.count
    }

    /// Shades within `limit` (summed channel difference) of a more common one become it.
    static func mergeNearColors(_ b: inout Bitmap, within limit: Int) {
        var counts = [[UInt8]: Int]()
        for i in stride(from: 0, to: b.px.count, by: 4) where b.px[i + 3] == 255 { counts[Array(b.px[i..<(i + 3)]), default: 0] += 1 }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.lexicographicallyPrecedes($1.key) }.map(\.key)
        var to = [[UInt8]: [UInt8]]()
        for (k, c) in ranked.enumerated() {
            to[c] = ranked[..<k].first { k2 in to[k2] == k2 && zip(k2, c).map { abs(Int($0) - Int($1)) }.reduce(0, +) <= limit } ?? c
        }
        for i in stride(from: 0, to: b.px.count, by: 4) where b.px[i + 3] == 255 {
            let c = to[Array(b.px[i..<(i + 3)])]!
            for k in 0..<3 { b.px[i + k] = c[k] }
        }
    }

    // MARK: Big head

    /// The hand-drawn look: head grown to about half the height (at most 1.8x), anchored on the neck, so the
    /// body reads smaller. Unchanged when the head is already that big or cannot be found.
    static func chibified(_ cutout: CGImage, useVision: Bool = true) -> CGImage {
        guard let head = headBox(cutout, useVision: useVision) else { return cutout }
        let body = Double(cutout.height) - head.maxY
        // A head box over most of the width (a penguin's beak, a hat brim) grown up to 1.8x became a mushroom wider than the body.
        guard head.width <= Double(cutout.width) * 0.6 else { return cutout }
        let k = min(1.8, body / head.height)
        guard k >= 1.05 else { return cutout }
        let hw = head.width * k, hh = head.height * k
        let hx = head.midX - hw / 2, hy = head.maxY - hh   // top-left coordinates
        let minX = min(0, hx), maxX = max(Double(cutout.width), hx + hw), minY = min(0, hy)
        let W = Int((maxX - minX).rounded(.up)), H = Int((Double(cutout.height) - minY).rounded(.up))
        guard let ctx = DogRenderer.context(width: W, height: H),
              let crop = cutout.cropping(to: head.integral) else { return cutout }
        ctx.interpolationQuality = .high
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX - minX, y: Double(H) - (r.minY - minY) - r.height, width: r.width, height: r.height) }
        ctx.draw(cutout, in: flip(CGRect(x: 0, y: 0, width: cutout.width, height: cutout.height)))
        ctx.draw(crop, in: flip(CGRect(x: hx, y: hy, width: hw, height: hh)))
        return ctx.makeImage() ?? cutout
    }

    /// Where the head is, top-left pixel coordinates: a face (people, often drawings too), an animal's head
    /// joints, else for an upright subject everything above the narrowest row (the neck).
    static func headBox(_ cutout: CGImage, useVision: Bool = true) -> CGRect? {
        let W = Double(cutout.width), H = Double(cutout.height)
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        if useVision, let r = visionHead(cutout) {
            let box = CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: r.width * W, height: r.height * H).intersection(full)
            // A box over most of the width or the top half also holds raised arms: the neck search does better.
            if box.height > 4, box.maxY < H * 0.85, box.width <= W * 0.7, box.height <= H * 0.45 { return box }
        }
        let b = Bitmap(cutout)
        let rows = (0..<b.height).map { y -> (Int, Int)? in
            guard let l = (0..<b.width).first(where: { b.alpha($0, y) >= 128 }),
                  let r = (0..<b.width).last(where: { b.alpha($0, y) >= 128 }) else { return nil }
            return (l, r)
        }
        guard let top = rows.firstIndex(where: { $0 != nil }), let bottom = rows.lastIndex(where: { $0 != nil }) else { return nil }
        let tall = bottom - top + 1
        // ponytail: wide subjects (lying, side-on) have no reliable neck row; they keep their proportions.
        guard Double(tall) >= Double(b.width) * 0.8 else { return nil }
        func width(_ y: Int) -> Int { rows[y].map { $0.1 - $0.0 + 1 } ?? 0 }
        let lo = top + tall / 4, hi = top + tall * 3 / 5
        guard let neck = (lo...hi).min(by: { (width($0), $0) < (width($1), $1) }) else { return nil }
        let widest = (top..<neck).map(width).max() ?? 0
        // No clear neck (a bust, a blob): growing the top would only make a mushroom.
        guard width(neck) * 100 < widest * 85 else { return nil }
        let split = neck
        let spans = (top..<split).compactMap { rows[$0] }
        guard let l = spans.map(\.0).min(), let r = spans.map(\.1).max() else { return nil }
        let box = CGRect(x: l, y: top, width: r - l + 1, height: split - top)
        // A head-and-shoulders photo (not clearly tall) really is mostly head: keep the box, chibi leaves it alone.
        guard Double(tall) >= Double(b.width) * 1.5, box.width > W * 0.7 || box.height > H * 0.45 else { return box }
        // A standing figure whose raised arms or long hair widen the top: the narrowest row is the waist. Take a head-sized
        // square at the top, centred on the top rows' mass (arms up on both sides balance out over the face).
        // ponytail: fixed one-third share; a real head detector would do better.
        let side = Double(tall) / 3
        var sum = 0, count = 0
        for y in top..<(top + Int(side)) { for x in 0..<b.width where b.alpha(x, y) >= 128 { sum += x; count += 1 } }
        guard count > 0 else { return box }
        return CGRect(x: Double(sum) / Double(count) - side / 2, y: Double(top), width: side, height: side).intersection(full)
    }

    /// Normalised head rectangle (Vision coordinates, origin bottom-left) from a face or animal head joints.
    private static func visionHead(_ cutout: CGImage) -> CGRect? {
        // On white, so see-through background does not read as black.
        guard let ctx = DogRenderer.context(width: cutout.width, height: cutout.height) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cutout.width, height: cutout.height))
        ctx.draw(cutout, in: CGRect(x: 0, y: 0, width: cutout.width, height: cutout.height))
        guard let flat = ctx.makeImage() else { return nil }
        let handler = VNImageRequestHandler(cgImage: flat, options: [:])
        let face = VNDetectFaceRectanglesRequest()
        if (try? handler.perform([face])) != nil, let f = face.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
            // Face box is brow to chin; a head adds hair above and around.
            let r = f.boundingBox
            return CGRect(x: r.midX - r.width * 0.85, y: r.minY - r.height * 0.1, width: r.width * 1.7, height: r.height * 1.75)
        }
        if #available(macOS 14, *) {
            let pose = VNDetectAnimalBodyPoseRequest()
            if (try? handler.perform([pose])) != nil, let obs = pose.results?.first,
               let points = try? obs.recognizedPoints(.head).values.filter({ $0.confidence > 0.3 }), points.count >= 3 {
                let xs = points.map(\.location.x), ys = points.map(\.location.y)
                let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                // Joints are ears, eyes and nose: pad for the skull and let the jaw hang below the nose.
                return CGRect(x: r.minX - r.width * 0.25, y: r.minY - r.height * 0.45, width: r.width * 1.5, height: r.height * 1.6)
            }
        }
        return nil
    }

    /// Average of one block, except that a clearly darker minority (eyes, nose, a dark stripe) wins:
    /// plain averaging washes those out, and they are what makes a face read at 16 px.
    static func blockColor(_ px: [UInt8], _ idx: [Int]) -> [UInt8] {
        func lum(_ i: Int) -> Int { (Int(px[i]) * 3 + Int(px[i + 1]) * 6 + Int(px[i + 2])) / 10 }
        let lums = idx.map(lum)
        var lo = Double(lums.min()!), hi = Double(lums.max()!)
        var dark = [Int](), light = [Int]()
        for _ in 0..<4 {   // two-means on brightness
            dark = []; light = []
            for (k, l) in lums.enumerated() { if abs(Double(l) - lo) <= abs(Double(l) - hi) { dark.append(k) } else { light.append(k) } }
            if !dark.isEmpty { lo = Double(dark.map { lums[$0] }.reduce(0, +)) / Double(dark.count) }
            if !light.isEmpty { hi = Double(light.map { lums[$0] }.reduce(0, +)) / Double(light.count) }
        }
        // A mixed block takes one side, not the muddy blend: the dark side when it is a real share, else the light.
        let split = hi - lo >= 60
        // A strongly coloured light side (yellow lenses, a red bow) that fills about half the block keeps its colour.
        func chroma(_ i: Int) -> Int { Int(max(px[i], px[i + 1], px[i + 2])) - Int(min(px[i], px[i + 1], px[i + 2])) }
        let vivid = light.count * 100 >= idx.count * 45 && light.map { chroma(idx[$0]) }.reduce(0, +) > 90 * light.count
        let pick = split && !vivid && dark.count * 100 >= idx.count * 22 ? dark.map { idx[$0] } : split ? light.map { idx[$0] } : idx
        var sum = [0, 0, 0]
        for i in pick { for c in 0..<3 { sum[c] += Int(px[i + c]) } }
        // Plain average: quantize adds the one saturation lift (two lifts turned soft pinks neon).
        return sum.map { UInt8((Double($0) / Double(pick.count)).rounded()) }
    }

    /// Drops opaque pixels with no opaque side neighbour and fills see-through pockets of at most 4 pixels
    /// that the outside cannot reach, with the average of their opaque neighbours.
    static func cleanSilhouette(_ b: inout Bitmap) {
        let w = b.width, h = b.height
        func solid(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && b.px[(y * w + x) * 4 + 3] == 255 }
        for y in 0..<h {
            for x in 0..<w where solid(x, y) && ![(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains(where: solid) {
                b.px[(y * w + x) * 4 + 3] = 0
            }
        }
        var seen = [Bool](repeating: false, count: w * h)
        for start in 0..<(w * h) where !seen[start] && b.px[start * 4 + 3] == 0 {
            var part = [start], head = 0, outside = false
            seen[start] = true
            while head < part.count {
                let i = part[head]; head += 1
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { outside = true }
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let j = ny * w + nx
                    if !seen[j] && b.px[j * 4 + 3] == 0 { seen[j] = true; part.append(j) }
                }
            }
            guard !outside, part.count <= 4 else { continue }
            for i in part {
                let x = i % w, y = i / w
                let near = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].filter(solid).map { ($0.1 * w + $0.0) * 4 }
                guard !near.isEmpty else { continue }
                for c in 0..<3 { b.px[i * 4 + c] = UInt8(near.map { Int(b.px[$0 + c]) }.reduce(0, +) / near.count) }
                b.px[i * 4 + 3] = 255
            }
        }
    }

    /// k-means in Lab to at most `n` colours (seeded by a median cut, so the result never varies), with a
    /// little extra contrast and saturation. Pixels clearly darker than their surroundings (eyes, nose, mouth)
    /// are kept out of the clusters and share one deep colour of their own. Returns those feature pixels.
    @discardableResult
    static func quantize(_ b: inout Bitmap, _ n: Int) -> Set<Int> {
        let w = b.width
        let opaque = (0..<(b.width * b.height)).filter { b.px[$0 * 4 + 3] == 255 }
        guard !opaque.isEmpty else { return [] }
        var lab = [Int: Lab]()
        for i in opaque { lab[i] = Lab(b.px[i * 4], b.px[i * 4 + 1], b.px[i * 4 + 2]) }
        var features = Set<Int>()
        for i in opaque where lab[i]!.l < 48 {
            let x = i % w, y = i / w
            let near = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]
                .filter { x + $0.0 >= 0 && x + $0.0 < w }.compactMap { lab[(y + $0.1) * w + x + $0.0] }
            guard near.count >= 5 else { continue }   // on the edge: that is the outline's job
            let around = near.map(\.l).sorted()[near.count / 2]
            if lab[i]!.l < around - 20 { features.insert(i) }
        }
        let rest = opaque.filter { !features.contains($0) }
        // Median cut seeds: split the box with the widest Lab channel at its median.
        var boxes = rest.isEmpty ? [] : [rest]
        while boxes.count < n {
            var best = -1, bestRange = 0.0, bestChannel = 0
            for (k, box) in boxes.enumerated() where box.count > 1 {
                for c in 0..<3 {
                    let v = box.map { lab[$0]![c] }
                    let r = v.max()! - v.min()!
                    if r > bestRange { best = k; bestRange = r; bestChannel = c }
                }
            }
            guard best >= 0, bestRange > 4 else { break }
            let sorted = boxes[best].sorted { (lab[$0]![bestChannel], $0) < (lab[$1]![bestChannel], $1) }
            boxes[best] = Array(sorted[..<(sorted.count / 2)])
            boxes.append(Array(sorted[(sorted.count / 2)...]))
        }
        var centres = boxes.map { Lab.mean($0.map { lab[$0]! }) }
        var owner = [Int: Int]()
        for _ in 0..<8 {   // Lloyd iterations
            for i in rest { owner[i] = centres.indices.min { lab[i]!.dist(centres[$0]) < lab[i]!.dist(centres[$1]) }! }
            var groups = [[Lab]](repeating: [], count: centres.count)
            for i in rest { groups[owner[i]!].append(lab[i]!) }
            for k in centres.indices where !groups[k].isEmpty { centres[k] = Lab.mean(groups[k]) }
        }
        let meanL = centres.map(\.l).reduce(0, +) / Double(max(1, centres.count))
        let lifted = centres.map { Lab(l: meanL + ($0.l - meanL) * 1.1, a: $0.a * 1.08, b: $0.b * 1.08).rgb }
        for i in rest { let c = lifted[owner[i]!]; for k in 0..<3 { b.px[i * 4 + k] = c[k] } }
        if !features.isEmpty {
            var f = Lab.mean(features.map { lab[$0]! })
            f.l = min(f.l, 10)   // deeper than the outline (about L 25), so a face does not melt into it
            let c = f.rgb
            for i in features { for k in 0..<3 { b.px[i * 4 + k] = c[k] } }
        }
        // Eye candidates: the features plus any inner pixel that came out very dark (a dog's eye is often its own cluster).
        let inner = opaque.filter { i in
            let x = i % w
            return x > 0 && x < w - 1 && [i - 1, i + 1, i - w, i + w].allSatisfy { lab[$0] != nil }
                && Lab(b.px[i * 4], b.px[i * 4 + 1], b.px[i * 4 + 2]).l < 32
        }
        var dark = features.union(inner)
        var deep = features.isEmpty ? [UInt8]([24, 18, 20]) : Array(b.px[(features.first! * 4)..<(features.first! * 4 + 3)])
        if features.isEmpty, let i = inner.first { deep = Array(b.px[(i * 4)..<(i * 4 + 3)]) }
        eyes(&b, &dark, dark: deep)
        return features.union(dark)
    }

    /// Eye-sized, roundish feature blobs (3 to 9 px, at most 2:1) are closed into an elliptical ring, keeping their
    /// own centre, and get a 1 px glint: an arc of a spiral or wide eye then reads as an open eye, not a '^' smile,
    /// and solid eyes stop being flat holes. Long thin blobs (mouths, stripes) are left alone.
    static func eyes(_ b: inout Bitmap, _ features: inout Set<Int>, dark: [UInt8]) {
        let w = b.width, h = b.height
        var seen = Set<Int>()
        for start in features.sorted() where !seen.contains(start) {
            var part = [start], head = 0
            seen.insert(start)
            while head < part.count {
                let i = part[head]; head += 1
                for dy in -1...1 { for dx in -1...1 {
                    let x = i % w + dx, y = i / w + dy, j = y * w + x
                    if x >= 0, y >= 0, x < w, y < h, features.contains(j), !seen.contains(j) { seen.insert(j); part.append(j) }
                } }
            }
            let xs = part.map { $0 % w }, ys = part.map { $0 / w }
            let x0 = xs.min()!, y0 = ys.min()!, bw = xs.max()! - x0 + 1, bh = ys.max()! - y0 + 1
            guard (3...9).contains(bw), (3...9).contains(bh), max(bw, bh) <= 2 * min(bw, bh) else { continue }
            let rx = Double(bw) / 2, ry = Double(bh) / 2
            for y in y0..<(y0 + bh) {
                for x in x0..<(x0 + bw) where b.px[(y * w + x) * 4 + 3] == 255 {
                    let ex = (Double(x - x0) + 0.5 - rx) / rx, ey = (Double(y - y0) + 0.5 - ry) / ry
                    let r = ex * ex + ey * ey, inner = (abs(ex) * rx - 1) / max(0.5, rx - 1)
                    // On the ellipse's 1 px rim: inside the ellipse, outside the one a pixel smaller.
                    let innerY = (abs(ey) * ry - 1) / max(0.5, ry - 1)
                    guard r <= 1.05, inner * inner + innerY * innerY > 0.7 || min(bw, bh) < 4 else { continue }
                    let i = y * w + x
                    for k in 0..<3 { b.px[i * 4 + k] = dark[k] }
                    features.insert(i)
                }
            }
            let g = (y0 + bh / 3) * w + x0 + bw / 3
            for k in 0..<3 { b.px[g * 4 + k] = 250 }
            features.insert(g)   // despeckle keeps it
        }
    }

    /// A lone pixel whose colour none of its 8 neighbours share takes the most common neighbour colour,
    /// except the dark features, which are allowed to be one pixel.
    static func despeckle(_ b: inout Bitmap, keep: Set<Int>) {
        let w = b.width, h = b.height, src = b.px
        for y in 0..<h {
            for x in 0..<w where src[(y * w + x) * 4 + 3] == 255 && !keep.contains(y * w + x) {
                let me = Array(src[((y * w + x) * 4)..<((y * w + x) * 4 + 3)])
                var counts = [[UInt8]: Int]()
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h, src[(ny * w + nx) * 4 + 3] == 255 else { continue }
                    counts[Array(src[((ny * w + nx) * 4)..<((ny * w + nx) * 4 + 3)]), default: 0] += 1
                }
                let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.lexicographicallyPrecedes($1.key) }
                guard counts[me] == nil, let top = ranked.first, top.value >= 3 else { continue }
                for c in 0..<3 { b.px[(y * w + x) * 4 + c] = top.key[c] }
            }
        }
    }

    static func opaqueBounds(_ b: Bitmap) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        bounds((0..<(b.width * b.height)).map { b.px[$0 * 4 + 3] > 0 }, b.width, b.height)
    }

    // MARK: Poses

    /// One frame's motion, in art pixels: shift, forward lean (top rows shear right), breathing stretch, effects.
    struct Motion {
        var dx = 0, dy = 0, lean = 0, breath = 0
        /// Which side of the bottom quarter lifts (steps, at most 2 art px); height and width in percent, anchored on the ground
        /// (squash on landing, lying down).
        var step = 0, squash = 100, stretch = 100
        var speedLines = false, sweat = false, zz = false
        var phase = 0
    }

    /// Frame counts match the dog: lying 3, walks 4, run 4, sprint 6, exhausted 6. One unit = one point.
    static func motions(_ pose: DogPose) -> [Motion] {
        let d = density
        func m(_ f: (inout Motion) -> Void) -> Motion { var x = Motion(); f(&x); return x }
        switch pose {
        case .lying: return [0, 1, 0].enumerated().map { i, b in m { $0.breath = b * d; $0.zz = true; $0.phase = i } }
        // Walks differ by bob, lean and step cadence: slow steps without bobbing, fast steps every frame.
        case .slowWalk: return [0, 1, 0, -1].map { s in m { $0.step = s * d } }
        case .walk: return zip([0, -1, 0, -1], [1, 0, -1, 0]).map { b, s in m { $0.dy = b * d; $0.lean = d; $0.step = s * d } }
        case .fastWalk: return zip([-1, 0, -1, 0], [1, -1, 1, -1]).map { b, s in m { $0.dy = b * d; $0.lean = d; $0.step = s * d } }
        case .run:
            // Hop of 1.5 pt with a squash as the feet land.
            return [0, 2, 3, 1].enumerated().map { i, up in
                m {
                    $0.dy = -up; $0.lean = 2 * d; $0.step = i % 2 == 0 ? d : -d; $0.speedLines = true; $0.phase = i
                    if up == 0 { $0.squash = 88; $0.stretch = 110 } else if up == 3 { $0.squash = 104 }
                }
            }
        case .sprint:
            return [0, 2, 3, 3, 1, 0].enumerated().map { i, up in
                m {
                    $0.dy = -up; $0.lean = 2 * d + (up == 3 ? 1 : 0); $0.speedLines = true; $0.phase = i
                    if up == 0 { $0.squash = i == 0 ? 86 : 94; $0.stretch = i == 0 ? 112 : 105 }
                }
            }
        case .exhausted:
            return [0, 1, 0, -1, 1, 0].enumerated().map { i, s in
                m { $0.dx = s * d; $0.sweat = true; $0.phase = i; if i % 3 == 2 { $0.squash = 94; $0.stretch = 104 } }
            }
        }
    }

    /// Every pose as RGBA frames (premultiplied, like the other characters), grouped in DogPose order.
    /// `bases` are outline-free sprites from `base`; a missing slot falls back as `CustomSlot.source` says.
    /// Sleeping without a 쉴 때 picture squashes the stand-in down so it still reads as lying.
    /// `flip` mirrors the pictures, for subjects facing left (leaning and speed lines assume facing right).
    /// `ring`: outline rings in art px (PhotoLook.Outline: 0, 1 or 2).
    static func frames(_ bases: [CustomSlot: Bitmap], lightRim: Bool = false, flip: Bool = false, ring: Int = 1) -> [[[UInt8]]] {
        DogPose.allCases.map { pose in
            let slot = CustomSlot.forPose(pose)
            var b = slot.source(among: Set(bases.keys)).flatMap { bases[$0] } ?? Bitmap(width: w, height: h)
            if flip { b = mirrored(b) }
            let outline = outlineColor(b)
            let lieDown = pose == .lying && bases[.rest] == nil
            return motions(pose).map { var m = $0; if lieDown { m.squash = 70 }; return render(b, m, outline: outline, lightRim: lightRim, ring: ring).cgReady }
        }
    }

    /// Whether the subject seems to face left: its upper third (where a head usually is) is heavier on the left.
    static func facesLeft(_ b: Bitmap) -> Bool {
        guard let box = opaqueBounds(b) else { return false }
        let mid = Double(box.minX + box.maxX) / 2
        var left = 0, right = 0
        for y in box.minY...(box.minY + (box.maxY - box.minY) / 3) {
            for x in box.minX...box.maxX where b.alpha(x, y) == 255 {
                if Double(x) < mid { left += 1 } else if Double(x) > mid { right += 1 }
            }
        }
        return left * 100 > right * 125   // clearly lopsided only; front-on and symmetric subjects stay as they are
    }

    static func render(_ base: Bitmap, _ m: Motion, outline: [UInt8], lightRim: Bool, ring: Int = 1) -> Bitmap {
        var out = Bitmap(width: w, height: h)
        guard let box = opaqueBounds(base) else { return out }
        let height = max(1, box.maxY - box.minY)
        let mid = (box.minY + box.maxY) / 2, cx = (box.minX + box.maxX) / 2
        // Every target pixel looks up where it comes from, so stretching never leaves holes.
        for y in 0..<h {
            for x in 0..<w {
                let fy = y - m.dy
                var sy = box.maxY - Int((Double(box.maxY - fy) * 100 / Double(m.squash)).rounded())
                if m.breath > 0 && sy <= mid { sy = min(mid, sy + m.breath) }
                guard sy >= 0, sy < h else { continue }
                // Lean bends the upper half only (0 at the waist, `lean` at the top), so the base stays under it.
                let up = box.maxY - sy
                let shear = up * 2 > height ? m.lean * (up * 2 - height) / height : 0
                let fx = x - m.dx - shear
                var sx = cx + Int((Double(fx - cx) * 100 / Double(m.stretch)).rounded())
                // A step: one side of the bottom quarter lifts (left for step > 0), the other stays planted.
                if m.step != 0, up * 4 < height, (sx < cx) == (m.step > 0) {
                    sy += min(2, abs(m.step))
                    sx = min(w - 1, max(0, sx))
                    guard sy <= box.maxY else { continue }
                }
                guard sx >= 0, sx < w, base.px[(sy * w + sx) * 4 + 3] == 255 else { continue }
                for c in 0..<4 { out.px[(y * w + x) * 4 + c] = base.px[(sy * w + sx) * 4 + c] }
            }
        }
        func solid(_ b: Bitmap, _ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && b.px[(y * w + x) * 4 + 3] == 255 }
        func put(_ x: Int, _ y: Int, _ c: [UInt8]) {
            guard x >= 0, y >= 0, x < w, y < h, out.px[(y * w + x) * 4 + 3] == 0 else { return }
            for i in 0..<4 { out.px[(y * w + x) * 4 + i] = c[i] }
        }
        // `ring` art px of outline on the four sides and the corners, so the silhouette closes.
        for _ in 0..<(base.outlined ? 0 : ring) {
            let inside = out
            for y in 0..<h {
                for x in 0..<w where !solid(inside, x, y) {
                    let near = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]
                    if near.contains(where: { solid(inside, x + $0.0, y + $0.1) }) { put(x, y, outline) }
                }
            }
        }
        if lightRim {
            let lined = out
            for y in 0..<h {
                for x in 0..<w where !solid(lined, x, y) {
                    if [(-1, 0), (1, 0), (0, -1), (0, 1)].contains(where: { solid(lined, x + $0.0, y + $0.1) }) {
                        put(x, y, [255, 255, 255, 150])
                    }
                }
            }
        }
        guard let now = opaqueBounds(out) else { return out }
        let d = density
        if m.speedLines {
            // Three dashes behind (left of) the body, drifting back each frame; the middle one longest.
            let span = now.maxY - now.minY
            let rows = [now.minY + span / 4, now.minY + span / 2, now.minY + span * 3 / 4]
            for (k, y) in rows.enumerated() where k != 2 || m.phase % 2 == 0 {
                guard let left = (0..<w).first(where: { solid(out, $0, y) }) else { continue }
                let end = left - 2 - (m.phase + k) % 2 * d, len = k == 1 ? 4 * d : 3 * d
                for x in max(0, end - len + 1)...max(0, end) { put(x, y, speedLine) }
            }
        }
        if m.sweat {
            // Two drops by the top front, outside the outline (put skips drawn pixels), sliding down each frame.
            let drop = [".L.", "LLL", "LLD", ".D."]
            let spots = [(now.maxX + 1, now.minY + 3 + m.phase % 3 * d), (now.maxX + 4, now.minY + (m.phase + 1) % 3 * d)]
            for (x0, y0) in spots {
                for (dy, row) in drop.enumerated() {
                    for (dx, ch) in row.enumerated() where ch != "." {
                        put(min(w - 3, x0) + dx, max(0, y0) + dy, ch == "L" ? sweatLight : sweatDark)
                    }
                }
            }
        }
        if m.zz {
            // The dog's z, one art pixel per point, drifting up and growing past the top right corner.
            let z = m.phase >= 2 ? DogStamps.zBig.rows : DogStamps.zSmall.rows
            let zw = z[0].count * d
            let x0 = min(w - zw, now.maxX + 2 + m.phase * d / 2), y0 = max(0, now.minY - 4 - m.phase * d)
            for (y, row) in z.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    for sy in 0..<d { for sx in 0..<d { put(x0 + x * d + sx, y0 + y * d + sy, zColor) } }
                }
            }
        }
        return out
    }

    /// A dense frame at 1 art px per point for 1x screens: a 2x2 block is opaque when at least two of its pixels
    /// are, and on the silhouette's edge it keeps its darkest pixel so the outline survives.
    static func halved(_ rgba: [UInt8]) -> [UInt8] {
        let ow = w / density, oh = h / density
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        func sweat(_ i: Int) -> Bool {
            rgba[i + 3] == 255 && [sweatLight, sweatDark].contains { Array(rgba[i..<(i + 3)]) == Array($0[0..<3]) }
        }
        for y in 0..<oh {
            for x in 0..<ow {
                let block = [(0, 0), (1, 0), (0, 1), (1, 1)].map { ((y * 2 + $0.1) * w + x * 2 + $0.0) * 4 }
                let solid = block.filter { rgba[$0 + 3] == 255 && !sweat($0) }
                guard solid.count >= 2 else { continue }
                func lum(_ i: Int) -> Int { Int(rgba[i]) * 3 + Int(rgba[i + 1]) * 6 + Int(rgba[i + 2]) }
                let o = (y * ow + x) * 4
                if solid.count < 4, let dark = solid.min(by: { lum($0) < lum($1) }) {
                    for c in 0..<3 { out[o + c] = rgba[dark + c] }
                } else {
                    for c in 0..<3 { out[o + c] = UInt8(solid.map { Int(rgba[$0 + c]) }.reduce(0, +) / solid.count) }
                }
                out[o + 3] = 255
            }
        }
        // Each 3x4 sweat drop halves into a '⌐' hook; draw it as a plain vertical drop instead, light over dark.
        var seen = Set<Int>()
        for start in 0..<(w * h) where sweat(start * 4) && !seen.contains(start) {
            var part = [start], head = 0
            seen.insert(start)
            while head < part.count {
                let i = part[head]; head += 1
                for j in [i - 1, i + 1, i - w, i + w] where j >= 0 && j < w * h && sweat(j * 4) && !seen.contains(j) { seen.insert(j); part.append(j) }
            }
            let xs = part.map { $0 % w }, ys = part.map { $0 / w }
            let hx = (xs.min()! + xs.max()!) / 4, hy = ys.min()! / 2
            for (dy, c) in [(0, sweatLight), (1, sweatDark)] where hy + dy < oh && hx < ow {
                let o = ((hy + dy) * ow + hx) * 4
                guard out[o + 3] == 0 else { continue }
                for k in 0..<4 { out[o + k] = c[k] }
            }
        }
        return out
    }

    /// Left-right mirror inside the subject's own box, so it stays where `base` centred it.
    static func mirrored(_ b: Bitmap) -> Bitmap {
        var out = Bitmap(width: b.width, height: b.height)
        out.outlined = b.outlined
        guard let box = opaqueBounds(b) else { return out }
        for y in 0..<b.height {
            for x in box.minX...box.maxX {
                let from = (y * b.width + x) * 4, to = (y * b.width + box.minX + box.maxX - x) * 4
                for c in 0..<4 { out.px[to + c] = b.px[from + c] }
            }
        }
        return out
    }

    /// Dark version of the subject's average colour, so the outline reads without going harsh black.
    static func outlineColor(_ b: Bitmap) -> [UInt8] {
        var sum = [0, 0, 0], n = 0
        for i in stride(from: 0, to: b.px.count, by: 4) where b.px[i + 3] == 255 {
            for c in 0..<3 { sum[c] += Int(b.px[i + c]) }
            n += 1
        }
        guard n > 0 else { return [40, 34, 44, 255] }
        let avg = sum.map { $0 / n }
        return [UInt8(20 + avg[0] * 22 / 100), UInt8(16 + avg[1] * 22 / 100), UInt8(24 + avg[2] * 22 / 100), 255]
    }

    static let speedLine: [UInt8] = [150, 160, 180, 255]
    static let sweatLight: [UInt8] = [0x6C, 0xC6, 0xF7, 255]
    static let sweatDark: [UInt8] = [0x2C, 0x8B, 0xD6, 255]
    static let zColor: [UInt8] = [0x7E, 0x9C, 0xCB, 255]
}

extension Bitmap {
    /// Premultiplied bytes, what DogRenderer.cgImage expects (identical to `px` wherever alpha is 0 or 255).
    var cgReady: [UInt8] {
        var out = px
        for i in stride(from: 0, to: out.count, by: 4) where out[i + 3] < 255 {
            let a = Int(out[i + 3])
            for c in 0..<3 { out[i + c] = UInt8(Int(out[i + c]) * a / 255) }
        }
        return out
    }
}

/// CIE Lab (D65), for clustering colours the way they look.
struct Lab {
    var l: Double, a: Double, b: Double

    init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        func lin(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (R, G, B) = (lin(r), lin(g), lin(b))
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        self.init(l: 116 * f(y) - 16, a: 500 * (f(x) - f(y)), b: 200 * (f(y) - f(z)))
    }

    subscript(_ c: Int) -> Double { c == 0 ? l : c == 1 ? a : b }

    func dist(_ o: Lab) -> Double { (l - o.l) * (l - o.l) + (a - o.a) * (a - o.a) + (b - o.b) * (b - o.b) }

    static func mean(_ v: [Lab]) -> Lab {
        let n = Double(max(1, v.count))
        return Lab(l: v.map(\.l).reduce(0, +) / n, a: v.map(\.a).reduce(0, +) / n, b: v.map(\.b).reduce(0, +) / n)
    }

    /// sRGB bytes, clamped.
    var rgb: [UInt8] {
        let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func inv(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16 / 116) / 7.787 }
        let x = inv(fx) * 0.95047, y = inv(fy), z = inv(fz) * 1.08883
        let lin = [3.2406 * x - 1.5372 * y - 0.4986 * z, -0.9689 * x + 1.8758 * y + 0.0415 * z, 0.0557 * x - 0.2040 * y + 1.0570 * z]
        return lin.map { v in
            let c = max(0, min(1, v))
            return UInt8(((c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255).rounded())
        }
    }
}

/// 다듬기 in the creator: what is left of the background after the automatic cut-out, cleared by hand. Works on a
/// Bitmap (straight RGBA, row 0 on top); a cleared pixel is all zero.
enum CutoutEdit {
    /// Clears the patch touching (`x`, `y`) whose colour is within `tolerance` (largest channel difference) of that
    /// pixel's: 4-connected and only through visible pixels, so the subject past a clear gap is never reached.
    /// nil when the pixel is clear or outside.
    static func eraseSimilar(_ b: Bitmap, x: Int, y: Int, tolerance: Int) -> Bitmap? {
        guard x >= 0, y >= 0, x < b.width, y < b.height, b.alpha(x, y) > 0 else { return nil }
        let s = (y * b.width + x) * 4
        let seed = (Int(b.px[s]), Int(b.px[s + 1]), Int(b.px[s + 2]))
        var out = b, seen = [Bool](repeating: false, count: b.width * b.height), stack = [y * b.width + x]
        seen[stack[0]] = true
        while let p = stack.popLast() {
            let i = p * 4
            let d = max(abs(Int(b.px[i]) - seed.0), abs(Int(b.px[i + 1]) - seed.1), abs(Int(b.px[i + 2]) - seed.2))
            guard b.px[i + 3] > 0, d <= tolerance else { continue }
            for c in 0..<4 { out.px[i + c] = 0 }
            let px = p % b.width, py = p / b.width
            for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)]
            where nx >= 0 && ny >= 0 && nx < b.width && ny < b.height && !seen[ny * b.width + nx] {
                seen[ny * b.width + nx] = true
                stack.append(ny * b.width + nx)
            }
        }
        return out
    }

    /// Clears a disc of `radius` px around (`x`, `y`), the 지우개 brush.
    static func brush(_ b: inout Bitmap, x: Int, y: Int, radius: Int) {
        let x0 = max(0, x - radius), x1 = min(b.width - 1, x + radius), y0 = max(0, y - radius), y1 = min(b.height - 1, y + radius)
        guard x0 <= x1, y0 <= y1 else { return }
        for yy in y0...y1 {
            for xx in x0...x1 where (xx - x) * (xx - x) + (yy - y) * (yy - y) <= radius * radius {
                let i = (yy * b.width + xx) * 4
                for c in 0..<4 { b.px[i + c] = 0 }
            }
        }
    }

    /// Anything left to show.
    static func hasSubject(_ b: Bitmap) -> Bool { stride(from: 3, to: b.px.count, by: 4).contains { b.px[$0] > 0 } }
}

/// The last `limit` states before each edit, for 되돌리기.
struct UndoStack<T> {
    let limit: Int
    private(set) var items: [T] = []
    init(limit: Int = 10) { self.limit = limit }
    mutating func push(_ item: T) {
        items.append(item)
        if items.count > limit { items.removeFirst(items.count - limit) }
    }
    mutating func pop() -> T? { items.popLast() }
    var isEmpty: Bool { items.isEmpty }
}
