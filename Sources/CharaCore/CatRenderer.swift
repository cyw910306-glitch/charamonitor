import Foundation

/// Paints every pose and extra motion of a cat and centres it on the shared 34x20 canvas.
public enum CatRenderer {
    private static let margin = 12

    /// RGBA frames on the shared canvas, poses in DogPose order (drop-in for DogSpriteCache's `custom:`).
    public static func frames(_ profile: CatProfile) -> [[[UInt8]]] { render(profile).poses }

    /// RGBA frames of one extra motion, or nil when cats have none (special).
    public static func frames(_ profile: CatProfile, extra motion: ExtraMotion) -> [[UInt8]]? { render(profile).extras[motion] }

    public static func render(_ profile: CatProfile) -> (poses: [[[UInt8]]], extras: [ExtraMotion: [[UInt8]]]) {
        let w = SpriteCanvas.width
        let poses = DogPose.allCases.map { CatRig.rigs($0) }
        let extras = ExtraMotion.allCases.compactMap { m in CatRig.rigs(m).map { (m, $0) } }
        let g = grids(profile, poses + extras.map(\.1))
        // One offset for everything, so switching poses or starting to eat never shifts the cat sideways.
        let span = union(g)
        let x0 = span.map { $0.minX - (w - ($0.maxX - $0.minX + 1)) / 2 } ?? margin
        let palette = CatPalette(profile)
        let rgba = g.map { $0.map { $0.rgba(palette, x0: x0, outWidth: w) } }
        var byMotion: [ExtraMotion: [[UInt8]]] = [:]
        for (i, e) in extras.enumerated() { byMotion[e.0] = rgba[poses.count + i] }
        return (Array(rgba.prefix(poses.count)), byMotion)
    }

    public static func grids(_ profile: CatProfile, _ rigs: [[CatRig]]) -> [[CatGrid]] {
        let painter = CatPainter(profile)
        return rigs.map { list in
            list.map { rig in
                var g = CatGrid(width: SpriteCanvas.width + margin * 2, height: SpriteCanvas.height)
                painter.paint(rig, into: &g, originX: margin + 8)
                return g
            }
        }
    }

    public static func union(_ grids: [[CatGrid]]) -> (minX: Int, maxX: Int)? {
        let boxes = grids.joined().compactMap(\.bounds)
        guard let lo = boxes.map(\.minX).min(), let hi = boxes.map(\.maxX).max() else { return nil }
        return (lo, hi)
    }
}
