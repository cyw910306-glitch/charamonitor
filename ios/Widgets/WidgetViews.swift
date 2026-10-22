import CharaCore
import SwiftUI
import WidgetKit

/// What a widget shows at one moment: who, which still frame, the battery and one line in the character's 말투.
struct CharaEntry: TimelineEntry {
    let date: Date
    var art: CharaArt
    let pose: DogPose
    var extra: ExtraMotion?
    let battery: SharedState.Battery?
    let line: String

    /// The still frame by state: a fresh tap's reaction, else charging eats, a low battery looks for food, night
    /// sleeps, any other time stands.
    static func make(art: CharaArt, battery: SharedState.Battery?, date: Date, persona style: PersonaStyle = .auto,
                     reaction: Int? = nil) -> CharaEntry {
        let persona = art.persona(chosen: style)
        func say(_ banmal: String, _ polite: String, flair: Bool = false) -> String {
            persona.dress(persona.style.banmal ? banmal : polite, flair: flair, day: date)
        }
        if let reaction {
            let r = reactions[reaction % reactions.count]
            let own = r.extra.map { art.lines($0) } ?? []
            let line = own.isEmpty ? say(L(r.banmal), L(r.polite)) : own[reaction / reactions.count % own.count]
            return CharaEntry(date: date, art: art, pose: r.pose, extra: r.extra, battery: battery, line: line)
        }
        if let b = battery, b.charging {
            return CharaEntry(date: date, art: art, pose: .slowWalk, extra: .eat, battery: b,
                              line: say(L("충전하면서 냠냠 먹는 중이야"), L("충전하면서 냠냠 먹는 중이에요")))
        }
        if let b = battery, b.percent <= 20 {
            return CharaEntry(date: date, art: art, pose: .exhausted, extra: .hungry, battery: b,
                              line: say(L("배고파… \(b.percent)%야, 충전해 줘!"), L("배고파요. \(b.percent)%예요, 충전해 주세요!")))
        }
        let hour = Calendar.current.component(.hour, from: date)
        if hour >= 22 || hour < 7 {
            return CharaEntry(date: date, art: art, pose: .lying, battery: battery, line: say(L("쿨쿨… 잘 자"), L("쿨쿨… 편히 주무세요")))
        }
        let idle = [(L("오늘도 옆에 있을게"), L("오늘도 옆에 있을게요")),
                    (L("산책 갈 때 불러 줘"), L("산책 갈 때 불러 주세요")),
                    (L("여기서 기다리고 있어"), L("여기서 기다리고 있어요")),
                    (L("천천히 해도 괜찮아"), L("천천히 하셔도 괜찮아요"))]
        let pick = idle[Int(date.timeIntervalSince1970 / 1800) % idle.count]   // a new one every timeline refresh
        return CharaEntry(date: date, art: art, pose: .walk, battery: battery, line: say(pick.0, pick.1, flair: true))
    }

    /// What one tap on the medium widget's character does, in turn. A pack's own "say" lines for the special
    /// move win over ours.
    static let reactions: [(pose: DogPose, extra: ExtraMotion?, banmal: String.LocalizationValue, polite: String.LocalizationValue)] = [
        (.run, .special, "간지러워! 헤헤", "간지러워요! 헤헤"),
        (.sprint, nil, "신난다! 한 번 더!", "신나요! 한 번 더요!"),
        (.fastWalk, nil, "나 불렀어?", "부르셨어요?"),
        (.lying, nil, "쓰담쓰담 좋아…", "쓰다듬어 주셔서 좋아요"),
    ]
}

/// One widget family's face. The family and background come in as values (not read from the environment) so the
/// render check can draw every one.
struct CharaWidgetFace: View {
    let entry: CharaEntry
    let family: WidgetFamily
    /// False in StandBy and wherever the system takes the background away: the character then fills the widget.
    var background = true

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: background ? AnyView(small) : AnyView(standBy)
        }
    }

    /// The system families' background: a soft wash that follows light and dark. Accessories keep the system's.
    @ViewBuilder static func backdrop(_ family: WidgetFamily) -> some View {
        switch family {
        case .systemSmall, .systemMedium:
            LinearGradient(colors: [Color(.systemBackground), Color(.secondarySystemBackground)], startPoint: .top, endPoint: .bottom)
        default:
            Color.clear
        }
    }

    private var frame: CharaFrame { CharaFrame(art: entry.art, pose: entry.pose, extra: entry.extra, scale: 6) }

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(verbatim: entry.art.displayName).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                BatteryLabel(battery: entry.battery)
            }
            frame.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(verbatim: entry.line).font(.caption2).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
        }
    }

    /// StandBy shows the widget large on black, often at night in red: just the character and the battery, big.
    private var standBy: some View {
        VStack(spacing: 4) {
            frame.frame(maxWidth: .infinity, maxHeight: .infinity)
            if entry.battery != nil {
                BatteryLabel(battery: entry.battery, font: .title2.weight(.bold), strong: true)
            } else {
                Text(verbatim: entry.art.displayName).font(.title3.weight(.bold)).lineLimit(1)
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            Button(intent: ReactIntent()) {
                frame.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 150)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(verbatim: entry.art.displayName).font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                    BatteryLabel(battery: entry.battery)
                }
                Text(verbatim: entry.line).font(.subheadline).lineLimit(3).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Text(verbatim: L("캐릭터를 눌러 보세요")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var circular: some View {
        if let b = entry.battery {
            Gauge(value: Double(b.percent), in: 0...100) {
                Text(verbatim: "\(b.percent)%")
            } currentValueLabel: {
                frame
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                frame.padding(6)
            }
        }
    }

    private var rectangular: some View {
        HStack(spacing: 6) {
            frame.frame(width: 54)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(verbatim: entry.art.displayName).font(.headline).lineLimit(1)
                    BatteryLabel(battery: entry.battery, font: .caption.weight(.semibold))
                }
                Text(verbatim: entry.line).font(.caption).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        if let b = entry.battery {
            let name = entry.art.displayName   // the number first: a long name is cut, not the battery
            return Text(verbatim: b.charging ? L("충전 중 \(b.percent)% · \(name)") : L("배터리 \(b.percent)% · \(name)"))
        }
        return Text(verbatim: entry.line)
    }
}

/// "82%", with a bolt while charging and red when low. Nothing when the battery is unknown.
struct BatteryLabel: View {
    let battery: SharedState.Battery?
    var font: Font = .caption.weight(.semibold)
    /// Full strength, where secondary would be too dim (StandBy at night is red on black).
    var strong = false

    var body: some View {
        if let b = battery {
            HStack(spacing: 1) {
                if b.charging { Image(systemName: "bolt.fill") }
                Text(verbatim: "\(b.percent)%")
            }
            .font(font)
            .monospacedDigit()
            .foregroundStyle(b.percent <= 20 && !b.charging ? AnyShapeStyle(.red) : strong ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .widgetAccentable()
        }
    }
}
