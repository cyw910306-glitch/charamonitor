import Foundation

// MARK: - Dog

public enum DogPose: Int, CaseIterable, Codable {
    case lying, slowWalk, walk, fastWalk, run, sprint, exhausted

    /// CPU usage (0...1) to pose. Lower bounds: 0, 5, 15, 30, 45, 65, 85 %.
    public static func forCPU(_ usage: Double) -> DogPose {
        let p = usage * 100
        switch p {
        case ..<5: return .lying
        case ..<15: return .slowWalk
        case ..<30: return .walk
        case ..<45: return .fastWalk
        case ..<65: return .run
        case ..<85: return .sprint
        default: return .exhausted
        }
    }

    public var label: String {
        switch self {
        case .lying: return L("쿨쿨 자는 중")
        case .slowWalk: return L("어슬렁어슬렁")
        case .walk: return L("산책 중")
        case .fastWalk: return L("총총총")
        case .run: return L("달리는 중")
        case .sprint: return L("전속력 질주!")
        case .exhausted: return L("헉헉 땀 뻘뻘")
        }
    }
}

/// Who lives in the menu bar: the customizable dog, a character made from the user's own pictures (which one:
/// AppSettings.customCharacterID), a cat breed (AppSettings.catID) or an original character or local pack
/// (AppSettings.originalID). Raw values are saved; never rename one. A value this build no longer has (a
/// removed character) reads as nil and loads as the dog.
/// Not named `Character`, which would shadow Swift.Character in this module.
public enum SpriteCharacter: String, Codable, CaseIterable {
    case dog, custom, cat, original
}

public enum EarStyle: String, Codable, CaseIterable { case pointy, floppy, folded, long }
public enum TailStyle: String, Codable, CaseIterable { case curly, straight, short, fluffy }
public enum SnoutStyle: String, Codable, CaseIterable { case short, medium, long }
public enum BodyBuild: String, Codable, CaseIterable { case small, medium, large, long }  // long = dachshund-like
public enum CoatPattern: String, Codable, CaseIterable { case solid, mask, saddle, whiteChest, socks, spots }

public struct RGBColor: Codable, Equatable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// "#C8913A" or "C8913A". Invalid input gives mid gray.
    public init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self.init(r: 128, g: 128, b: 128); return }
        self.init(r: UInt8(v >> 16 & 0xFF), g: UInt8(v >> 8 & 0xFF), b: UInt8(v & 0xFF))
    }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
}

public struct DogProfile: Codable, Equatable {
    public var name: String
    public var ears: EarStyle
    public var tail: TailStyle
    public var snout: SnoutStyle
    public var build: BodyBuild
    public var fluffy: Bool
    public var pattern: CoatPattern
    public var baseColor: RGBColor       // main coat
    public var secondaryColor: RGBColor  // pattern color (mask/saddle/chest/socks/spots)
    public var noseColor: RGBColor
}
