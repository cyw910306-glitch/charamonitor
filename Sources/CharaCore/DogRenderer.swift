import CoreGraphics
import Foundation

/// The shared art canvas every character is drawn on: 34 x 20 points (the Mac's DogSpriteCache.canvasWidth/Height).
public enum SpriteCanvas {
    public static let width = 34
    public static let height = 20
}

/// Seconds per frame, the same in every app that draws a character.
public enum FrameTiming {
    /// Seconds per frame of an extra moment: searching is slow, eating brisk, special moves quick.
    public static func extra(_ motion: ExtraMotion?) -> TimeInterval {
        switch motion {
        case .hungry: return 0.38
        case .eat: return 0.22
        case .special, nil: return 0.12
        }
    }

    /// Seconds per frame. Speeds up smoothly inside each pose's CPU band (DogPose.forCPU thresholds).
    public static func pose(_ pose: DogPose, cpu: Double) -> TimeInterval {
        let band: (lo: Double, hi: Double, slow: Double, fast: Double)
        switch pose {
        case .lying: return 0.6
        case .slowWalk: band = (0.05, 0.15, 0.22, 0.18)
        case .walk: band = (0.15, 0.30, 0.16, 0.12)
        case .fastWalk: band = (0.30, 0.45, 0.12, 0.095)
        case .run: band = (0.45, 0.65, 0.09, 0.07)
        case .sprint: band = (0.65, 0.85, 0.07, 0.055)
        case .exhausted: band = (0.85, 1.0, 0.055, 0.045)
        }
        let c = cpu.isFinite ? cpu : 0
        let t = min(1, max(0, (c - band.lo) / (band.hi - band.lo)))
        return max(0.04, band.slow + (band.fast - band.slow) * t)
    }
}

/// Paints every pose of a profile and centres the dog on the shared canvas.
public enum DogRenderer {
    private static let margin = 12

    /// RGBA bytes per frame, grouped by pose in DogPose order.
    public static func frames(_ profile: DogProfile) -> [[[UInt8]]] {
        let w = SpriteCanvas.width
        let grids = grids(profile)
        let span = union(grids)
        // One offset per profile, so switching poses never shifts the dog sideways.
        let x0 = span.map { $0.minX - (w - ($0.maxX - $0.minX + 1)) / 2 } ?? margin
        let palette = DogPalette(profile)
        return grids.map { $0.map { $0.rgba(palette, x0: x0, outWidth: w) } }
    }

    /// Every frame painted on a scratch canvas wide enough for any dog, grouped by pose in DogPose order.
    public static func grids(_ profile: DogProfile) -> [[ArtGrid]] {
        let painter = DogPainter(profile)
        return DogPose.allCases.map { pose in
            pose.rigs.map { rig in
                var g = ArtGrid(width: SpriteCanvas.width + margin * 2, height: SpriteCanvas.height)
                painter.paint(rig, into: &g, originX: margin + 8)
                return g
            }
        }
    }

    /// Horizontal extent of the dog over all frames, or nil when nothing was painted.
    public static func union(_ grids: [[ArtGrid]]) -> (minX: Int, maxX: Int)? {
        let boxes = grids.joined().compactMap(\.bounds)
        guard let lo = boxes.map(\.minX).min(), let hi = boxes.map(\.maxX).max() else { return nil }
        return (lo, hi)
    }

    /// `interpolate` off keeps pixel art blocky wherever it is drawn; illustrations (HD packs) turn it on.
    public static func cgImage(_ rgba: [UInt8], width: Int = SpriteCanvas.width, height: Int = SpriteCanvas.height,
                        interpolate: Bool = false) -> CGImage {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: interpolate, intent: .defaultIntent)!
    }

    public static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

