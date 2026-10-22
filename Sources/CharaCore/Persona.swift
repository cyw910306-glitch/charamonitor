import Foundation

/// How the character talks. `auto` = the preset of whoever is in the menu bar (Persona.preset). `cry`: the
/// character's own sound first, the words in brackets ("멍! (배터리가 10%야)"), put on in code (Persona.dress).
public enum PersonaStyle: String, CaseIterable, Codable {
    case auto, friendly, calm, shy, proud, bright, polite, cry

    public var label: String {
        switch self {
        case .auto: return L("캐릭터 기본")
        case .friendly: return L("다정한 반말")
        case .calm: return L("담백한 반말")
        case .shy: return L("수줍은 반말")
        case .proud: return L("도도한 반말")
        case .bright: return L("씩씩한 반말")
        case .polite: return L("존댓말")
        case .cry: return L("울음소리 말투")
        }
    }

    /// The model is told this; the post-processing (Banmal.fix) backs it up for every style but polite.
    public var rule: String {
        switch self {
        case .auto, .friendly, .cry: return "똑똑하고 다정한 친구처럼 담백한 반말로 말해. 감탄사는 거의 쓰지 마."
        case .calm: return "감정 표현 없이 담백한 반말로 말해. 감탄사, 이모지, 느낌표는 쓰지 마."
        case .shy: return "조금 수줍은 반말로 말해. 말끝을 가끔 흐려도 돼."
        case .proud: return "조금 도도하지만 결국 챙겨 주는 반말로 말해."
        case .bright: return "기운차고 씩씩한 반말로 말해."
        case .polite: return "부드러운 해요체 존댓말로만 말해. 반말 어미(~야, ~어, ~해)는 쓰지 마."
        }
    }

    public var banmal: Bool { self != .polite }

    /// Interjections Persona.flavor may put before a free template line (none for 담백 and 존댓말).
    public var leads: [String] {
        switch self {
        case .auto, .friendly: return [L("있지, "), L("저기, ")]
        case .shy: return [L("저, 저기… "), L("그, 그게… ")]
        case .proud: return [L("흥, "), L("뭐, ")]
        case .bright: return [L("좋아! "), L("자! ")]
        case .calm, .polite, .cry: return []
        }
    }

    /// What Persona.flavor may put after a free template line. No speech level of their own: pet lines are 존댓말.
    public var tails: [String] {
        switch self {
        case .auto, .friendly: return [L(" 헤헤"), L(" 히히")]
        case .shy: return [L(" (부끄)"), L(" …헤헤")]
        case .proud: return [L(" 에헴"), L(" 흥")]
        case .bright: return [L(" 파이팅!"), L(" 아자!")]
        case .calm, .polite, .cry: return []
        }
    }

    /// One sample answer in this voice (a small model follows an example far better than a description). A general
    /// question on purpose: a Mac one made the model talk about the Mac whatever was asked.
    public var example: String {
        switch self {
        case .auto, .friendly, .cry: return "식물학으로는 과일이야. 요리할 때는 채소처럼 써."
        case .calm: return "식물학으로는 과일이야. 요리에서는 채소로 다뤄."
        case .shy: return "음, 식물학으로는 과일이야. 요리할 때는 채소처럼 쓰지만."
        case .proud: return "식물학으로는 과일이야. 요리할 땐 채소 취급이지만, 그 정도는 알아 둬."
        case .bright: return "식물학으로는 과일이야! 요리할 때는 채소처럼 써."
        case .polite: return "식물학으로는 과일이에요. 요리할 때는 채소처럼 써요."
        }
    }
}

public struct Persona: Equatable {
    public var name: String
    public var style: PersonaStyle   // never .auto
    /// The 울음소리 style's sounds (Persona.cries); empty = Persona.neutralCries.
    public var cries: [String] = []

    public init(name: String, style: PersonaStyle, cries: [String] = []) {
        self.name = name
        self.style = style
        self.cries = cries
    }

    /// Preset per character: originals by id, the rest by kind. Unknown ids get the friendly default.
    public static func preset(character: SpriteCharacter, id: String?) -> PersonaStyle {
        switch character {
        case .dog, .custom: return .friendly
        case .cat: return .proud
        case .original:
            switch id {
            case "original-tan-cat": return .proud
            default: return .friendly
            }
        }
    }

    /// `own`: the character's own 말투 (a pack's or a custom character's), used before the kind preset; `cries` its sounds.
    public static func resolve(name: String, character: SpriteCharacter, id: String?, chosen: PersonaStyle,
                        own: PersonaStyle? = nil, cries ownCries: [String] = []) -> Persona {
        let style = chosen != .auto ? chosen : own.flatMap { $0 == .auto ? nil : $0 } ?? preset(character: character, id: id)
        return Persona(name: name, style: style, cries: ownCries.isEmpty ? cries(character: character, id: id) : ownCries)
    }

    /// Sounds per kind for the 울음소리 style. Our own animal sounds only.
    public static func cries(character: SpriteCharacter, id: String?) -> [String] {
        switch character {
        case .dog: return [L("멍!"), L("왕왕"), L("끄응…")]
        case .cat: return catCries
        case .original: return id == "original-tan-cat" ? catCries : neutralCries
        case .custom: return neutralCries
        }
    }
    public static var catCries: [String] { [L("냐앙"), L("먀?"), L("냥냥")] }
    public static var neutralCries: [String] { [L("음!"), L("오!"), L("흠흠")] }

    /// A character's own sounds as read from a file (pack.json, character.json): at most 6, each one line of 1 to 8
    /// characters with control characters taken out. Anything else is dropped.
    public static func cleanCries(_ raw: [String]?) -> [String] {
        Array((raw ?? []).map { oneLine($0, max: 99) }.filter { (1...8).contains($0.count) }.prefix(6))
    }

    /// `text` as one line: control characters (newlines too) become spaces, runs of spaces one, cut at `max`.
    public static func oneLine(_ text: String, max: Int) -> String {
        let s = String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        return String(s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(max)).trimmingCharacters(in: .whitespaces)
    }

    /// A template or answer as this persona says it: the 울음소리 style puts one of its sounds first and the line, untouched,
    /// in brackets (so every number and name stays exact); the others get Persona.flavor when `flair`.
    /// The sound is picked by the text and the day like flavor, so BubbleGate still sees a repeat as the same words.
    public func dress(_ text: String, flair: Bool = true, day: Date = Date()) -> String {
        guard style == .cry else { return flair ? flavor(text, day: day) : text }
        // A long answer reads badly inside brackets: the sound on its own first line, the answer under it as is.
        return text.count > Self.longDress || text.contains("\n") ? "\(sound(text, day))\n\(text)" : exclaim(text, day: day)
    }

    /// A reaction card's line in every style: one of the character's sounds, then what it means in brackets
    /// ("흠! (벌써 2/4! 잘 가고 있어.)"). The sound is picked like dress's.
    public func exclaim(_ text: String, day: Date = Date()) -> String { "\(sound(text, day)) (\(text))" }

    private func sound(_ text: String, _ day: Date) -> String {
        let sounds = cries.isEmpty ? Self.neutralCries : cries
        return sounds[Int(Self.dayHash(text, day) % UInt32(sounds.count))]
    }

    /// Longer than this (or more than one line), the 울음소리 style puts the sound above the text, not the text in brackets.
    public static let longDress = 60

    /// FNV-1a 32 of `text` and `day`'s date: the same all day, different tomorrow.
    public static func dayHash(_ text: String, _ day: Date) -> UInt32 {
        let d = Calendar.current.dateComponents([.year, .month, .day], from: day)
        var h: UInt32 = 2_166_136_261
        for b in "\(text)\(d.year ?? 0)-\(d.month ?? 0)-\(d.day ?? 0)".utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h
    }

    /// One time in four (by the text and the day, so the same line reads the same all day) adds one of the style's
    /// leads or tails to a free template line. Not for lines that must read cleanly (battery, heat, calendar).
    public func flavor(_ text: String, day: Date = Date()) -> String {
        let h = Self.dayHash(text, day)
        guard h % 4 == 0 else { return text }
        let lead = (h >> 2) & 1 == 0
        let list = lead ? style.leads : style.tails
        guard !list.isEmpty else { return text }
        let item = list[Int((h >> 3) % UInt32(list.count))]
        return lead ? item + text : text + item
    }
}
