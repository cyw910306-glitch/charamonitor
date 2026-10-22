import CharaCore
import SwiftUI
import WidgetKit

/// The Live Activity's pieces, as plain views of its attributes and state so the render check can draw them.
/// `stale`: the run's end has passed and the app has not ended it yet (it was away), so it shows done, not 00:00.
struct CharaLiveFace {
    let attributes: CharaActivityAttributes
    let state: CharaActivityAttributes.ContentState
    let stale: Bool
    let art: CharaArt

    init(_ attributes: CharaActivityAttributes, _ state: CharaActivityAttributes.ContentState, stale: Bool = false) {
        self.attributes = attributes
        self.state = state
        self.stale = stale
        art = Self.art(attributes.characterID, keys: CharaArt.keys(Self.pose(state, stale: stale), extra: Self.extra(state, stale: stale)))
    }

    /// Done: resting. Else the pose the app picked.
    static func pose(_ state: CharaActivityAttributes.ContentState, stale: Bool) -> DogPose {
        stale ? .lying : DogPose(rawValue: state.pose) ?? .walk
    }

    static func extra(_ state: CharaActivityAttributes.ContentState, stale: Bool) -> ExtraMotion? {
        stale ? nil : state.extra.flatMap(ExtraMotion.init(rawValue:))
    }

    /// The last face's character: the banner and the Dynamic Island draw the same update, so a pack is read once.
    private static var last: (key: String, art: CharaArt)?

    private static func art(_ id: String, keys: Set<String>) -> CharaArt {
        let key = id + " " + keys.sorted().joined(separator: " ")
        if let last, last.key == key { return last.art }
        let art = Shared.art(id, keys: keys)
        last = (key, art)
        return art
    }

    var title: String {
        if stale { return L("집중 끝!") }
        return attributes.title.isEmpty ? L("집중 시간") : attributes.title
    }

    /// startDate...endDate, never backwards (a range that is would crash).
    var span: ClosedRange<Date> { min(attributes.startDate, attributes.endDate)...attributes.endDate }

    /// Small on purpose: ActivityKit drops images larger than they are shown. 34 x 20 points at 3x.
    func character(width: CGFloat) -> some View {
        CharaFrame(art: art, pose: Self.pose(state, stale: stale), extra: Self.extra(state, stale: stale), scale: 3)
            .frame(width: width, height: width * 20 / 34)
    }

    @ViewBuilder var timer: some View {
        if stale {
            Image(systemName: "checkmark.circle.fill").accessibilityLabel(Text("집중 끝!"))
        } else {
            Text(timerInterval: span, countsDown: true).monospacedDigit()
        }
    }

    @ViewBuilder var progress: some View {
        if stale {
            ProgressView(value: 1)
        } else {
            ProgressView(timerInterval: span, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
        }
    }

    /// The Lock Screen banner.
    var banner: some View {
        HStack(spacing: 12) {
            character(width: 68)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(verbatim: title).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    timer.font(.title3.weight(.semibold)).multilineTextAlignment(.trailing).frame(maxWidth: 96, alignment: .trailing)
                }
                progress.tint(.orange)
                Text(verbatim: art.displayName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    var compactTrailing: some View {
        timer.font(.caption.weight(.semibold)).multilineTextAlignment(.trailing).frame(width: 44).foregroundStyle(.orange)
    }
}
