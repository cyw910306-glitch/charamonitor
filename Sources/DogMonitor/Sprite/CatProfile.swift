import Foundation

enum CatEars: String, Codable, CaseIterable { case pointy, folded }
enum CatTail: String, Codable, CaseIterable { case long, short, fluffy }
/// tabby: `secondaryColor` stripes, `accentColor` cream belly. calico: white base, orange `secondaryColor` and
/// black `accentColor` patches. tuxedo / bicolor: `secondaryColor` white parts. pointed: `secondaryColor` points.
enum CatCoat: String, Codable, CaseIterable { case solid, tabby, calico, tuxedo, pointed, bicolor }
enum CatBuild: String, Codable, CaseIterable { case small, medium, large }
/// Breed marks that tell look-alike cats apart at 1x: a flat Persian face, round British cheeks and a deeper body,
/// the Russian Blue's silver back line and longer legs, Norwegian lynx tufts and a light tail tip.
enum CatTrait: String, Codable { case flatFace, chubby, silverBack, lynxTufts }

struct CatProfile: Codable, Equatable {
    var name: String
    var ears: CatEars
    var tail: CatTail
    var coat: CatCoat
    var build: CatBuild
    var fluffy: Bool
    var shortLegs: Bool        // 먼치킨
    var baseColor: RGBColor
    var secondaryColor: RGBColor
    var accentColor: RGBColor
    var eyeColor: RGBColor
    var noseColor: RGBColor
    /// Optional so profiles saved before 2.0 still decode.
    var traits: [CatTrait]? = nil

    func has(_ t: CatTrait) -> Bool { traits?.contains(t) ?? false }
}

struct CatPreset: Identifiable {
    let id: String
    let name: String
    let profile: CatProfile
}

extension CatProfile {
    static let defaultCat = presets[0].profile

    static let presets: [CatPreset] = [
        cat("korean-shorthair", L("코리안 숏헤어(고등어)"), .tabby, "#9C968C", "#4E4A45", "#E9E4DA", eye: "#B9C94A"),
        cat("cheese-tabby", L("치즈 태비"), .tabby, "#EBA75C", "#C2672A", "#FBE8CC", eye: "#E0A52E"),
        cat("calico", L("삼색이"), .calico, "#F8F4EC", "#E39140", "#2E2A2A", eye: "#D9B23A"),
        cat("tuxedo", L("턱시도"), .tuxedo, "#26252B", "#F6F5F1", "#F6F5F1", eye: "#A8D255"),
        cat("russian-blue", L("러시안 블루"), .solid, "#8C9BAD", "#8C9BAD", "#B4C0CE", eye: "#5FCB6C", build: .small, nose: "#5C6675",
            traits: [.silverBack]),
        cat("persian", L("페르시안"), .solid, "#F4ECE2", "#F4ECE2", "#FFFFFF", eye: "#E38B35", tail: .fluffy, build: .large, fluffy: true,
            traits: [.flatFace]),
        cat("siamese", L("샴"), .pointed, "#F2E6D0", "#5B4335", "#F2E6D0", eye: "#4F9BEA", build: .small, nose: "#4A362B"),
        cat("munchkin", L("먼치킨"), .bicolor, "#DDB083", "#FAF6EF", "#FAF6EF", eye: "#C9A238", build: .small, shortLegs: true),
        cat("scottish-fold", L("스코티시 폴드"), .bicolor, "#8E939B", "#F4F3F0", "#F4F3F0", eye: "#E39A3B", ears: .folded),
        cat("norwegian-forest", L("노르웨이 숲"), .tabby, "#8C6D4F", "#4A3828", "#F1E6D6", eye: "#C8B23C", tail: .fluffy, build: .large, fluffy: true,
            traits: [.lynxTufts]),
        cat("british-shorthair", L("브리티시 숏헤어"), .solid, "#7C8696", "#7C8696", "#A0A9B8", eye: "#E8973A", tail: .short, build: .large, nose: "#5A606A",
            traits: [.chubby]),
        cat("black-cat", L("검은 고양이"), .solid, "#232227", "#232227", "#3A3940", eye: "#F2CF45", nose: "#3A3940"),
    ]

    private static func cat(_ id: String, _ name: String, _ coat: CatCoat, _ base: String, _ sec: String, _ acc: String,
                            eye: String, ears: CatEars = .pointy, tail: CatTail = .long, build: CatBuild = .medium,
                            fluffy: Bool = false, shortLegs: Bool = false, nose: String = "#E88A9A",
                            traits: [CatTrait]? = nil) -> CatPreset {
        CatPreset(id: id, name: name, profile: CatProfile(
            name: name, ears: ears, tail: tail, coat: coat, build: build, fluffy: fluffy, shortLegs: shortLegs,
            baseColor: RGBColor(hex: base), secondaryColor: RGBColor(hex: sec), accentColor: RGBColor(hex: acc),
            eyeColor: RGBColor(hex: eye), noseColor: RGBColor(hex: nose), traits: traits))
    }
}
