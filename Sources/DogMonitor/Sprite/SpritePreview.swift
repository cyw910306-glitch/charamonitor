import AppKit

/// QA and asset renders: one sheet per preset, menu bar strips, the customization matrix, the app icon.
enum SpritePreview {
    static func renderAll(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for preset in DogProfile.presets {
            try write(sheet(DogRenderer.frames(preset.profile)), dir, "sheet-\(preset.id).png")
        }
        try write(menubar(background: PixelColor(hex: "#ECECEC")), dir, "menubar-light.png")
        try write(menubar(background: PixelColor(hex: "#2A2A2A")), dir, "menubar-dark.png")
        try write(customizationMatrix(), dir, "customization-matrix.png")
        try write(icon(), dir, "icon-1024.png")
        try write(icon(small: true), dir, "icon-small-1024.png")   // the 16 and 32 px slots (build_app.sh)
        #if !MAS   // the drawing AI's guide; no AI drawing in the App Store build
        try write(styleReference(), dir, "style-ref.png")   // copy to Resources/style-ref.png (build_app.sh bundles it)
        #endif
        // Reported, not thrown: the images are still useful for finding the cause.
        for problem in problems() { fputs("스프라이트 점검: \(problem)\n", stderr) }
    }

    /// Invariants a stamp edit can break: every dog fits the canvas, and the sleeping z floats clear of it.
    static func problems() -> [String] {
        var out: [String] = []
        for preset in DogProfile.presets {
            let grids = DogRenderer.grids(preset.profile)
            if let s = DogRenderer.union(grids), s.maxX - s.minX + 1 > w {
                out.append("\(preset.id) 폭 \(s.maxX - s.minX + 1)px, 캔버스 \(w)px를 넘어 잘림")
            }
            for g in grids[DogPose.lying.rawValue] {
                let touching = (0..<g.height).contains { y in
                    (0..<g.width).contains { x in
                        g[x, y].ink == .zz && [g[x - 1, y], g[x + 1, y], g[x, y - 1], g[x, y + 1]].contains { $0.part != .none && $0.part != .fx }
                    }
                }
                if touching { out.append("\(preset.id) 잠자는 z가 강아지에 닿음") }
            }
        }
        return out
    }

    /// --make-character: runs the custom character pipeline on 1 to 3 pictures (쉴 때, 평소, 바쁠 때; one picture
    /// is 평소) and writes the cut-outs, the 8x sheet, and every pose on light and dark bars at 1x and 2x.
    /// `aiArt`: pictures on plain white from the AI, cut out by flood fill like the creator does.
    static func makeCharacter(_ paths: [String], to dir: URL, aiArt: Bool = false) throws {
        let slots = slots(paths.count)
        var bases: [CustomSlot: Bitmap] = [:]
        for (slot, path) in zip(slots, paths) {
            let start = Date()
            guard let image = CustomSprite.load(url: URL(fileURLWithPath: path)) else { throw CocoaError(.fileReadCorruptFile) }
            guard let checked = CustomSprite.checkedCutout(image, useVision: !aiArt, aiArt: aiArt) else { throw CocoaError(.fileReadUnknown) }
            let cut = checked.image
            if checked.unclear { print("경고: 주인공이 잘 안 보여요 (마스크가 화면 대부분이거나 테두리 세 곳 이상에 닿음)") }
            try write(cut, dir, "cutout-\(slot.rawValue).png")
            let base = CustomSprite.base(cut, chibi: !aiArt)
            bases[slot] = base
            var colors = Set<[UInt8]>()
            for i in stride(from: 0, to: base.px.count, by: 4) where base.px[i + 3] > 0 { colors.insert(Array(base.px[i..<(i + 4)])) }
            let box = CustomSprite.opaqueBounds(base)
            print("\(slot.label): \(path) \(image.width)x\(image.height), 잘라낸 \(cut.width)x\(cut.height), "
                  + "스프라이트 \(box.map { "\($0.maxX - $0.minX + 1)x\($0.maxY - $0.minY + 1)" } ?? "비었음"), 색 \(colors.count)개, "
                  + (CustomSprite.isPixelArt(cut) ? "도트 격자 복원, " : "")
                  + "머리 \(CustomSprite.headBox(cut).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "못 찾음"), "
                  + String(format: "%.2f초", Date().timeIntervalSince(start)))
        }
        // Same default as the creator: the first picture decides whether it faces left.
        let flip = slots.first.flatMap { bases[$0] }.map(CustomSprite.facesLeft) ?? false
        if flip { print("왼쪽을 보는 것 같아 좌우를 뒤집었어요") }
        for rim in [false, true] {
            let frames = CustomSprite.frames(bases, lightRim: rim, flip: flip)
            let tag = rim ? "-rim" : ""
            try write(sheet(frames), dir, "sheet\(tag).png")
            for (name, bg) in [("light", PixelColor(hex: "#ECECEC")), ("dark", PixelColor(hex: "#2A2A2A"))] {
                for scale in [1, 2] {
                    try write(poseStrip(frames, background: bg, scale: scale), dir, "menubar\(tag)-\(name)@\(scale)x.png")
                }
            }
        }
    }

    private static func slots(_ count: Int) -> [CustomSlot] { count == 1 ? [.normal] : Array(CustomSlot.allCases.prefix(count)) }

    #if !MAS   // no AI drawing in the App Store build
    /// --make-character-chatgpt: the same pictures through this Mac's ChatGPT (Codex) first, no key and no server,
    /// saved as ai-<slot>.png, then --make-character on those drawings. Uses that account's usage.
    static func makeCharacterAI(_ paths: [String], to dir: URL, chatGPT: ChatGPTCharacterClient) throws {
        var photos: [CustomSlot: CGImage] = [:]
        for (slot, path) in zip(slots(paths.count), paths) {
            guard let image = CustomSprite.load(url: URL(fileURLWithPath: path)) else { throw CocoaError(.fileReadCorruptFile) }
            // Like the creator: the subject and a margin, not the whole frame.
            photos[slot] = CustomSprite.checkedCutout(image).map { CustomSprite.crop(image, around: $0.box) } ?? image
        }
        let start = Date()
        let drawn = try chatGPT.draw(photos: photos) { print("내 ChatGPT가 그리는 중… (\($0)/\($1))") }
        print(String(format: "AI 그림 %d장, %.1f초 · 이 맥의 ChatGPT", drawn.count, Date().timeIntervalSince(start)))
        // Every pose comes back, the empty slots from the nearest photo; use whatever came back.
        var drawings: [String] = []
        for slot in CustomSlot.allCases {
            guard let image = drawn[slot] else { print("\(slot.label) 그림이 오지 않았어요"); continue }
            try write(image, dir, "ai-\(slot.rawValue).png")
            drawings.append(dir.appendingPathComponent("ai-\(slot.rawValue).png").path)
        }
        guard drawings.count == 3 || drawings.count == 1 && drawn[.normal] != nil else {
            throw AICharacterClient.Failure(message: "AI 그림이 일부만 와서 칸을 맞출 수 없어요. 다시 해 주세요.")
        }
        try makeCharacter(drawings, to: dir, aiArt: true)
    }

    /// --make-character-claude: the same pictures through 내 Claude (this Mac's Claude Code, the Keychain token or, with
    /// JELLY_CLAUDE_CLI_LOGIN=1, the CLI's own sign-in), then frames.json, the 8x sheet and the menu bar strips.
    static func makeCharacterClaude(_ paths: [String], to dir: URL, client: ClaudeCharacterClient) throws {
        var photos: [CustomSlot: CGImage] = [:]
        for (slot, path) in zip(slots(paths.count), paths) {
            guard let image = CustomSprite.load(url: URL(fileURLWithPath: path)) else { throw CocoaError(.fileReadCorruptFile) }
            photos[slot] = CustomSprite.checkedCutout(image).map { CustomSprite.crop(image, around: $0.box) } ?? image
        }
        let start = Date()
        let art = try client.draw(photos: photos) { step, steps in
            print("내 Claude가 그리는 중… (\(step)/\(steps) \(step == 1 ? "그리기" : "다듬기"))")
        }
        print(String(format: "Claude 그림 색 %d개, 동작별 %@장, %.1f초", art.palette.count,
                     DogPose.allCases.map { "\(art.poses[FrameArt.key($0)]?.count ?? 0)" }.joined(separator: "/"), Date().timeIntervalSince(start)))
        try art.json.write(to: dir.appendingPathComponent("frames.json"))
        try write(sheet(art.nativeFrames()), dir, "sheet.png")
        let frames = art.frames()
        for (name, bg) in [("light", PixelColor(hex: "#ECECEC")), ("dark", PixelColor(hex: "#2A2A2A"))] {
            for scale in [1, 2] { try write(poseStrip(frames, background: bg, scale: scale), dir, "menubar-\(name)@\(scale)x.png") }
        }
    }

    #endif
    /// Frame 0 of every pose side by side on a 24 pt bar.
    private static func poseStrip(_ frames: [[[UInt8]]], background: PixelColor, scale s: Int) -> CGImage {
        let gap = 6 * s, bar = 24 * s, margin = 8 * s
        let board = Board(margin * 2 + frames.count * (w * s + gap) - gap, bar, background)
        for (i, pose) in frames.enumerated() {
            board.draw(s == 1 ? DogRenderer.art1x(pose[0]) : DogRenderer.art(pose[0]), margin + i * (w * s + gap), (bar - h * s) / 2, width: w * s, height: h * s)
        }
        return board.image
    }

    private static let w = DogSpriteCache.canvasWidth, h = DogSpriteCache.canvasHeight

    /// Rows are poses, columns are frames, 8x.
    static func sheet(_ frames: [[[UInt8]]]) -> CGImage {
        let s = 8, pad = 12, cols = frames.map(\.count).max() ?? 1
        let board = Board(pad + cols * (w * s + pad), pad + frames.count * (h * s + pad), PixelColor(hex: "#CFCFCF"))
        for (row, poseFrames) in frames.enumerated() {
            for (col, rgba) in poseFrames.enumerated() {
                let x = pad + col * (w * s + pad), y = pad + row * (h * s + pad)
                board.fill(x, y, w * s, h * s, PixelColor(hex: "#E6E6E6"))
                board.draw(DogRenderer.art(rgba), x, y, width: w * s, height: h * s)
            }
        }
        return board.image
    }

    /// Every preset's walk and sprint frame at real menu bar size, drawn @2x on a 24 pt bar.
    private static func menubar(background: PixelColor) -> CGImage {
        let characters = DogProfile.presets.map { DogRenderer.frames($0.profile) }
        let perRow = 6, s = 2, gap = 4, spacing = 20, bar = 24 * s, margin = 16
        let item = w * s * 2 + gap
        let rows = (characters.count + perRow - 1) / perRow
        let board = Board(margin * 2 + perRow * item + (perRow - 1) * spacing, margin * 2 + rows * bar + (rows - 1) * 8, background)
        for (i, frames) in characters.enumerated() {
            let x = margin + (i % perRow) * (item + spacing)
            let y = margin + (i / perRow) * (bar + 8) + (bar - h * s) / 2
            board.draw(DogRenderer.cgImage(frames[DogPose.walk.rawValue][0]), x, y, scale: s)
            board.draw(DogRenderer.cgImage(frames[DogPose.sprint.rawValue][0]), x + w * s + gap, y, scale: s)
        }
        return board.image
    }

    /// The default dog with one parameter changed per cell. Rows: ears, tails, snouts, builds, patterns, fluffy.
    private static func customizationMatrix() -> CGImage {
        let base = DogProfile.defaultDog
        func vary(_ change: (inout DogProfile) -> Void) -> DogProfile { var p = base; change(&p); return p }
        let rows: [[DogProfile]] = [
            EarStyle.allCases.map { e in vary { $0.ears = e } },
            TailStyle.allCases.map { t in vary { $0.tail = t } },
            SnoutStyle.allCases.map { n in vary { $0.snout = n } },
            BodyBuild.allCases.map { b in vary { $0.build = b } },
            // A dark secondary so every pattern shape is easy to see.
            CoatPattern.allCases.map { c in vary { $0.pattern = c; $0.secondaryColor = RGBColor(hex: "#5A3B29") } },
            [false, true].map { f in vary { $0.fluffy = f } },
        ]
        let s = 8, pad = 12, cols = rows.map(\.count).max() ?? 1
        let board = Board(pad + cols * (w * s + pad), pad + rows.count * (h * s + pad), PixelColor(hex: "#CFCFCF"))
        for (r, profiles) in rows.enumerated() {
            for (c, profile) in profiles.enumerated() {
                let x = pad + c * (w * s + pad), y = pad + r * (h * s + pad)
                board.fill(x, y, w * s, h * s, PixelColor(hex: "#E6E6E6"))
                board.draw(DogRenderer.cgImage(DogRenderer.frames(profile)[DogPose.walk.rawValue][0]), x, y, scale: s)
            }
        }
        return board.image
    }

    #if !MAS
    /// The AI's style guide: hand-drawn side-view frames at 8x on white (jelly and the toy poodle walking and lying, a
    /// shiba walking, and the original tan cat), each cropped to its pixels and standing on one baseline.
    static func styleReference() -> CGImage {
        let dogs = ["jelly", "toy-poodle", "shiba"].compactMap { id in DogProfile.presets.first { $0.id == id } }.map { DogRenderer.frames($0.profile) }
        // Only the body: the sleeping z floats clear of it, and the AI must not copy effects the app adds itself.
        let picks = ([(0, DogPose.walk), (0, .lying), (1, .walk), (1, .lying), (2, .walk)].map { dogs[$0.0][$0.1.rawValue][0] }
            + (OriginalCharacterSet2.named("original-tan-cat").map { [$0.poseRGBA[DogPose.walk.rawValue][0]] } ?? [])).map(largestPart)
        let s = 8, pad = 16
        let boxes = picks.map { opaqueBounds($0)! }
        let width = pad + boxes.map { ($0.maxX - $0.minX + 1) * s + pad }.reduce(0, +)
        let tallest = boxes.map { $0.maxY - $0.minY + 1 }.max()! * s
        let board = Board(width, tallest + pad * 2, PixelColor(hex: "#FFFFFF"))
        var x = pad
        for (rgba, box) in zip(picks, boxes) {
            let bw = box.maxX - box.minX + 1, bh = box.maxY - box.minY + 1
            let crop = DogRenderer.cgImage(rgba).cropping(to: CGRect(x: box.minX, y: box.minY, width: bw, height: bh))!
            board.draw(crop, x, pad + tallest - bh * s, scale: s)
            x += bw * s + pad
        }
        return board.image
    }

    #endif
    /// `rgba` with only its largest part, corners counting as touching.
    static func largestPart(_ rgba: [UInt8]) -> [UInt8] {
        var label = [Int](repeating: -1, count: w * h), sizes: [Int] = []
        for start in 0..<(w * h) where rgba[start * 4 + 3] != 0 && label[start] < 0 {
            var stack = [start]
            label[start] = sizes.count
            sizes.append(0)
            while let i = stack.popLast() {
                sizes[sizes.count - 1] += 1
                for dy in -1...1 { for dx in -1...1 {
                    let x = i % w + dx, y = i / w + dy, j = y * w + x
                    if x >= 0, y >= 0, x < w, y < h, rgba[j * 4 + 3] != 0, label[j] < 0 { label[j] = label[start]; stack.append(j) }
                } }
            }
        }
        guard let big = sizes.indices.max(by: { sizes[$0] < sizes[$1] }) else { return rgba }
        var out = rgba
        for i in 0..<(w * h) where label[i] != big { for c in 0..<4 { out[i * 4 + c] = 0 } }
        return out
    }

    /// Jelly running, centred on a soft rounded square.
    /// One character on the icon: a 34x20 frame drawn `scale` times, feet centred on (`centerX`, `groundY`) from the top.
    private struct Actor { var rgba: [UInt8]; var scale: Int; var centerX: Int; var groundY: Int }

    /// The app icon: Jelly running up front, the tan cat and the robot behind, on the warm rounded square with a soft
    /// shadow. `small`: Jelly alone and bigger, for the 16 and 32 px slots where three figures turn to specks.
    static func icon(small: Bool = false) -> CGImage {
        let size = 1024
        let board = Board(size, size, nil)
        let ctx = board.ctx
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let path = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(path)
        ctx.setFillColor(PixelColor(hex: "#FBE6D2").cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // Lighter than Jelly's apricot coat at the bottom, so the lead still stands out when the icon is tiny.
        let colors = [PixelColor(hex: "#FBE6D2"), PixelColor(hex: "#FFF8F0")].map(\.cgColor) as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        }
        ctx.restoreGState()

        let jelly = DogRenderer.frames(.defaultDog)[DogPose.run.rawValue][0]
        func original(_ id: String) -> [UInt8] { OriginalCharacterSet2.named(id)?.poseRGBA[DogPose.walk.rawValue][0] ?? jelly }
        let actors = small ? [Actor(rgba: jelly, scale: 19, centerX: 512, groundY: 680)]
            : [Actor(rgba: original("original-tan-cat"), scale: 13, centerX: 320, groundY: 450),
               Actor(rgba: DogRenderer.frames(DogProfile.presets.first { $0.id == "husky" }?.profile ?? .defaultDog)[DogPose.walk.rawValue][0],
                     scale: 13, centerX: 724, groundY: 450),
               Actor(rgba: jelly, scale: 18, centerX: 512, groundY: 790)]
        for a in actors {
            guard let box = opaqueBounds(a.rgba) else { continue }
            let bw = box.maxX - box.minX + 1, s = a.scale
            let x = a.centerX - (box.minX * s + bw * s / 2)
            let y = a.groundY - (box.maxY + 1) * s
            // Soft ground shadow under the feet.
            ctx.setFillColor(CGColor(srgbRed: 0.45, green: 0.3, blue: 0.2, alpha: 0.16))
            ctx.fillEllipse(in: CGRect(x: CGFloat(a.centerX) - CGFloat(bw * s) * 0.42, y: CGFloat(size - a.groundY) - 22,
                                       width: CGFloat(bw * s) * 0.84, height: 40))
            board.draw(DogRenderer.cgImage(a.rgba), x, y, scale: s)
        }
        return board.image
    }

    private static func opaqueBounds(_ rgba: [UInt8]) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var r: (Int, Int, Int, Int)?
        for y in 0..<h {
            for x in 0..<w where rgba[(y * w + x) * 4 + 3] != 0 {
                if let b = r { r = (min(b.0, x), max(b.1, x), min(b.2, y), max(b.3, y)) } else { r = (x, x, y, y) }
            }
        }
        return r.map { (minX: $0.0, maxX: $0.1, minY: $0.2, maxY: $0.3) }
    }

    /// 그림 스타일 side by side, for checking and for store shots: one row per style (자동, 도트, 일러스트), the walk frame
    /// of the dog, the first cat and every built-in original at 4x on a light bar. Packs are never read here.
    static func renderStyles(to out: URL) throws {
        let readies: [any AnimatedCharacter] = Array(CatCatalog.all.prefix(1)) + OriginalCharacterSet2.all
        let k: CGFloat = 4, w = CGFloat(DogSpriteCache.canvasWidth) * k, h = CGFloat(DogSpriteCache.canvasHeight) * k, pad: CGFloat = 12
        let rows = RenderStyle.allCases.map { style in
            [DogSpriteCache(profile: .defaultDog, pixelSize: k, style: style)] + readies.map { DogSpriteCache($0, pixelSize: k, style: style) }
        }
        let cols = CGFloat(rows[0].count)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((w + pad) * cols * 2), pixelsHigh: Int((h + pad) * CGFloat(rows.count) * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: (w + pad) * cols, height: (h + pad) * CGFloat(rows.count))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(cgColor: PixelColor(hex: "#ECECEC").cgColor)?.setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        for (r, caches) in rows.enumerated() {
            for (c, cache) in caches.enumerated() {
                NSGraphicsContext.current?.imageInterpolation = cache.smooth ? .high : .none
                cache.frames(for: .walk)[0].draw(in: NSRect(x: CGFloat(c) * (w + pad) + pad / 2, y: CGFloat(rows.count - 1 - r) * (h + pad) + pad / 2,
                                                             width: w, height: h))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: out)
    }

    #if !MAS
    /// Every pose and extra of the pack in `folder`, through the images the app draws: one row per motion (poses,
    /// then extras), its frames on a light (#ECECEC) bar on the left and a dark (#2A2A2A) bar on the right. Pixel packs
    /// at 8x; smooth (HD) packs at their real menu bar sizes, 1x and 2x, then at the pack's own size.
    static func renderPack(_ folder: URL, to out: URL) throws {
        let pack = try CharacterPack(folder: folder)
        let rows = DogPose.allCases.map { pack.frames(for: $0) } + ExtraMotion.allCases.compactMap { pack.frames(forExtra: $0) }
        let scales = pack.smooth ? [1, 2, pack.density] : [8]
        let cols = rows.map(\.count).max() ?? 1, pad = 8, w = DogSpriteCache.canvasWidth, h = DogSpriteCache.canvasHeight
        let cw = scales.reduce(0) { $0 + w * $1 + pad }, ch = h * (scales.max() ?? 1) + pad
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cols * cw * 2, pixelsHigh: rows.count * ch, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = pack.smooth ? .high : .none
        for (k, (name, bar)) in [(NSAppearance.Name.aqua, "#ECECEC"), (.darkAqua, "#2A2A2A")].enumerated() {
            NSColor(cgColor: PixelColor(hex: bar).cgColor)?.setFill()
            NSRect(x: k * cols * cw, y: 0, width: cols * cw, height: rows.count * ch).fill()
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                for (r, frames) in rows.enumerated() {
                    for (c, image) in frames.enumerated() {
                        var x = (k * cols + c) * cw + pad / 2
                        for s in scales {
                            image.draw(in: NSRect(x: x, y: (rows.count - 1 - r) * ch + pad / 2, width: w * s, height: h * s))
                            x += w * s + pad
                        }
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: out)
    }
    #endif

    private static func write(_ image: CGImage, _ dir: URL, _ name: String) throws {
        let url = dir.appendingPathComponent(name)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try data.write(to: url)
    }
}

/// A CGContext addressed from the top-left, in whole pixels.
private final class Board {
    let ctx: CGContext
    let height: Int

    init(_ width: Int, _ height: Int, _ background: PixelColor?) {
        self.height = height
        ctx = DogRenderer.context(width: width, height: height)!
        ctx.interpolationQuality = .none
        if let background { fill(0, 0, width, height, background) }
    }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: PixelColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: x, y: height - y - h, width: w, height: h))
    }

    func draw(_ image: CGImage, _ x: Int, _ y: Int, scale: Int) {
        let w = image.width * scale, h = image.height * scale
        ctx.draw(image, in: CGRect(x: x, y: height - y - h, width: w, height: h))
    }

    /// Into a `w` x `h` box: pixel-exact when enlarging, averaged when shrinking (a dense custom frame at 1x).
    func draw(_ image: CGImage, _ x: Int, _ y: Int, width w: Int, height h: Int) {
        ctx.interpolationQuality = image.width > w ? .high : .none
        defer { ctx.interpolationQuality = .none }
        ctx.draw(image, in: CGRect(x: x, y: height - y - h, width: w, height: h))
    }

    var image: CGImage { ctx.makeImage()! }
}

private extension PixelColor {
    var cgColor: CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
}
