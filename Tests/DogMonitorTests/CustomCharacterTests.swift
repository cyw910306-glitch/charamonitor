import XCTest
@testable import DogMonitor

final class CustomCharacterTests: XCTestCase {
    private let w = CustomSprite.w, h = CustomSprite.h
    private let d = CustomSprite.density

    /// A 200x300 photo: light grey background, a tall red body with a dark "eye", a small blue foot.
    private func syntheticPhoto() -> CGImage {
        let ctx = DogRenderer.context(width: 200, height: 300)!
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 60, width: 80, height: 180))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 110, y: 200, width: 14, height: 14))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 40, width: 40, height: 20))
        return ctx.makeImage()!
    }

    private func opaque(_ f: [UInt8], _ x: Int, _ y: Int) -> Bool { f[(y * w + x) * 4 + 3] == 255 }
    private func box(_ f: [UInt8]) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        var b = (Int.max, Int.min, Int.max, Int.min)
        for y in 0..<h { for x in 0..<w where f[(y * w + x) * 4 + 3] > 0 { b = (min(b.0, x), max(b.1, x), min(b.2, y), max(b.3, y)) } }
        return (b.0, b.1, b.2, b.3)
    }

    func testPipelineFallbackCutoutPixelatesOntoTheCanvas() throws {
        let cut = try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false))
        // Cropped to the subject: 80 wide, 200 tall (body plus foot).
        XCTAssertEqual(cut.width * 200, cut.height * 80, accuracy: 400)
        let base = CustomSprite.base(cut)
        XCTAssertEqual(base.width, w)
        XCTAssertEqual(base.height, h)
        let frames = CustomSprite.frames([.normal: base])
        let walk = frames[DogPose.walk.rawValue][0]
        XCTAssertEqual(walk.count, w * h * 4)
        // Background gone: corners are clear, and every alpha is hard.
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] { XCTAssertFalse(opaque(walk, x, y)) }
        XCTAssertTrue(stride(from: 3, to: walk.count, by: 4).allSatisfy { walk[$0] == 0 || walk[$0] == 255 })
        // Twice the art density on the same 34x20 pt: 68x40 art px.
        XCTAssertEqual(w, DogSpriteCache.canvasWidth * 2)
        XCTAssertEqual(h, DogSpriteCache.canvasHeight * 2)
        // At most the k-means colours, one dark-feature colour and the outline.
        var colors = Set<[UInt8]>()
        for i in stride(from: 0, to: walk.count, by: 4) where walk[i + 3] > 0 { colors.insert(Array(walk[i..<(i + 3)])) }
        XCTAssertLessThanOrEqual(colors.count, CustomSprite.maxColors + 2)
        // Subject on the dog's ground row, outline one row below it and closing the sides.
        let b = box(walk)
        XCTAssertEqual(b.maxY, CustomSprite.ground + 1)
        XCTAssertEqual((b.maxY + 1) / d, DogPainter.ground + 1)   // the outline shares the dog's outline row
        let outline = CustomSprite.outlineColor(base)
        let bottomMid = ((b.maxY * w) + (b.minX + b.maxX) / 2) * 4
        XCTAssertEqual(Array(walk[bottomMid..<(bottomMid + 4)]), outline)
        let midRow = (b.minY + b.maxY) / 2
        let left = try XCTUnwrap((0..<w).first { opaque(walk, $0, midRow) })
        XCTAssertEqual(Array(walk[((midRow * w) + left) * 4..<((midRow * w) + left) * 4 + 4]), outline)
        // Tall subject: height-limited to 32 art px plus the outline.
        XCTAssertEqual(b.maxY - b.minY + 1, CustomSprite.maxSubjectHeight + 2)
        // The dark eye survived the downscale as its own darker pixels.
        let dark = colors.contains { $0[0] < 80 && $0[1] < 80 && $0[2] < 80 && $0 != Array(outline.prefix(3)) }
        XCTAssertTrue(dark)
    }

    func testPosesKeepFrameCountsSizeAndOffsets() throws {
        let cut = try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false))
        let base = CustomSprite.base(cut)
        let frames = CustomSprite.frames([.rest: base, .normal: base, .busy: base])
        XCTAssertEqual(frames.map(\.count), [3, 4, 4, 4, 4, 6, 6])
        XCTAssertTrue(frames.joined().allSatisfy { $0.count == w * h * 4 })
        let rest = box(CustomSprite.render(base, CustomSprite.Motion(), outline: CustomSprite.outlineColor(base), lightRim: false).px)
        // Bob and hop move the feet up, never below the ground.
        func feet(_ pose: DogPose) -> [Int] {
            frames[pose.rawValue].map { f in (0..<h).last { y in (0..<w).contains { opaque(f, $0, y) && $0 > 0 } }! }
        }
        for pose in [DogPose.slowWalk, .walk, .fastWalk] {
            let lift = feet(pose).map { rest.maxY - $0 }
            XCTAssertEqual(Set(lift).subtracting([0, d]), [], "\(pose) bob \(lift)")
            XCTAssertEqual(lift.contains(d), pose != .slowWalk, "\(pose) bob \(lift)")
            XCTAssertTrue(CustomSprite.motions(pose).contains { $0.step != 0 }, "\(pose) never steps")
        }
        // Without a 쉴 때 picture, sleeping squashes the stand-in down onto the ground.
        XCTAssertTrue(CustomSprite.frames([.normal: base])[DogPose.lying.rawValue] != frames[DogPose.lying.rawValue])
        var lie = CustomSprite.Motion()
        lie.squash = 70
        let asleep = box(CustomSprite.render(base, lie, outline: CustomSprite.outlineColor(base), lightRim: false).px)
        XCTAssertEqual(asleep.maxY, rest.maxY)
        XCTAssertLessThan(asleep.maxY - asleep.minY, rest.maxY - rest.minY - 3)
        XCTAssertEqual(CustomSlot.busy.source(among: [.rest]), .rest)
        XCTAssertEqual(CustomSlot.rest.source(among: [.normal, .busy]), .normal)
        let hop = feet(.run).map { rest.maxY - $0 }
        XCTAssertEqual(hop.max(), 3, "a 1.5 pt hop, so a 34-row subject still fits")
        XCTAssertEqual(hop.min(), 0)
        // Landing squashes: shorter and wider on the ground frame, feet still on the ground.
        let land = CustomSprite.motions(.run)[0]
        XCTAssertLessThan(land.squash, 100)
        XCTAssertGreaterThan(land.stretch, 100)
        let landed = box(frames[DogPose.run.rawValue][0])
        XCTAssertLessThan(landed.maxY - landed.minY, rest.maxY - rest.minY)
        // Exhausted shakes sideways by 1 pt without moving the feet.
        let shake = CustomSprite.motions(.exhausted).map(\.dx)
        XCTAssertEqual(Set(shake), [-d, 0, d])
        XCTAssertEqual(Set(feet(.exhausted)), [rest.maxY])
        // Sprint and run draw speed lines left of the body; exhausted draws sweat.
        XCTAssertTrue(CustomSprite.motions(.sprint).allSatisfy(\.speedLines))
        XCTAssertTrue(CustomSprite.motions(.exhausted).allSatisfy(\.sweat))
        // Same image size as the dog, so the menu bar never jumps.
        let custom = DogSpriteCache(profile: .defaultDog, custom: frames)
        XCTAssertEqual(custom.imageSize, DogSpriteCache(profile: .defaultDog).imageSize)
    }

    /// A 200x300 figure: a round head on a thin neck over a wider body, the head a quarter of the height.
    private func figure() -> CGImage {
        let ctx = DogRenderer.context(width: 200, height: 300)!
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 50, y: 0, width: 100, height: 210))        // body, bottom-left origin
        ctx.fill(CGRect(x: 90, y: 200, width: 20, height: 20))        // neck
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.8, blue: 0.7, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 65, y: 220, width: 70, height: 75))   // head
        return ctx.makeImage()!
    }

    func testBigHeadGrowsTheHeadAndKeepsTheFeet() throws {
        let img = figure()
        let head = try XCTUnwrap(CustomSprite.headBox(img, useVision: false))
        // Found above the neck: the head's rows, not the body's.
        XCTAssertEqual(head.minY, 5, accuracy: 3)
        XCTAssertEqual(head.height, 75, accuracy: 12)
        XCTAssertEqual(head.width, 70, accuracy: 6)
        let big = CustomSprite.chibified(img, useVision: false)
        let grown = try XCTUnwrap(CustomSprite.headBox(big, useVision: false))
        // Head up to 1.8x bigger relative to the body, so its share of the height goes up.
        let before = head.height / Double(img.height), after = grown.height / Double(big.height)
        XCTAssertGreaterThan(after, before * 1.2)
        XCTAssertEqual(grown.width / head.width, 1.8, accuracy: 0.15)
        // The body below the head is untouched: same pixels at the bottom.
        XCTAssertEqual(Bitmap(big).alpha(big.width / 2, big.height - 2), 255)
        // A plain block (no neck) is left as it is.
        let block = try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false))
        XCTAssertNil(CustomSprite.headBox(block, useVision: false))
        XCTAssertTrue(CustomSprite.chibified(block, useVision: false) === block)
        // The option changes the sprite, and off means the old proportions.
        let on = CustomSprite.base(img, chibi: true), off = CustomSprite.base(img, chibi: false)
        XCTAssertNotEqual(on.px, off.px)
    }

    func testQuantizeKeepsDarkFeaturesAndCapsColours() {
        // A 20x20 smooth gradient with a 2x1 black "eye" in the middle.
        var b = Bitmap(width: 20, height: 20)
        for y in 0..<20 {
            for x in 0..<20 {
                let i = (y * 20 + x) * 4
                b.px[i] = UInt8(120 + x * 6); b.px[i + 1] = UInt8(90 + y * 6); b.px[i + 2] = 140; b.px[i + 3] = 255
            }
        }
        for x in 9...10 { let i = (10 * 20 + x) * 4; b.px[i] = 10; b.px[i + 1] = 10; b.px[i + 2] = 10 }
        let features = CustomSprite.quantize(&b, CustomSprite.maxColors)
        XCTAssertEqual(features, [10 * 20 + 9, 10 * 20 + 10])
        var colors = Set<[UInt8]>()
        for i in stride(from: 0, to: b.px.count, by: 4) { colors.insert(Array(b.px[i..<(i + 3)])) }
        XCTAssertLessThanOrEqual(colors.count, CustomSprite.maxColors + 1)
        XCTAssertGreaterThanOrEqual(colors.count, 8)
        XCTAssertLessThan(Int(b.px[(10 * 20 + 9) * 4]), 60)
    }

    func testSilhouetteLosesSpecksAndHoles() {
        var b = Bitmap(width: 10, height: 10)
        for y in 2..<8 { for x in 2..<8 { let i = (y * 10 + x) * 4; b.px[i] = 200; b.px[i + 3] = 255 } }
        b.px[(4 * 10 + 4) * 4 + 3] = 0          // pinhole
        b.px[(0 * 10 + 9) * 4 + 3] = 255        // stray pixel
        CustomSprite.cleanSilhouette(&b)
        XCTAssertEqual(b.alpha(4, 4), 255)
        XCTAssertEqual(b.px[(4 * 10 + 4) * 4], 200)
        XCTAssertEqual(b.alpha(9, 0), 0)
    }

    func testOneXKeepsTheOutline() throws {
        let base = CustomSprite.base(try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false)))
        let frame = CustomSprite.frames([.normal: base])[DogPose.walk.rawValue][0]
        let small = CustomSprite.halved(frame)
        let sw = DogSpriteCache.canvasWidth
        XCTAssertEqual(small.count, sw * DogSpriteCache.canvasHeight * 4)
        XCTAssertTrue(stride(from: 3, to: small.count, by: 4).allSatisfy { small[$0] == 0 || small[$0] == 255 })
        let outline = Array(CustomSprite.outlineColor(base).prefix(3))
        let mid = DogSpriteCache.canvasHeight / 2
        let left = try XCTUnwrap((0..<sw).first { small[(mid * sw + $0) * 4 + 3] == 255 })
        XCTAssertEqual(Array(small[((mid * sw + left) * 4)..<((mid * sw + left) * 4 + 3)]), outline)
    }

    func testMissingSlotsFallBackToNormal() throws {
        let base = CustomSprite.base(try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false)))
        let only = CustomSprite.frames([.normal: base])
        XCTAssertEqual(only[DogPose.sprint.rawValue].count, 6)
        XCTAssertFalse(only[DogPose.lying.rawValue][0].allSatisfy { $0 == 0 })
        let restOnly = CustomSprite.frames([.rest: base])
        XCTAssertEqual(restOnly[DogPose.walk.rawValue], only[DogPose.walk.rawValue])
    }

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chars-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testStorageRoundTrip() throws {
        let root = try tempRoot()
        let cut = try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false))
        let store = CustomCharacterStore(root: root)
        let saved = try store.save(name: "빨강이", lightRim: true, inputs: [.normal: cut, .busy: cut])
        let dir = store.folder(saved.id)
        for file in ["sheet.png", "character.json", "input-normal.png", "input-busy.png"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path), file)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("input-rest.png").path))

        let reopened = CustomCharacterStore(root: root)
        let loaded = try XCTUnwrap(reopened.character(saved.id.uuidString))
        XCTAssertEqual(loaded.name, "빨강이")
        XCTAssertTrue(loaded.lightRim)
        XCTAssertEqual(loaded.frames.map(\.count), saved.frames.map(\.count))
        // Hard pixels come back exactly; the soft rim within PNG rounding.
        for (a, b) in zip(loaded.frames.joined(), saved.frames.joined()) {
            XCTAssertEqual(a.count, b.count)
            XCTAssertTrue(zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
        }
        let inputs = reopened.inputs(saved.id)
        XCTAssertEqual(Set(inputs.keys), [.normal, .busy])
        XCTAssertLessThanOrEqual(inputs[.normal].map { max($0.width, $0.height) } ?? 0, 256)

        // Its own 말투 and sounds come back; old files without them read as none.
        XCTAssertNil(loaded.voice)
        try reopened.save(id: saved.id, name: "빨강이", lightRim: true, inputs: inputs, created: loaded.created, voice: .cry, cries: ["삐!", ""])
        let voiced = try XCTUnwrap(CustomCharacterStore(root: root).character(saved.id.uuidString))
        XCTAssertEqual(voiced.voice, .cry)
        XCTAssertEqual(voiced.cries, ["삐!"])

        // Rename in place keeps the folder.
        try reopened.save(id: saved.id, name: "새 이름", lightRim: false, inputs: inputs, created: loaded.created)
        XCTAssertEqual(reopened.characters.count, 1)
        XCTAssertEqual(reopened.character(saved.id.uuidString)?.name, "새 이름")
    }

    func testCharactersSavedAtTheOldDensityAreRedrawn() throws {
        let root = try tempRoot()
        let cut = try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false))
        let saved = try CustomCharacterStore(root: root).save(name: "옛날", lightRim: false, inputs: [.normal: cut])
        let json = CustomCharacterStore(root: root).folder(saved.id).appendingPathComponent("character.json")
        var text = try String(contentsOf: json, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"canvasWidth\" : \(w)", with: "\"canvasWidth\" : 34")
            .replacingOccurrences(of: "\"canvasHeight\" : \(h)", with: "\"canvasHeight\" : 20")
            .replacingOccurrences(of: "  \"chibi\" : true,\n", with: "")
        XCTAssertTrue(text.contains("\"canvasWidth\" : 34") && !text.contains("chibi"))
        try text.write(to: json, atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(CustomCharacterStore(root: root).character(saved.id.uuidString))
        XCTAssertTrue(loaded.chibi)
        XCTAssertEqual(loaded.frames.map(\.count), saved.frames.map(\.count))
        XCTAssertTrue(loaded.frames.joined().allSatisfy { $0.count == w * h * 4 })
    }

    func testAtMostFiveCharacters() throws {
        let store = CustomCharacterStore(root: try tempRoot())
        let cut = try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false))
        for i in 0..<CustomCharacterStore.maxCount { try store.save(name: "\(i)", lightRim: false, inputs: [.normal: cut]) }
        XCTAssertThrowsError(try store.save(name: "6", lightRim: false, inputs: [.normal: cut]))
        XCTAssertEqual(store.characters.count, CustomCharacterStore.maxCount)
    }

    func testDeleteStaysInsideItsOwnFolder() throws {
        let root = try tempRoot()
        let store = CustomCharacterStore(root: root)
        let cut = try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false))
        let a = try store.save(name: "a", lightRim: false, inputs: [.normal: cut])
        let b = try store.save(name: "b", lightRim: false, inputs: [.normal: cut])
        let sibling = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sibling)

        try store.delete(a.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(a.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(b.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertEqual(store.characters.map(\.id), [b.id])
        XCTAssertThrowsError(try store.delete(a.id))   // already gone

        // A link planted in place of a character folder is refused, and what it points at survives.
        let outside = try tempRoot()
        let victim = outside.appendingPathComponent("victim.txt")
        try Data("x".utf8).write(to: victim)
        let fake = UUID()
        try FileManager.default.createSymbolicLink(at: store.folder(fake), withDestinationURL: outside)
        XCTAssertThrowsError(try store.delete(fake))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testOldSavedCharactersStillLoad() {
        XCTAssertEqual(SpriteCharacter(rawValue: "dog"), .dog)
        XCTAssertNil(SpriteCharacter(rawValue: "girl"), "a removed character loads as the dog")
        XCTAssertEqual(SpriteCharacter(rawValue: "custom"), .custom)
    }

    // MARK: 실사

    /// 자동 다듬기 that lands after the creator closed: merged into what is saved now, and only while the user's own
    /// pictures are the ones it was drawn from.
    func testLateAIDrawingMergesIntoTheSavedCharacter() throws {
        let store = CustomCharacterStore(root: try tempRoot())
        let photo = RealSprite.source(try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false)))
        let basis = [CustomSlot.normal: CGSize(width: photo.width, height: photo.height)]
        let saved = try store.save(name: "젤리", lightRim: false, look: PhotoLook(), inputs: [.normal: photo])
        // Renamed and flipped in a second editor meanwhile: the merge keeps that.
        try store.save(id: saved.id, name: "새 이름", lightRim: false, flipped: true, look: PhotoLook(), inputs: [.normal: photo])
        XCTAssertTrue(store.mergeAI(saved.id, cuts: [.busy: photo, .normal: photo], basis: basis))
        let merged = try XCTUnwrap(store.character(saved.id.uuidString))
        XCTAssertEqual(merged.name, "새 이름")
        XCTAssertTrue(merged.flipped)
        XCTAssertEqual(store.aiSlots(saved.id), [.busy], "never over the user's own 평소")
        XCTAssertEqual(Set(store.inputs(saved.id).keys), [.normal, .busy])
        // The user's own picture is AI-free in the editor; replacing it there and saving drops the stale drawing's basis.
        let other = RealSprite.source(try XCTUnwrap(CustomSprite.cutout(figure(), useVision: false)))
        XCTAssertNotEqual(other.width, photo.width)
        try store.save(id: saved.id, name: "새 이름", lightRim: false, look: PhotoLook(), inputs: [.normal: other])
        XCTAssertFalse(store.mergeAI(saved.id, cuts: [.rest: photo], basis: basis), "drawn from a picture no longer there")
        XCTAssertEqual(store.aiSlots(saved.id), [])
        XCTAssertFalse(store.mergeAI(UUID(), cuts: [.rest: photo], basis: basis), "deleted meanwhile")
    }

    func testRealStyleDrawsEveryPoseAtEveryBackingScale() throws {
        let cut = try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false))
        let real = RealSprite(sources: [.normal: cut], look: PhotoLook())
        let poses = real.poseImages()
        XCTAssertEqual(poses.map(\.count), [3, 4, 4, 4, 4, 6, 6])
        for image in poses.joined() {
            XCTAssertEqual(image.size, NSSize(width: 34, height: 20))
            XCTAssertEqual(image.representations.map(\.pixelsWide).sorted(), [34, 68, 102])
        }
        XCTAssertEqual(ExtraMotion.allCases.map { real.extraImages($0).count }, [4, 4, 6])
        // Big previews are drawn from the source at their own size, not blown up from the bar frames.
        XCTAssertEqual(real.poseImages(pixelSize: 4, scales: [2])[0][0].representations.first?.pixelsWide, 272)
        let frames = real.frames()
        XCTAssertEqual(frames.map(\.count), [3, 4, 4, 4, 4, 6, 6])
        XCTAssertTrue(frames.joined().allSatisfy { $0.count == w * h * 4 })
        // Smooth, not posterized: soft edge pixels and many colours.
        let walk = frames[DogPose.walk.rawValue][0]
        XCTAssertTrue(stride(from: 3, to: walk.count, by: 4).contains { walk[$0] > 0 && walk[$0] < 255 })
    }

    func testRealSizesSetTheSubjectHeight() throws {
        let cut = try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false))
        for size in PhotoLook.Size.allCases {
            let still = RealSprite(sources: [.normal: cut], look: PhotoLook(style: .real, size: size, outline: .none)).stillRGBA()
            var top = h, bottom = 0
            for y in 0..<h { for x in 0..<w where still[(y * w + x) * 4 + 3] >= 128 { top = min(top, y); bottom = max(bottom, y) } }
            XCTAssertEqual(bottom - top + 1, size.points * d, accuracy: 2, "\(size)")
            XCTAssertGreaterThanOrEqual(bottom, h - 3, "\(size) stands on the ground")
        }
    }

    func testRealOutlineWidensTheSilhouette() throws {
        let cut = try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false))
        func covered(_ o: PhotoLook.Outline) -> Int {
            let f = RealSprite(sources: [.normal: cut], look: PhotoLook(style: .real, size: .medium, outline: o)).frames()[DogPose.walk.rawValue][0]
            return stride(from: 3, to: f.count, by: 4).filter { f[$0] >= 128 }.count
        }
        let (none, thin, bold) = (covered(.none), covered(.thin), covered(.bold))
        XCTAssertLessThan(none, thin)
        XCTAssertLessThan(thin, bold)
    }

    func testRealSourceIsTrimmedWithAMargin() {
        // 1500x900, transparent, a 600x700 opaque block off-centre: trimmed to it plus 2 px, then capped at 1024.
        let ctx = DogRenderer.context(width: 1500, height: 900)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 50, width: 600, height: 700))
        let src = RealSprite.source(ctx.makeImage()!)
        XCTAssertEqual(src.width, 604)
        XCTAssertEqual(src.height, 704)
        let big = DogRenderer.context(width: 2400, height: 2400)!
        big.setFillColor(CGColor(gray: 0.5, alpha: 1))
        big.fill(CGRect(x: 0, y: 0, width: 2400, height: 2400))
        XCTAssertEqual(max(RealSprite.source(big.makeImage()!).width, RealSprite.source(big.makeImage()!).height), RealSprite.sourcePixels)
    }

    func testRealCharacterSavesItsLookAndRedrawsFromTheCutout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomCharacterStore(root: root)
        let cut = try XCTUnwrap(CustomSprite.cutout(syntheticPhoto(), useVision: false))
        let look = PhotoLook(style: .real, size: .large, outline: .bold)
        let saved = try store.save(name: "실사", lightRim: false, look: look, inputs: [.normal: cut])
        XCTAssertNotNil(saved.real)
        let loaded = try XCTUnwrap(CustomCharacterStore(root: root).character(saved.id.uuidString))
        XCTAssertEqual(loaded.look, look)
        XCTAssertEqual(loaded.real, saved.real)
        XCTAssertEqual(loaded.frames.map(\.count), [3, 4, 4, 4, 4, 6, 6])
        // 도트 stays 도트, and a file without a look (before 2.0) reads as 도트.
        let dot = try store.save(name: "도트", lightRim: false, look: .legacy, inputs: [.normal: cut])
        XCTAssertNil(dot.real)
        let meta = store.folder(dot.id).appendingPathComponent("character.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: meta)) as? [String: Any])
        json["look"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: meta)
        let old = try XCTUnwrap(CustomCharacterStore(root: root).character(dot.id.uuidString))
        XCTAssertEqual(old.look, .legacy)
        XCTAssertNil(old.real)
    }

    /// Not a check: `PHOTO_QA_DIR=<폴더> PHOTO_QA_IMAGES='a.jpg|b.png' swift test --filter testPhotoQARenders` writes the
    /// QA renders (RealSpritePreview) for each picture in 실사 and 도트.
    func testPhotoQARenders() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["PHOTO_QA_DIR"], let images = env["PHOTO_QA_IMAGES"] else { throw XCTSkip("QA only") }
        let looks = (env["PHOTO_QA_LOOKS"] ?? "real-medium-thin,pixel-medium-thin").split(separator: ",").map { tag -> (String, PhotoLook) in
            let p = tag.split(separator: "-").map(String.init)
            return (String(tag), PhotoLook(style: .init(rawValue: p[0])!, size: .init(rawValue: p[1])!, outline: .init(rawValue: p[2])!))
        }
        for path in images.split(separator: "|").map(String.init) {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            for (tag, look) in looks {
                try RealSpritePreview.make(path, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)/\(tag)"), look: look)
            }
        }
        // The creator page, on a throwaway preferences suite (never the owner's).
        if let path = env["PHOTO_QA_CREATOR"] {
            let suite = "qa.dogmonitor.photo-creator"
            AppDefaults.store = try XCTUnwrap(UserDefaults(suiteName: suite))
            AppDefaults.store.removePersistentDomain(forName: suite)
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            let cut = try XCTUnwrap(CustomSprite.load(url: URL(fileURLWithPath: path)).flatMap { CustomSprite.cutout($0) }.map(RealSprite.source))
            for (tag, look) in looks {
                let out = URL(fileURLWithPath: dir).appendingPathComponent("creator/\(tag)")
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try RealSpritePreview.creator(cut, look: look, to: out)
            }
        }
    }
}
