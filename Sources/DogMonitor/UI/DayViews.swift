#if !MAS
import AppKit
import SwiftUI

// 하루 기록 on screen: the 오늘 타임라인 window (3-minute blocks on an hour axis, the block's detail and its correction,
// the totals, the week), the dashboard line, the 설정 card, the menu bar ring, and their QA renders.

/// The small ring in the menu bar (메뉴바 집중 링): today's 집중 against 딴짓. A click opens the timeline.
final class DayRing: NSObject {
    static let shared = DayRing()
    private var item: NSStatusItem?

    func update() {
        guard !HotspotPanel.qaInert else { return }
        let c = DriftCenter.shared
        guard c.dayOn && c.dayRing else {
            if let i = item { NSStatusBar.system.removeStatusItem(i); item = nil }
            return
        }
        let i = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if item == nil {
            i.button?.target = self
            i.button?.action = #selector(open)
            i.button?.setAccessibilityLabel(L("하루 기록 타임라인 열기"))
            item = i
        }
        let s = DaySummary(c.day.day(Date()))
        i.button?.image = Self.image(focus: s.focus, drift: s.drift)
        i.button?.toolTip = L("오늘 집중 \(DayLog.duration(s.focus)) · 딴짓 \(DayLog.duration(s.drift))")
    }

    @objc private func open() { DayWindow.open() }

    /// 16 pt: a grey track, 집중 green from the top clockwise, 딴짓 orange after it.
    static func image(focus: Int, drift: Int, side: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            let c = CGPoint(x: r.midX, y: r.midY), radius = side / 2 - 2.5
            func arc(_ from: CGFloat, _ to: CGFloat, _ color: NSColor) {
                let p = NSBezierPath()
                p.appendArc(withCenter: c, radius: radius, startAngle: 90 - from * 360, endAngle: 90 - to * 360, clockwise: true)
                p.lineWidth = 3
                color.setStroke()
                p.stroke()
            }
            arc(0, 0.9999, NSColor.labelColor.withAlphaComponent(0.25))
            let total = CGFloat(focus + drift)
            if total > 0 {
                let f = CGFloat(focus) / total
                if f > 0 { arc(0, f, NSColor(srgbRed: 0.25, green: 0.68, blue: 0.42, alpha: 1)) }
                if f < 1 { arc(f, 1, NSColor(srgbRed: 0.94, green: 0.54, blue: 0.24, alpha: 1)) }
            }
            return true
        }
    }
}

/// The 오늘 타임라인 window, one at a time.
enum DayWindow {
    private static var window: NSWindow?

    static func open() {
        if let w = window {
            if !w.isVisible { w.contentView = NSHostingView(rootView: DayTimelineView()) }   // reopened: today, not the day it closed on
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = L("하루 기록")
        w.contentView = NSHostingView(rootView: DayTimelineView())
        w.isReleasedWhenClosed = false
        w.sharingType = .none   // tab titles stay out of screen shares
        window = w
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// One day: the summary, the blocks on an hour axis (20 to an hour), the block under the pointer or picked, the totals
/// per site or app, and the 7 days.
struct DayTimelineView: View {
    @ObservedObject var center: DriftCenter = .shared
    /// A QA render's clock; else the time of each render (the window is kept and reopened, so never the time it opened).
    var pinned: Date?
    var now: Date { pinned ?? Date() }
    /// QA renders: no scroll view, and a block already picked.
    var scrolls = true
    @State private var back = 0
    @State private var hover: Date?
    @State private var picked: Date?

    init(center: DriftCenter = .shared, now: Date? = nil, scrolls: Bool = true, picked: Date? = nil) {
        self.center = center
        self.pinned = now
        self.scrolls = scrolls
        _picked = State(initialValue: picked)
    }

    private var cal: Calendar { .current }
    private var date: Date { cal.date(byAdding: .day, value: -back, to: now) ?? now }

    var body: some View {
        if scrolls { ScrollView { content } } else { content }
    }

    private var content: some View {
        let blocks = center.day.day(date)
        let byStart = Dictionary(blocks.map { ($0.start, $0) }, uniquingKeysWith: { $1 })
        return VStack(alignment: .leading, spacing: 14) {
            header(blocks)
            grid(byStart)
            detail(byStart[hover ?? picked ?? .distantPast])
            Divider()
            totals(blocks)
            Divider()
            week
            Text(L("화면을 찍거나 녹화하지 않아요. 기록은 이 맥에만 \(center.dayKeep)일 동안 남아요."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 600, alignment: .leading)
    }

    private func header(_ blocks: [DayBlock]) -> some View {
        let s = DaySummary(blocks)
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMdEEEE")
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: back == 0 ? L("오늘") + " · " + f.string(from: date) : f.string(from: date))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Button { back = min(6, back + 1); picked = nil } label: { Image(systemName: "chevron.left") }
                    .disabled(back >= 6).accessibilityLabel(L("전날"))
                Button { back = max(0, back - 1); picked = nil } label: { Image(systemName: "chevron.right") }
                    .disabled(back == 0).accessibilityLabel(L("다음 날"))
            }
            Text(L("집중 \(DayLog.duration(s.focus)) · 딴짓 \(DayLog.duration(s.drift))"))
                .font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit()
            HStack(spacing: 10) {
                Text(L("중립 \(DayLog.duration(s.neutral)) · 자리 비움 \(DayLog.duration(s.away))"))
                if back == 0 {
                    let n = DaySummary(DayLog.session(blocks, now: now))
                    if n.total > 0 {
                        Text(L("지금 세션: 집중 \(DayLog.duration(n.focus)) · 딴짓 \(DayLog.duration(n.drift))"))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func hours(_ byStart: [Date: DayBlock]) -> [Int] {
        let hs = byStart.keys.map { cal.component(.hour, from: $0) }
        var lo = hs.min() ?? 9, hi = hs.max() ?? 17
        if back == 0 { let h = cal.component(.hour, from: now); lo = min(lo, h); hi = max(hi, h) }
        return Array(lo...hi)
    }

    private func grid(_ byStart: [Date: DayBlock]) -> some View {
        let day = cal.startOfDay(for: date)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 28, height: 1)
                ForEach([":00", ":15", ":30", ":45"], id: \.self) { t in
                    Text(verbatim: t).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 23 * 5, alignment: .leading)
                }
            }
            ForEach(hours(byStart), id: \.self) { h in
                HStack(spacing: 1) {
                    Text(verbatim: String(format: "%02d", h)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .monospacedDigit().frame(width: 27, alignment: .leading)
                    ForEach(0..<20, id: \.self) { n in
                        cell(day.addingTimeInterval(TimeInterval(h * 3600 + n * 180)), byStart)
                    }
                }
            }
            legend
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("3분 블록 타임라인"))
    }

    private func cell(_ start: Date, _ byStart: [Date: DayBlock]) -> some View {
        let b = byStart[start]
        let fill: Color = b.map { Self.color($0.label) } ?? Color.primary.opacity(0.05)
        let on = picked == start || hover == start
        return RoundedRectangle(cornerRadius: 3, style: .continuous).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.primary, lineWidth: 1.5).opacity(on && b != nil ? 1 : 0))
            .overlay(alignment: .topTrailing) {
                if b?.fixed == true { Circle().fill(Color.white).frame(width: 4, height: 4).padding(2) }
            }
            .frame(width: 22, height: 16)
            .contentShape(Rectangle())
            .onHover { inside in if inside { hover = b == nil ? nil : start } else if hover == start { hover = nil } }
            .onTapGesture { if b != nil { picked = start } }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach([DriftLabel?.some(.focus), .some(.neutral), .some(.drift), nil], id: \.self) { l in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Self.color(l)).frame(width: 10, height: 10)
                    Text(l?.label ?? L("자리 비움"))
                }
            }
            Spacer()
            Text(L("눌러서 라벨 고치기"))
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func detail(_ b: DayBlock?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            if let b {
                HStack(spacing: 8) {
                    Text(verbatim: Self.clock(b.start) + "~" + Self.clock(b.end)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Text(b.label?.label ?? L("자리 비움"))
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Self.color(b.label).opacity(b.label == nil ? 1 : 0.95)))
                    if b.fixed == true { Text(L("직접 고침")).font(.system(size: 10)).foregroundStyle(.secondary) }
                    Spacer()
                }
                if b.label != nil {
                    Text(verbatim: b.top == b.app || b.app.isEmpty ? b.top : "\(b.top) · \(b.app)").font(.system(size: 13, weight: .semibold))
                    if let t = b.title { Text(verbatim: t).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                    let seen = b.seen.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(4)
                    if seen.count > 1 {
                        Text(verbatim: seen.map { $0.key }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if picked == b.start {
                        HStack(spacing: 6) {
                            Text(L("라벨 고치기")).font(.system(size: 11)).foregroundStyle(.secondary)
                            ForEach(DriftLabel.allCases, id: \.self) { l in
                                Button(l.label) { center.correctBlock(b.start, to: l) }
                                    .controlSize(.small)
                                    .disabled(b.label == l)
                            }
                            Text(L("고치면 내 기준에 한 줄 남아요")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(L("키보드와 마우스 입력이 없던 3분이에요.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Text(L("블록에 마우스를 올리면 그때 무엇을 했는지 보여요. 누르면 라벨을 고칠 수 있어요."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(shape.fill(Color.primary.opacity(0.05)))
    }

    private func totals(_ blocks: [DayBlock]) -> some View {
        let rows = Array(DayLog.totals(blocks).prefix(8))
        let top = max(1, rows.first?.seconds ?? 1)
        return VStack(alignment: .leading, spacing: 5) {
            Text(L("앱·사이트별")).font(.system(size: 12, weight: .semibold))
            if rows.isEmpty { Text(L("아직 기록이 없어요")).font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(rows, id: \.name) { r in
                HStack(spacing: 8) {
                    Text(verbatim: r.name).font(.system(size: 11)).lineLimit(1).frame(width: 150, alignment: .leading)
                    // One bar in the labels' colours: the same site can be 집중 and 딴짓.
                    HStack(spacing: 0) {
                        ForEach(DriftLabel.allCases, id: \.self) { l in
                            if let sec = r.by[l], sec > 0 { Self.color(l).frame(width: 300 * CGFloat(sec) / CGFloat(top)) }
                        }
                    }
                    .frame(height: 10)
                    .frame(minWidth: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Text(verbatim: DayLog.duration(max(1, r.seconds / 60))).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(r.name + " " + DayLog.duration(max(1, r.seconds / 60)))
            }
        }
    }

    private var week: some View {
        let days = center.day.week(now)
        let top = max(60, days.map { $0.summary.total }.max() ?? 60)
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("E")
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("이번 주")).font(.system(size: 12, weight: .semibold))
                let w = days.reduce(DaySummary()) { DaySummary(focus: $0.focus + $1.summary.focus, neutral: $0.neutral + $1.summary.neutral, drift: $0.drift + $1.summary.drift) }
                Text(L("7일 집중 \(DayLog.duration(w.focus)) · 딴짓 \(DayLog.duration(w.drift))")).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .bottom, spacing: 18) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    let s = d.summary
                    Button {
                        back = 6 - i; picked = nil
                    } label: {
                        VStack(spacing: 3) {
                            Text(verbatim: s.focus > 0 ? DayLog.duration(s.focus) : "").font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                            VStack(spacing: 0) {
                                Self.color(.drift).frame(height: 110 * CGFloat(s.drift) / CGFloat(top))
                                Self.color(.neutral).frame(height: 110 * CGFloat(s.neutral) / CGFloat(top))
                                Self.color(.focus).frame(height: 110 * CGFloat(s.focus) / CGFloat(top))
                            }
                            .frame(width: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .background(alignment: .bottom) { RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)).frame(width: 30, height: 110) }
                            .frame(height: 110, alignment: .bottom)
                            Text(verbatim: f.string(from: d.day)).font(.system(size: 10, weight: 6 - i == back ? .bold : .regular))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("\(f.string(from: d.day)) 집중 \(DayLog.duration(s.focus)) 딴짓 \(DayLog.duration(s.drift))"))
                }
            }
        }
    }

    static func color(_ l: DriftLabel?) -> Color { l.map(DriftTimeline.color) ?? WeatherArt.color("#8FA3BF").opacity(0.45) }

    static func clock(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// The dashboard's line while 하루 기록 is on: the ring, today's minutes, the strip and the timeline button.
struct DaySummaryRow: View {
    @ObservedObject var center: DriftCenter = .shared
    var now = Date()

    var body: some View {
        let blocks = center.day.day(now)
        let s = DaySummary(blocks)
        let strip = blocks.compactMap { b in b.label.map { DriftLog.Block(start: b.start, label: $0, top: b.top) } }
        Panel {
            HStack(spacing: 10) {
                DriftRing(focus: s.focus, drift: s.drift)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(L("하루 기록")).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button(L("타임라인")) { DayWindow.open() }.controlSize(.mini)
                    }
                    Text(L("오늘 집중 \(DayLog.duration(s.focus)) · 딴짓 \(DayLog.duration(s.drift))")).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    DriftTimeline(blocks: strip, now: now, height: 8)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 설정

struct DaySection: View {
    @ObservedObject var center: DriftCenter = .shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var byo = BYOSettings.shared

    private var k: CGFloat { settings.settingsTextLarge ? 1.15 : 1 }
    private var tint: Color? { settings.palette.tint(.drift) }
    private func f(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * k, weight: w) }

    var body: some View {
        Panel(tint: tint.map { center.dayOn ? $0 : $0.opacity(0.5) }) {
            HStack(spacing: 8) {
                Text(verbatim: "⏱").font(.system(size: 14 * k))
                    .frame(width: 26 * k, height: 26 * k)
                    .background(Circle().fill(tint?.opacity(0.25) ?? Color.primary.opacity(0.08)))
                    .accessibilityHidden(true)
                Text(L("하루 기록")).font(.system(size: 13 * k, weight: .bold, design: .rounded))
                Spacer()
                Toggle(L("하루 기록"), isOn: $center.dayOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(tint)
            }
            Text(L("근무 시간과 상관없이 하루 종일 3분마다 무엇을 했는지 남겨요. 입력이 없으면 자리 비움으로 적어요. 딴짓 지킴이와 따로 켜고 꺼요."))
                .font(f(12)).foregroundStyle(.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                row(L("타임라인")) {
                    VStack(alignment: .leading, spacing: 2) {   // side by side the English button was cut
                        Button(L("오늘 타임라인 열기")) { DayWindow.open() }.controlSize(.small)
                        let s = DaySummary(center.day.day(Date()))
                        Text(L("오늘 집중 \(DayLog.duration(s.focus)) · 딴짓 \(DayLog.duration(s.drift))")).font(f(11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                row(L("브라우저 탭")) {
                    VStack(alignment: .leading, spacing: 2) {
                        onOff(L("브라우저 탭 보기"), Binding(get: { center.tabs }, set: { center.setTabs($0) }))
                        Text(L("켜야 같은 사이트에서도 강의 영상과 쇼츠를 구분해요")).font(f(10)).foregroundStyle(.secondary)
                    }
                }
                row(L("그 외 영상")) {
                    Picker(L("그 외 영상"), selection: $center.videoDrift) {
                        Text(L("딴짓")).tag(true)
                        Text(L("중립")).tag(false)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 140)
                }
                Text(L("쇼츠·릴스·틱톡은 딴짓, 제목에 강의·튜토리얼·코딩처럼 배우는 말이나 업무 프로필 단어가 있는 영상은 집중이에요. 네이버·다음 뉴스, 카페, 블로그도 주소와 제목으로 나눠요."))
                    .font(f(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                row(L("AI 분류")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Picker(L("AI 분류"), selection: Binding(get: { center.dayAI }, set: { center.setDayAI($0) })) {
                            Text(L("이 맥에서만")).tag(false)
                            Text(L("내 AI 연결")).tag(true)
                        }
                        .labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 180)
                        Text(center.dayAI ? L("규칙이 모르는 화면만 3분에 한 번 묶어서 \(byo.provider?.label ?? L("내 AI"))에 보내요. 앱 이름·도메인·탭 제목, 업무 프로필, 내 기준 메모만 가요.")
                                          : L("규칙과 이 맥 AI로만 판단해요. 아무것도 보내지 않아요."))
                            .font(f(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if center.dayAI, let p = byo.provider, !DayAI.allowed(method: byo.method, provider: p) {
                            Text(L("\(p.label) 구독 계정은 읽기 도구가 있어 탭 제목 속 지시를 따를 수 있어서 보내지 않아요. API 키나 Claude로 바꾸면 보내요."))
                                .font(f(10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        } else if center.dayAI, let why = center.dayAIFailure {
                            Text(verbatim: why).font(f(10)).foregroundStyle(.orange)
                        }
                    }
                }
                row(L("메뉴바 링")) { onOff(L("메뉴바에 집중 링 보이기"), $center.dayRing) }
                row(L("보관 기간")) {
                    Picker(L("보관 기간"), selection: $center.dayKeep) {
                        ForEach(DayLog.keepChoices, id: \.self) { Text(L("\($0)일")).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 120)
                }
                memoEditor
                HStack {
                    Button(L("CSV 내보내기")) { center.exportCSV() }.controlSize(.small).disabled(center.day.blocks.isEmpty)
                    Spacer()
                    Button(L("전부 지우기")) { center.clearDay() }.controlSize(.small).disabled(center.day.blocks.isEmpty)
                }
            }
            .disabled(!center.dayOn)
            .opacity(center.dayOn ? 1 : 0.55)
            Text(L("화면을 녹화하거나 찍지 않아요. 3분마다 앱 이름, 사이트, 탭 제목 요약과 판정을 이 맥에만 남기고, 내 AI 연결에 동의했을 때만 앱 이름·도메인·탭 제목, 업무 프로필, 내 기준 메모를 보내요."))
                .font(f(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var memoEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("내 기준")).font(f(12)).foregroundStyle(.secondary)
                Spacer()
                Button(L("지우기")) { center.memo = "" }.controlSize(.mini).disabled(center.memo.isEmpty)
            }
            TextEditor(text: $center.memo)
                .font(f(11))
                .frame(height: 76)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .accessibilityLabel(L("내 기준"))
            Text(L("타임라인에서 라벨을 고칠 때마다 한 줄씩 쌓여요. 직접 써도 돼요. 예: youtube.com · 제목에 \"피그마\" → 집중"))
                .font(f(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: label).font(f(12)).foregroundStyle(.secondary)
                .frame(width: 92 * k, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            control()
        }
    }

    private func onOff(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(tint)
    }
}

// MARK: - QA

/// --render-day: the 설정 card off and on, the timeline window with a block picked, the dashboard line and the ring,
/// light and dark. The day is made by the real rules from looks at made-up tabs. No file, timer, window or network.
enum DayQA {
    static func render(to dir: URL) throws {
        HotspotPanel.qaInert = true
        DriftFile.off = true
        let center = DriftCenter()
        center.profile = "앱 개발자"
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let now = today.addingTimeInterval(14 * 3600 + 40 * 60)
        center.memo = DayMemo.line(key: "youtube.com", title: "피그마 오토레이아웃", label: .focus)
        let day = sample(center, today: today, cal: cal)
        center.qaShowDay(day)
        let pick = day.day(now).first { $0.top == "youtube.com" && $0.label == .drift }?.start
        for (a, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            center.qaShowDay(DayLog(), on: false)
            try DashboardSnapshot.snapshot(DaySection(center: center).frame(width: 380).padding(), appearance: a,
                                           to: dir.appendingPathComponent("day-settings-off-\(suffix).png"))
            center.qaShowDay(day, on: true, ai: true)
            try DashboardSnapshot.snapshot(DaySection(center: center).frame(width: 380).padding(), appearance: a,
                                           to: dir.appendingPathComponent("day-settings-on-\(suffix).png"))
            try DashboardSnapshot.snapshot(DayTimelineView(center: center, now: now, scrolls: false, picked: pick), appearance: a,
                                           to: dir.appendingPathComponent("day-timeline-\(suffix).png"))
            try DashboardSnapshot.snapshot(DaySummaryRow(center: center, now: now).frame(width: 376).padding(), appearance: a,
                                           to: dir.appendingPathComponent("day-summary-\(suffix).png"))
        }
        let rings = HStack(spacing: 12) {
            ForEach([(0, 0), (48, 18), (90, 5), (5, 60)], id: \.0) { f, d in
                Image(nsImage: DayRing.image(focus: f, drift: d, side: 16)).resizable().interpolation(.high).frame(width: 48, height: 48)
            }
        }
        try DashboardSnapshot.snapshot(rings.padding(), appearance: .aqua, to: dir.appendingPathComponent("day-ring.png"))
        try DashboardSnapshot.snapshot(rings.padding(), appearance: .darkAqua, to: dir.appendingPathComponent("day-ring-dark.png"))
        let csv = dir.appendingPathComponent("day.csv")
        try Data(day.csv().utf8).write(to: csv)
    }

    /// Today from 09:00 to 15:39 and the six days before: tabs and apps, labelled by the center's rules.
    static func sample(_ center: DriftCenter, today: Date, cal: Calendar) -> DayLog {
        typealias Look = (app: String, name: String, url: String?, title: String?)
        let xcode: Look = ("com.apple.dt.Xcode", "Xcode", nil, nil)
        let lecture: Look = ("com.google.Chrome", "Chrome", "https://www.youtube.com/watch?v=a1", "SwiftUI 튜토리얼 3강 - YouTube")
        let shorts: Look = ("com.google.Chrome", "Chrome", "https://www.youtube.com/shorts/x9", "고양이 점프 #shorts - YouTube")
        let figma: Look = ("com.google.Chrome", "Chrome", "https://www.youtube.com/watch?v=f2", "피그마 오토레이아웃 정리 - YouTube")
        let slack: Look = ("com.tinyspeck.slackmacgap", "Slack", nil, nil)
        let github: Look = ("com.google.Chrome", "Chrome", "https://github.com/jelly/app/pull/12", "Fix timeline · Pull Request #12")
        let reel: Look = ("com.google.Chrome", "Chrome", "https://www.instagram.com/reel/abc/", "Instagram")
        let news: Look = ("com.google.Chrome", "Chrome", "https://n.news.naver.com/article/001/1", "환율 소식 : 네이버 뉴스")
        let script: [(Int, Look?)] = [(14, xcode), (6, lecture), (3, slack), (4, shorts), (12, github), (2, news), (10, nil), (5, figma),
                                      (16, xcode), (3, reel), (2, slack), (12, github), (5, nil), (10, xcode), (3, shorts), (6, lecture)]
        var log = DayLog()
        var rec = DayRecorder()
        var t = today.addingTimeInterval(9 * 3600)
        for (blocks, look) in script {
            for _ in 0..<(blocks * 18) {
                let item = look.map { l -> (DriftLabel, DriftSample) in
                    let s = DriftSample(at: t, app: l.app, appName: l.name, url: l.url, title: l.title)
                    return (center.rule(s) ?? .neutral, s)
                }
                if let b = rec.add(item, at: t, calendar: cal) { log.add(b, now: t, keepDays: 7, calendar: cal) }
                t += DriftRules.sampleEvery
            }
        }
        if let b = rec.close() { log.add(b, now: t, keepDays: 7, calendar: cal) }
        // The week before: whole blocks, made-up but steady.
        for back in 1...6 {
            guard let d = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekend = cal.isDateInWeekend(d)
            let mix: [(Int, DriftLabel, String)] = weekend ? [(20, .drift, "youtube.com"), (10, .neutral, "Safari")]
                : [(40 + back * 7, .focus, "Xcode"), (8, .neutral, "Slack"), (6 + back * 2, .drift, "youtube.com"), (30, .focus, "github.com")]
            var s = d.addingTimeInterval(9 * 3600 + 30 * 60)
            for (n, label, top) in mix {
                for _ in 0..<n {
                    log.blocks.append(DayBlock(start: s, label: label, top: top, key: top, app: top, title: nil, seen: [top: 18]))
                    s += DriftRules.blockSeconds
                }
            }
        }
        log.blocks.sort { $0.start < $1.start }
        return log
    }
}
#endif
