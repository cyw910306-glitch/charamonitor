import Foundation

public struct DogPreset: Identifiable {
    public let id: String
    public let name: String   // Korean breed name
    public let profile: DogProfile
}

extension DogProfile {
    /// 젤리: the owner's maltipoo. Apricot teddy cut, puffy floppy ears, white chest.
    public static let defaultDog = DogProfile(
        name: L("젤리"), ears: .floppy, tail: .fluffy, snout: .short, build: .small, fluffy: true,
        pattern: .whiteChest,
        baseColor: RGBColor(hex: "#D8B290"), secondaryColor: RGBColor(hex: "#F5EDE6"), noseColor: RGBColor(hex: "#3B2C26"))

    public static let presets: [DogPreset] = [
        DogPreset(id: "jelly", name: L("젤리"), profile: .defaultDog),
        breed("golden", L("골든 리트리버"), .floppy, .fluffy, .medium, .large, fluffy: true, .solid, "#D69A52", "#EFD3A0", nose: "#2B1E18"),
        breed("shiba", L("시바견"), .pointy, .curly, .medium, .small, .whiteChest, "#D8843F", "#F6E6CC"),
        breed("husky", L("시베리안 허스키"), .pointy, .fluffy, .medium, .large, .mask, "#5F6873", "#F4F4F2", nose: "#1C1C1E"),
        breed("labrador", L("래브라도 리트리버"), .floppy, .straight, .medium, .large, .solid, "#E8C98F", "#F3E2BD", nose: "#3A2A22"),
        breed("poodle", L("푸들"), .floppy, .fluffy, .long, .large, fluffy: true, .solid, "#2A2A2E", "#4A4A50", nose: "#111113"),
        breed("toy-poodle", L("토이 푸들"), .floppy, .fluffy, .medium, .small, fluffy: true, .solid, "#A9582B", "#C9804E", nose: "#2A1A14"),
        breed("maltipoo", L("말티푸"), .floppy, .fluffy, .short, .small, fluffy: true, .solid, "#F1DEC4", "#FBF3E8", nose: "#2B2220"),
        breed("beagle", L("비글"), .long, .straight, .medium, .medium, .saddle, "#C98642", "#2B2522", nose: "#1E1A18"),
        breed("dachshund", L("닥스훈트"), .long, .straight, .long, .long, .solid, "#A4532A", "#7A3A1C", nose: "#1E1614"),
        breed("bulldog", L("불독"), .folded, .short, .short, .small, .whiteChest, "#C98D5A", "#F6F1EA", nose: "#231C1A"),
        breed("border-collie", L("보더콜리"), .folded, .fluffy, .medium, .medium, fluffy: true, .whiteChest, "#232327", "#F4F4F1", nose: "#141416"),
        breed("chihuahua", L("치와와"), .pointy, .curly, .short, .small, .solid, "#D9A15F", "#F0D2A4", nose: "#2A1E1A"),
        breed("pomeranian", L("포메라니안"), .pointy, .fluffy, .short, .small, fluffy: true, .solid, "#EC9A3E", "#F7C98A", nose: "#221A18"),
        breed("corgi", L("웰시코기"), .pointy, .short, .medium, .long, .whiteChest, "#DA8A3C", "#FAF6F0", nose: "#1E1A18"),
        breed("shepherd", L("저먼 셰퍼드"), .pointy, .straight, .long, .large, .saddle, "#C98A4B", "#27221F", nose: "#161413"),
        breed("doberman", L("도베르만"), .pointy, .short, .long, .large, .mask, "#211E1E", "#B3652F", nose: "#141212"),
        breed("jack-russell", L("잭 러셀 테리어"), .folded, .short, .medium, .small, .spots, "#F6F3EE", "#B7722F", nose: "#1E1A18"),
        breed("maltese", L("말티즈"), .long, .fluffy, .short, .small, fluffy: true, .solid, "#FAF8F3", "#FFFFFF", nose: "#1C1A1A"),
        breed("bichon", L("비숑 프리제"), .floppy, .fluffy, .short, .small, fluffy: true, .solid, "#FFFFFF", "#F4F1EA", nose: "#161414"),
        breed("samoyed", L("사모예드"), .pointy, .fluffy, .medium, .large, fluffy: true, .solid, "#FBFAF6", "#FFFFFF", nose: "#1A1818"),
        breed("jindo", L("진돗개"), .pointy, .curly, .medium, .medium, .solid, "#F0E6D2", "#FBF7EE", nose: "#2A2220"),
        breed("french-bulldog", L("프렌치 불독"), .pointy, .short, .short, .small, .mask, "#D6B386", "#2E2723", nose: "#1A1614"),
    ]

    private static func breed(_ id: String, _ name: String, _ ears: EarStyle, _ tail: TailStyle, _ snout: SnoutStyle,
                              _ build: BodyBuild, fluffy: Bool = false, _ pattern: CoatPattern,
                              _ base: String, _ secondary: String, nose: String = "#1E1A18") -> DogPreset {
        DogPreset(id: id, name: name, profile: DogProfile(
            name: name, ears: ears, tail: tail, snout: snout, build: build, fluffy: fluffy, pattern: pattern,
            baseColor: RGBColor(hex: base), secondaryColor: RGBColor(hex: secondary), noseColor: RGBColor(hex: nose)))
    }
}
