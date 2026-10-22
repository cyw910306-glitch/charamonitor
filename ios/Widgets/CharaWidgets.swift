import ActivityKit
import CharaCore
import SwiftUI
import WidgetKit

@main
struct CharaWidgets: WidgetBundle {
    var body: some Widget {
        CharaWidget()
        CharaLiveActivity()
    }
}

/// The chosen character, still, by the battery and the hour; a fresh entry every 30 minutes and whenever the app
/// or a tap reloads. A tap's reaction shows for a short while, then the normal face comes back.
struct CharaProvider: TimelineProvider {
    static let refresh: TimeInterval = 30 * 60, reactionShows: TimeInterval = 12

    func placeholder(in context: Context) -> CharaEntry {
        CharaEntry.make(art: Shared.art(CharaArt.defaultID), battery: SharedState.Battery(percent: 80, charging: false), date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (CharaEntry) -> Void) {
        completion(entries(now: .now)[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CharaEntry>) -> Void) {
        let now = Date.now
        completion(Timeline(entries: entries(now: now), policy: .after(now.addingTimeInterval(Self.refresh))))
    }

    /// A pack is read twice, small: its name and voice first (walk only), then just the frames the entries show
    /// (the widget has about 30 MB; a whole HD pack can be more).
    private func entries(now: Date) -> [CharaEntry] {
        let id = SharedState.widgetCharacterID, battery = SharedState.battery, persona = SharedState.persona
        let art = Shared.art(id, keys: [])
        var list = [CharaEntry.make(art: art, battery: battery, date: now, persona: persona)]
        if let r = SharedState.reaction, now.timeIntervalSince(r.at) < Self.reactionShows {
            let back = r.at.addingTimeInterval(Self.reactionShows)
            list = [CharaEntry.make(art: art, battery: battery, date: now, persona: persona, reaction: r.index),
                    CharaEntry.make(art: art, battery: battery, date: back, persona: persona)]
        }
        guard CharaArt.builtIn(art.id) == nil else { return list }
        let shown = Shared.art(id, keys: list.reduce(into: []) { $0.formUnion(CharaArt.keys($1.pose, extra: $1.extra)) })
        return list.map { var e = $0; e.art = shown; return e }
    }
}

struct CharaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CharaWidget", provider: CharaProvider()) { entry in
            CharaWidgetView(entry: entry)
        }
        .configurationDisplayName("캐릭모니터")
        .description("내 캐릭터가 홈 화면에 살아요.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct CharaWidgetView: View {
    let entry: CharaEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.showsWidgetContainerBackground) private var background

    var body: some View {
        CharaWidgetFace(entry: entry, family: family, background: background)
            .containerBackground(for: .widget) { CharaWidgetFace.backdrop(family) }
    }
}

struct CharaLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CharaActivityAttributes.self) { context in
            CharaLiveFace(context.attributes, context.state, stale: context.isStale).banner
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let face = CharaLiveFace(context.attributes, context.state, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { face.character(width: 64).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.trailing) {
                    face.timer.font(.title3.weight(.semibold)).foregroundStyle(.orange).multilineTextAlignment(.trailing).frame(maxWidth: 90)
                }
                DynamicIslandExpandedRegion(.center) { Text(verbatim: face.title).font(.headline).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) { face.progress.tint(.orange).padding(.horizontal, 4) }
            } compactLeading: {
                face.character(width: 34)
            } compactTrailing: {
                face.compactTrailing
            } minimal: {
                face.character(width: 24)
            }
            .keylineTint(.orange)
        }
    }
}
