import XCTest
import AppKit
@testable import DogMonitor

final class ExtraMotionTests: XCTestCase {
    private let w = DogSpriteCache.canvasWidth, h = DogSpriteCache.canvasHeight

    func testEveryDogHasHungryAndEatFramesOnTheCanvas() {
        for preset in DogProfile.presets {
            for motion in [ExtraMotion.hungry, .eat] {
                let frames = DogExtras.rgba(preset.profile, motion)
                XCTAssertEqual(frames.count, 4, "\(preset.id) \(motion)")
                for f in frames {
                    XCTAssertEqual(f.count, w * h * 4)
                    // A whole dog, not a stray pixel or two.
                    XCTAssertGreaterThan(stride(from: 3, to: f.count, by: 4).filter { f[$0] != 0 }.count, 120, "\(preset.id) \(motion)")
                }
            }
            XCTAssertTrue(DogExtras.rgba(preset.profile, .special).isEmpty)
            // Dog plus bowl fit the canvas, so nothing is cut off.
            XCTAssertLessThanOrEqual(DogExtras.layout(preset.profile).width, w, preset.id)
        }
        let images = DogExtras.frames(profile: .defaultDog, pixelSize: 1, motion: .eat)
        XCTAssertEqual(images.first?.size, DogSpriteCache(profile: .defaultDog).imageSize)
    }

    /// EXTRAS_OUT=<dir> swift test --filter ExtraMotionTests writes QA sheets.
    func testWriteQASheets() throws {
        guard let dir = ProcessInfo.processInfo.environment["EXTRAS_OUT"] else { return }
        let ids = ProcessInfo.processInfo.environment["EXTRAS_IDS"]?.split(separator: ",").map(String.init)
        let dogs = DogProfile.presets.filter { ids?.contains($0.id) ?? true }
        var rows: [[[UInt8]]] = []
        for d in dogs {
            rows.append(DogExtras.rgba(d.profile, .hungry) + DogExtras.rgba(d.profile, .eat)
                        + [DogRenderer.frames(d.profile)[DogPose.walk.rawValue][0]])
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try write(board(rows, scale: 8, bg: (0xE6, 0xE6, 0xE6)), "\(dir)/sheet8x.png")
        try write(board(rows, scale: 1, bg: (0xEC, 0xEC, 0xEC)), "\(dir)/bar-light@1x.png")
        try write(board(rows, scale: 1, bg: (0x2A, 0x2A, 0x2A)), "\(dir)/bar-dark@1x.png")
        try write(board(rows, scale: 2, bg: (0x2A, 0x2A, 0x2A)), "\(dir)/bar-dark@2x.png")
        try write(board(rows, scale: 2, bg: (0xEC, 0xEC, 0xEC)), "\(dir)/bar-light@2x.png")
    }

    private func board(_ rows: [[[UInt8]]], scale s: Int, bg: (UInt8, UInt8, UInt8)) -> (px: [UInt8], width: Int) {
        let pad = s >= 4 ? 8 : 4, cols = rows.map(\.count).max() ?? 1
        let bw = pad + cols * (w * s + pad), bh = pad + rows.count * (h * s + pad)
        var out = [UInt8](repeating: 255, count: bw * bh * 4)
        for i in 0..<(bw * bh) { out[i * 4] = bg.0; out[i * 4 + 1] = bg.1; out[i * 4 + 2] = bg.2 }
        for (r, frames) in rows.enumerated() {
            for (c, f) in frames.enumerated() {
                let ox = pad + c * (w * s + pad), oy = pad + r * (h * s + pad)
                for y in 0..<(h * s) { for x in 0..<(w * s) {
                    let src = ((y / s) * w + x / s) * 4, dst = ((oy + y) * bw + ox + x) * 4
                    if f[src + 3] != 0 { for k in 0..<3 { out[dst + k] = f[src + k] } }
                    else if s >= 4 && ((x / s + y / s) % 2 == 0) { for k in 0..<3 { out[dst + k] = bg.0 &- 14 } }
                } }
            }
        }
        return (out, bw)
    }

    private func write(_ b: (px: [UInt8], width: Int), _ path: String) throws {
        let cg = DogRenderer.cgImage(b.px, width: b.width, height: b.px.count / 4 / b.width)
        try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
