import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DogMonitor

final class PhotoTests: XCTestCase {
    /// A JPEG of `w`x`h` noise (hard to compress) with EXIF and GPS tags, or a PNG with a transparent left half.
    private func image(_ w: Int, _ h: Int, noise: Bool = true, gps: Bool = false, png: Bool = false) -> Data {
        var rng = SplitMix64(seed: 3)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            let x = (i / 4) % w
            px[i] = noise ? UInt8(truncatingIfNeeded: rng.next()) : 200
            px[i + 1] = noise ? UInt8(truncatingIfNeeded: rng.next()) : 40
            px[i + 2] = noise ? UInt8(truncatingIfNeeded: rng.next()) : 40
            px[i + 3] = png && x < w / 2 ? 0 : 255
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cg = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.5, kCGImagePropertyGPSLatitudeRef: "N",
                                                    kCGImagePropertyGPSLongitude: 127.0, kCGImagePropertyGPSLongitudeRef: "E"]
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: "secret"]
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func props(_ d: Data) -> [CFString: Any] {
        let src = CGImageSourceCreateWithData(d as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
    }

    private func side(_ d: Data) -> Int {
        let p = props(d)
        return max(p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int)
    }

    func testBigNoisyPhotoShrinksIntoBothBudgetsAsJPEG() throws {
        let input = image(3000, 2000, gps: true)
        XCTAssertNotNil(props(input)[kCGImagePropertyGPSDictionary])
        guard case .success(let p) = PhotoPrep.prepare(input) else { return XCTFail("not prepared") }
        XCTAssertLessThanOrEqual(p.full.count, PhotoRules.fullBudget)
        XCTAssertLessThanOrEqual(p.thumb.count, PhotoRules.thumbBudget)
        XCTAssertLessThanOrEqual(side(p.full), PhotoRules.fullSide)
        XCTAssertLessThanOrEqual(side(p.thumb), PhotoRules.thumbSide)
        for d in [p.full, p.thumb] {
            let src = CGImageSourceCreateWithData(d as CFData, nil)!
            XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.jpeg.identifier)
            XCTAssertNil(props(d)[kCGImagePropertyGPSDictionary])
            XCTAssertNil((props(d)[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        }
        XCTAssertTrue(PhotoPrep.received(p))
    }

    func testTransparencyBecomesWhite() throws {
        guard case .success(let p) = PhotoPrep.prepare(image(200, 100, noise: false, png: true)) else { return XCTFail("not prepared") }
        let rep = NSBitmapImageRep(data: p.full)!
        let left = rep.colorAt(x: 10, y: 50)!.usingColorSpace(.sRGB)!, right = rep.colorAt(x: 190, y: 50)!.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(left.redComponent + left.greenComponent + left.blueComponent, 2.9)
        XCTAssertLessThan(right.greenComponent, 0.4)
    }

    func testOversizeIsRefusedBeforeDecoding() {
        XCTAssertEqual(PhotoPrep.prepare(Data(count: PhotoRules.maxInput + 1)), .failure(.tooBig))
        XCTAssertEqual(PhotoPrep.prepare(image(20_001, 2, noise: false)), .failure(.tooBig))
        XCTAssertEqual(PhotoPrep.prepare(Data("not a picture".utf8)), .failure(.notImage))
        XCTAssertTrue(PhotoRules.inputOK(width: 20_000, height: 4000, bytes: 10))
        XCTAssertFalse(PhotoRules.inputOK(width: 9000, height: 9000, bytes: 10))   // 81 megapixels
        XCTAssertFalse(PhotoRules.inputOK(width: 0, height: 10, bytes: 10))
    }

    private func photo(_ thumb: Int, _ full: Int) -> PreparedPhoto {
        PreparedPhoto(full: Data((0..<full).map { UInt8(truncatingIfNeeded: $0 * 7) }), thumb: Data((0..<thumb).map { UInt8(truncatingIfNeeded: $0) }))
    }

    func testPartsRoundTripAndFitAFrame() throws {
        let p = photo(PhotoRules.thumbBudget, PhotoRules.fullBudget)
        let parts = PhotoPart.split(p, id: 9)
        XCTAssertEqual(parts.count, PhotoRules.maxParts)
        XCTAssertTrue(parts.allSatisfy(\.isSane))
        let frame = try XCTUnwrap(SocialWire.encode(SocialMessage.photo(parts[0])))
        XCTAssertLessThanOrEqual(frame.count, SocialWire.maxFrame)
        XCTAssertTrue(SocialWire.fromNewer(frame))   // an older build skips it instead of closing the link
        var a = PhotoAssembly()
        var out: PreparedPhoto?
        for part in parts { out = a.push(part, from: "f", now: 0) }
        XCTAssertEqual(out, p)
        XCTAssertEqual(a.inFlight, 0)
    }

    func testABadPartDropsThePhoto() {
        let parts = PhotoPart.split(photo(1000, 100_000), id: 1)
        var a = PhotoAssembly()
        _ = a.push(parts[0], from: "f", now: 0)
        XCTAssertNil(a.push(parts[2], from: "f", now: 0))   // skipped one
        XCTAssertNil(a.push(parts[3], from: "f", now: 0))
        XCTAssertEqual(a.inFlight, 0)
        // Lies about sizes are refused before anything is kept.
        var big = parts[0]; big.total = PhotoRules.maxTotal + 1
        var count = parts[0]; count.count = 99
        var thumb = parts[0]; thumb.thumb = PhotoRules.thumbBudget + 1
        var fat = parts[0]; fat.data = Data(count: PhotoRules.chunk + 1)
        for p in [big, count, thumb, fat] { XCTAssertFalse(p.isSane) }
        // Another friend's parts never join this one.
        _ = a.push(parts[0], from: "f", now: 0)
        XCTAssertNil(a.push(parts[1], from: "g", now: 0))
        XCTAssertEqual(a.inFlight, 1)
    }

    func testStartsPerMinuteAreCapped() {
        let one = PhotoPart.split(photo(10, 10), id: 1)
        XCTAssertEqual(one.count, 1)
        var a = PhotoAssembly()
        for _ in 0..<PhotoRules.perMinute { XCTAssertNotNil(a.push(one[0], from: "f", now: 5)) }
        XCTAssertNil(a.push(one[0], from: "f", now: 6))
        XCTAssertNotNil(a.push(one[0], from: "g", now: 6))
        XCTAssertNotNil(a.push(one[0], from: "f", now: 70))
    }

    func testRateLimitTakesOneWholePhotoAndVersionGate() {
        var r = SocialRateLimit()
        let part = SocialMessage.photo(PhotoPart.split(photo(10, 10), id: 1)[0])
        XCTAssertTrue((0..<PhotoRules.maxParts).allSatisfy { _ in r.allow(part, now: 1) })
        XCTAssertFalse(r.allow(part, now: 1))
        XCTAssertTrue(r.allow(part, now: 3.1))
        XCTAssertFalse(PhotoRules.canSend(version: 2))
        XCTAssertFalse(PhotoRules.canSend(version: nil))
        XCTAssertTrue(PhotoRules.canSend(version: SocialBus.version))
    }

    func testReceivedJPEGMustBeSmallAndJPEG() {
        XCTAssertNil(PhotoPrep.checked(image(400, 10, noise: false), side: PhotoRules.thumbSide))
        XCTAssertNil(PhotoPrep.checked(image(10, 10, noise: false, png: true), side: PhotoRules.thumbSide))
        XCTAssertNotNil(PhotoPrep.checked(image(300, 10, noise: false), side: PhotoRules.thumbSide))
    }

    func testChatKeepsOnlyTheNewestFullPhotos() {
        let chat = SocialChat()
        let p = photo(10, 10)
        for _ in 0..<(PhotoRules.keepFull + 3) { chat.append("f", "사진", mine: true, photo: p) }
        let lines = chat.log["f"] ?? []
        XCTAssertEqual(lines.filter { $0.photo?.full != nil }.count, PhotoRules.keepFull)
        XCTAssertNotNil(lines.last?.photo?.full)
        XCTAssertTrue(lines.allSatisfy { $0.photo?.thumb == p.thumb })
    }

    func testFitNeverGrows() {
        XCTAssertEqual(PhotoZoomView.fit(CGSize(width: 320, height: 160), in: CGSize(width: 180, height: 180)), CGSize(width: 180, height: 90))
        XCTAssertEqual(PhotoZoomView.fit(CGSize(width: 50, height: 40), in: CGSize(width: 180, height: 180)), CGSize(width: 50, height: 40))
    }
}
