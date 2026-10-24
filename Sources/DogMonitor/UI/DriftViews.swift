#if !MAS
import AppKit
import SwiftUI

// 딴짓 지킴이 on screen: the nudge card, the 설정 card, the dashboard's today line, and their QA renders.

/// The card over a desktop friend's head (or under the menu bar icon): a sticker in the 집중 위젯's colours that takes
/// clicks without taking the focus from the app in front.
final class DriftCard {
    static let shared = DriftCard()
    private var panel: NSPanel?

    func show() {
        guard !HotspotPanel.qaInert else { return }
        let p = panel ?? makePanel()
        panel = p
        p.contentView = FirstClickHost(rootView: DriftCardView(center: .shared))
        place()
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func place() {
        guard let p = panel, let host = p.contentView else { return }
        let size = host.fittingSize
        p.setContentSize(size)
        let origin = DesktopFriends.speaker.flatMap { $0() }.map { SpeechBubbleWindow.above($0, size: size, lift: FocusBubble.shared.lift(over: $0)) }
            ?? SpeechBubbleWindow.underIcon(size: size)
        p.setFrameOrigin(origin)
    }

    private func makePanel() -> NSPanel {
        let p = DriftPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.sharingType = .none   // what was on screen stays out of screen shares
        return p
    }
}

/// Never key: pressing a button leaves the app in front as it was (the paw re-checks that it is).
private final class DriftPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct DriftCardView: View {
    @ObservedObject var center: DriftCenter
    /// QA renders: this kind instead of the center's.
    var preview: DriftCardKind?
    var previewSnooze = false
    var previewPaw = false
    @State private var snoozing = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let hex = FocusCenter.shared.theme.hexes(dark: dark)
        let fill = WeatherArt.color(hex.fill), ink = WeatherArt.color(hex.ink), accent = WeatherArt.color(hex.accent)
        let rim = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let polite = !AssistantModel.persona().style.banmal
        VStack(spacing: 0) {
            if let kind = preview ?? center.card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Text(verbatim: "🐾").font(.system(size: 12)).accessibilityHidden(true)
                        Text(L("딴짓 지킴이")).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(ink.opacity(0.7))
                    }
                    Text(verbatim: Self.line(kind, polite: polite))
                        .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 250, alignment: .leading)
                    if case .nudge = kind, previewPaw || center.pawUp {
                        Text(polite ? L("고양이가 앞발을 들었어요. 고양이를 누르면 안 닫아요.") : L("고양이가 앞발을 들었어. 고양이를 누르면 안 닫아."))
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(accent)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 250, alignment: .leading)
                    }
                    buttons(kind, ink: ink, accent: accent)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(rim.fill(fill))
                .overlay(rim.strokeBorder(Color.white.opacity(dark ? 0.35 : 1), lineWidth: 2.5))
                SpeechBubbleView.Tail().fill(fill).frame(width: 14, height: 7).rotationEffect(.degrees(180)).padding(.top, -2.5)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .padding(8)
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    static func line(_ kind: DriftCardKind, polite: Bool) -> String {
        switch kind {
        case .nudge(let back?):
            return polite ? L("아까 \(back) 하던 중이었죠. 돌아갈까요?") : L("아까 \(back) 하던 중이었지. 돌아갈까?")
        case .nudge(nil):
            return polite ? L("한눈팔고 있는 것 같아요. 하던 일로 돌아갈까요?") : L("한눈팔고 있는 것 같아. 하던 일로 돌아갈까?")
        case .still:
            return polite ? L("잡혔다! 그대로 둘게요. 아직 딴짓 중이에요?") : L("잡혔다! 그대로 둘게. 아직 딴짓 중이야?")
        case .closed(let what, let back?):
            return polite ? L("\(what) 창은 냥펀치로 닫았어요. \(back) 화면으로 돌아왔어요.") : L("\(what) 창은 냥펀치로 닫았어. \(back) 화면으로 돌아왔어.")
        case .closed(let what, nil):
            return polite ? L("\(what) 창은 냥펀치로 닫았어요.") : L("\(what) 창은 냥펀치로 닫았어.")
        }
    }

    @ViewBuilder
    private func buttons(_ kind: DriftCardKind, ink: Color, accent: Color) -> some View {
        let soft = PillButton(fill: ink.opacity(0.12), text: ink, k: 1)
        let strong = PillButton(fill: accent, text: .white, k: 1)
        switch kind {
        case .nudge:
            if snoozing || previewSnooze {
                HStack(spacing: 6) {
                    Button(L("10분 쉬기")) { center.snooze(10) }.buttonStyle(strong)
                    Button(L("20분 쉬기")) { center.snooze(20) }.buttonStyle(strong)
                    Button(L("취소")) { snoozing = false }.buttonStyle(soft)
                }
            } else {
                HStack(spacing: 6) {
                    Button(L("돌아가기")) { center.goBack() }.buttonStyle(strong)
                    Button(L("쉬는 중")) { snoozing = true }.buttonStyle(soft)
                    Button(L("딴짓 아님")) { center.notDrift() }.buttonStyle(soft)
                        .help(L("이 사이트나 앱을 집중 목록에 넣어요"))
                }
            }
        case .still:
            HStack(spacing: 6) {
                Button(L("네, 계속 봐 줘요")) { center.stillDrifting() }.buttonStyle(strong)
                Button(L("아니요, 일하는 중")) { center.notDrift() }.buttonStyle(soft)
                    .help(L("이 사이트나 앱을 집중 목록에 넣어요"))
            }
        case .closed:
            Button(L("알겠어요")) { center.closeCard() }.buttonStyle(soft)
        }
    }
}

// MARK: - Today

/// Today's blocks as one strip: 집중 green, 중립 grey, 딴짓 orange, the empty stretches clear.
struct DriftTimeline: View {
    var blocks: [DriftLog.Block]
    var now: Date
    var height: CGFloat = 12

    var body: some View {
        let day = Calendar.current.startOfDay(for: now)
        let first = blocks.map(\.start).min() ?? now
        let from = min(first, now.addingTimeInterval(-3600))
        let span = max(3600, now.timeIntervalSince(from))
        VStack(spacing: 3) {
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 3), with: .color(Color.primary.opacity(0.08)))
                for b in blocks {
                    let x = CGFloat(b.start.timeIntervalSince(from) / span) * size.width
                    let w = max(1, CGFloat(DriftRules.blockSeconds / span) * size.width)
                    ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Self.color(b.label)))
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
            HStack {
                Text(verbatim: DriftHours.clock(Int(from.timeIntervalSince(day) / 60)))
                Spacer()
                Text(L("지금"))
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("오늘 3분 블록 타임라인"))
    }

    static func color(_ l: DriftLabel) -> Color {
        switch l {
        case .focus: return WeatherArt.color("#3FAE6A")
        case .neutral: return Color.gray.opacity(0.55)
        case .drift: return WeatherArt.color("#F08A3C")
        }
    }
}

/// The ring: today's 집중 against 딴짓 (중립 left out).
struct DriftRing: View {
    var focus: Int
    var drift: Int
    var size: CGFloat = 34

    var body: some View {
        let total = max(1, focus + drift)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(drift) / CGFloat(total))
                .stroke(DriftTimeline.color(.drift), style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                .rotationEffect(.degrees(-90 + 360 * Double(focus) / Double(total)))
            Circle().trim(from: 0, to: CGFloat(focus) / CGFloat(total))
                .stroke(DriftTimeline.color(.focus), style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "🐾").font(.system(size: size * 0.36))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The dashboard's line while 딴짓 지킴이 is on: the ring, today's minutes and the strip.
struct DriftSummaryRow: View {
    @ObservedObject var center: DriftCenter = .shared
    var now = Date()

    var body: some View {
        let m = center.log.minutes(now)
        let focus = m[.focus] ?? 0, drift = m[.drift] ?? 0
        Panel {
            HStack(spacing: 10) {
                DriftRing(focus: focus, drift: drift)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(L("딴짓 지킴이")).font(.system(size: 12, weight: .semibold))
                        Text(verbatim: center.watching ? L("지켜보는 중") : L("지금은 안 봐요"))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text(L("오늘 집중 \(focus)분 · 딴짓 \(drift)분")).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    DriftTimeline(blocks: center.log.today(now), now: now, height: 8)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 설정

struct DriftSection: View {
    @ObservedObject var center: DriftCenter = .shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var site = ""
    var now = Date()

    private var k: CGFloat { settings.settingsTextLarge ? 1.15 : 1 }
    private var tint: Color? { settings.palette.tint(.drift) }
    private func f(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * k, weight: w) }

    var body: some View {
        Panel(tint: tint.map { center.on ? $0 : $0.opacity(0.5) }) {
            HStack(spacing: 8) {
                Text(verbatim: "🐾").font(.system(size: 14 * k))
                    .frame(width: 26 * k, height: 26 * k)
                    .background(Circle().fill(tint?.opacity(0.25) ?? Color.primary.opacity(0.08)))
                    .accessibilityHidden(true)
                Text(L("딴짓 지킴이")).font(.system(size: 13 * k, weight: .bold, design: .rounded))
                Spacer()
                Toggle(L("딴짓 지킴이"), isOn: $center.on).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(tint)
            }
            Text(L("딴짓이 길어지면 아까 하던 일로 돌아가자고 말해 줘요. 고양이가 대신 닫아 줄 수도 있어요"))
                .font(f(12)).foregroundStyle(.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            row(L("타이머 중 자동")) { onOff(L("집중 타이머 중엔 자동으로 켜기"), $center.withTimer) }
            VStack(alignment: .leading, spacing: 7) {
                row(L("근무 시간")) {
                    HStack(spacing: 4) {
                        onOff(L("근무 시간에 지켜보기"), $center.hoursOn)
                        hourPicker(L("시작"), Binding(get: { center.hours.start / 60 }, set: { center.hours.start = $0 * 60 }))
                        Text(verbatim: "~").font(f(11)).foregroundStyle(.secondary)
                        hourPicker(L("끝"), Binding(get: { center.hours.end / 60 }, set: { center.hours.end = $0 * 60 }))
                        Toggle(L("평일만"), isOn: $center.hours.weekdaysOnly).toggleStyle(.checkbox).controlSize(.small).font(f(11))
                    }
                    .disabled(!center.hoursOn)
                }
                row(L("딴짓 확정")) {
                    Picker(L("딴짓 확정"), selection: $center.needed) {
                        ForEach(1...4, id: \.self) { Text(L("\($0 * 3)분")).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                row(L("브라우저 탭")) {
                    VStack(alignment: .leading, spacing: 2) {
                        onOff(L("브라우저 탭 보기"), Binding(get: { center.tabs }, set: { center.setTabs($0) }))
                        if !center.deniedBrowsers.isEmpty {
                            Text(L("허용 안 된 브라우저는 앱 이름으로만 봐요. 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 켤 수 있어요."))
                                .font(f(10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                row(L("업무 프로필")) {
                    TextField(L("예: 앱 개발자, 영상 편집자"), text: $center.profile).textFieldStyle(.roundedBorder).font(f(11)).controlSize(.small)
                }
                row(L("이 맥 AI")) {
                    HStack(spacing: 6) {
                        onOff(L("애매한 건 이 맥 AI에게 묻기"), $center.useAI).disabled(!OnDeviceEngine.isAvailable)
                        Text(OnDeviceEngine.isAvailable ? L("규칙이 모르는 것만, 맥 안에서") : L("이 맥에서는 쓸 수 없어요"))
                            .font(f(10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                listsEditor
                Divider().padding(.vertical, 2)
                catRows
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    let m = center.log.minutes(now)
                    HStack {
                        Text(L("오늘")).font(f(12)).foregroundStyle(.secondary)
                        Text(L("집중 \(m[.focus] ?? 0)분 · 중립 \(m[.neutral] ?? 0)분 · 딴짓 \(m[.drift] ?? 0)분")).font(f(11)).monospacedDigit()
                        Spacer()
                    }
                    DriftTimeline(blocks: center.log.today(now), now: now)
                }
            }
            .disabled(!center.on && !center.withTimer)
            .opacity(center.on || center.withTimer ? 1 : 0.55)
            // Outside the switch's reach: the record can be wiped with watching off too.
            HStack {
                Spacer()
                Button(L("기록 지우기")) { center.clearLog() }.controlSize(.small)
            }
            Text(L("판단은 모두 이 맥 안에서 해요. 화면을 녹화하거나 찍지 않고, 기록은 3분마다 사이트나 앱 이름 하나와 집중·중립·딴짓만 7일 동안 남겨요. 회의·화면 공유·녹화 중에는 카드를 미뤄요."))
                .font(f(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var listsEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            row(L("목록에 넣기")) {
                HStack(spacing: 4) {
                    TextField(L("사이트 주소"), text: $site).textFieldStyle(.roundedBorder).font(f(11)).controlSize(.small)
                    Button(L("집중")) { center.add(site, to: .focus); site = "" }.controlSize(.small).disabled(site.isEmpty)
                    Button(L("딴짓")) { center.add(site, to: .drift); site = "" }.controlSize(.small).disabled(site.isEmpty)
                    appMenu(L("앱…")) { id in center.add(id, to: .drift) }
                }
            }
            chips(L("집중 목록"), center.lists.focus) { center.remove($0) }
            chips(L("딴짓 목록"), center.lists.drift) { center.remove($0) }
            Text(L("기본 딴짓: 영상·SNS·쇼핑·커뮤니티·게임·웹툰 사이트와 게임 앱. 업무 프로필에 '영상 편집'처럼 쓰면 그 종류는 딴짓으로 치지 않아요. 카드에서 '딴짓 아님'을 누르면 집중 목록으로 옮겨요."))
                .font(f(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var catRows: some View {
        VStack(alignment: .leading, spacing: 7) {
            row(L("고양이")) { onOff(L("고양이 보이기"), $center.cat) }
            Group {
                row(L("털색")) {
                    HStack(spacing: 6) {
                        ForEach(DriftCoat.allCases, id: \.self) { c in coatSwatch(c) }
                        Text(center.coat.label).font(f(11)).foregroundStyle(.secondary)
                    }
                }
                row(L("크기")) {
                    Picker(L("크기"), selection: $center.catSize) {
                        ForEach(DriftCatSize.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                row(L("평소에는")) {
                    Picker(L("평소에는"), selection: $center.catPlays) {
                        Text(L("데스크톱에서 놀기")).tag(true)
                        Text(L("숨어 있기")).tag(false)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                row(L("발로 닫기")) { onOff(L("발로 닫기"), Binding(get: { center.paw }, set: { center.setPaw($0) })) }
                row(L("잡을 시간")) {
                    HStack {
                        Slider(value: $center.pawSeconds, in: 2...6, step: 0.5).controlSize(.small)
                        Text(L("\(String(format: "%.1f", center.pawSeconds))초")).font(f(11)).monospacedDigit().frame(width: 34)
                    }
                    .disabled(!center.paw)
                }
                row(L("보호할 앱")) {
                    HStack(spacing: 4) {
                        Text(L("기본 보호 \(CleanerRules.defaultProtected.count)개 + 직접 \(center.protectedApps.count)개")).font(f(11)).foregroundStyle(.secondary)
                        appMenu(L("추가…")) { center.protect($0) }
                    }
                }
                if !center.protectedApps.isEmpty { chips(L("직접 보호"), center.protectedApps) { center.unprotect($0) } }
            }
            .disabled(!center.cat)
            Text(L("고양이는 처음엔 꺼져 있어요. 딴짓이 확정되고 발로 닫기가 켜져 있을 때만 달려와 그 창 위에서 앞발을 들어요. 앞발이 내려오기 전에 고양이를 누르면 그대로 두고 다음 카드에서 물어봐요. 못 잡으면 브라우저는 그 탭만, 앱은 정상 종료로 닫고 하던 화면으로 돌아가요."))
                .font(f(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func coatSwatch(_ c: DriftCoat) -> some View {
        let p = c.profile
        let base = p.map { Color(.sRGB, red: Double($0.baseColor.r) / 255, green: Double($0.baseColor.g) / 255, blue: Double($0.baseColor.b) / 255) } ?? .gray
        let mark = p.map { Color(.sRGB, red: Double($0.secondaryColor.r) / 255, green: Double($0.secondaryColor.g) / 255, blue: Double($0.secondaryColor.b) / 255) } ?? .gray
        let chosen = center.coat == c
        return Button { center.coat = c } label: {
            Circle().fill(base)
                .overlay(Circle().trim(from: 0.5, to: 1).fill(mark).opacity(c == .mackerel || c == .cheese || c == .calico || c == .tuxedo ? 1 : 0))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                .frame(width: 18, height: 18).padding(2)
                .overlay(Circle().strokeBorder(Color.primary, lineWidth: 1.5).opacity(chosen ? 1 : 0))
        }
        .buttonStyle(.plain)
        .help(c.label)
        .accessibilityLabel(c.label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func hourPicker(_ label: String, _ value: Binding<Int>) -> some View {
        Picker(label, selection: value) {
            ForEach(0..<24, id: \.self) { Text(verbatim: String(format: "%02d", $0)).tag($0) }
        }
        .labelsHidden().controlSize(.small).frame(width: 54)
    }

    /// The apps running now, to pick from without typing a bundle id.
    private func appMenu(_ title: String, pick: @escaping (String) -> Void) -> some View {
        Menu(title) {
            ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }, id: \.0) { id, name in
                Button(name) { pick(id) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().font(f(11))
    }

    private func chips(_ title: String, _ items: [String], remove: @escaping (String) -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title).font(f(10)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            if items.isEmpty {
                Text(L("없음")).font(f(10)).foregroundStyle(.secondary)
            } else {
                FlowRow(spacing: 4) {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 2) {
                            Text(verbatim: Self.name(item)).font(f(10)).lineLimit(1)
                            Button { remove(item) } label: { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }
                                .buttonStyle(.plain).accessibilityLabel(L("\(Self.name(item)) 빼기"))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
            }
        }
    }

    /// A bundle id as the app's name when it is installed; a site as it is.
    static func name(_ item: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item) else { return item }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
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

/// Chips that wrap onto the next line.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - QA

/// --render-drift: the 설정 card off and on, the three cards, the 6 털색 x 4 크기 sheet, the paw frames and the
/// dashboard line, light and dark. Its own preferences; no file, timer, panel or script.
enum DriftQA {
    static func render(to dir: URL) throws {
        HotspotPanel.qaInert = true
        DriftFile.off = true
        let center = DriftCenter()
        let day = Calendar.current.startOfDay(for: Date())
        let now = day.addingTimeInterval(14 * 3600 + 20 * 60)
        var log = DriftLog()
        let script: [(Int, DriftLabel, String)] = [(20, .focus, "Xcode"), (4, .neutral, "Finder"), (3, .drift, "youtube.com"),
                                                   (25, .focus, "github.com"), (2, .neutral, "Slack"), (5, .drift, "instagram.com"),
                                                   (14, .focus, "Figma")]
        var t = day.addingTimeInterval(9 * 3600 + 30 * 60)
        for (n, label, top) in script {
            for _ in 0..<n { log.blocks.append(DriftLog.Block(start: t, label: label, top: top)); t += DriftRules.blockSeconds }
        }
        center.add("github.com", to: .focus)
        center.add("com.apple.dt.Xcode", to: .focus)
        center.add("namu.wiki", to: .drift)
        center.profile = "앱 개발자"
        let back = DriftTarget(app: "com.apple.dt.Xcode", appName: "Xcode", url: nil)
        for (a, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            center.qaShow(log: DriftLog(), card: nil, lastFocus: nil, on: false)
            try DashboardSnapshot.snapshot(DriftSection(center: center, now: now).frame(width: 380).padding(), appearance: a,
                                           to: dir.appendingPathComponent("drift-settings-off-\(suffix).png"))
            center.qaShow(log: log, card: nil, lastFocus: back, on: true)
            center.cat = true
            try DashboardSnapshot.snapshot(DriftSection(center: center, now: now).frame(width: 380).padding(), appearance: a,
                                           to: dir.appendingPathComponent("drift-settings-on-\(suffix).png"))
            let cards: [(String, DriftCardKind, Bool)] = [("nudge", .nudge(back: "Xcode"), false), ("nudge-paw", .nudge(back: "Xcode"), false), ("nudge-snooze", .nudge(back: "Xcode"), true),
                                                          ("still", .still, false), ("closed", .closed(what: "youtube.com", back: "Xcode"), false)]
            for (name, kind, snooze) in cards {
                try DashboardSnapshot.snapshot(DriftCardView(center: center, preview: kind, previewSnooze: snooze, previewPaw: name == "nudge-paw").padding(), appearance: a,
                                               to: dir.appendingPathComponent("drift-card-\(name)-\(suffix).png"))
            }
            try DashboardSnapshot.snapshot(DriftSummaryRow(center: center, now: now).frame(width: 376).padding(), appearance: a,
                                           to: dir.appendingPathComponent("drift-summary-\(suffix).png"))
        }
        try DashboardSnapshot.snapshot(CatSheet().padding(), appearance: .aqua, to: dir.appendingPathComponent("drift-cats.png"))
        try DashboardSnapshot.snapshot(PawSheet().padding(), appearance: .aqua, to: dir.appendingPathComponent("drift-paw.png"))
        try DashboardSnapshot.snapshot(PawSheet().padding(), appearance: .darkAqua, to: dir.appendingPathComponent("drift-paw-dark.png"))
    }

    /// Every 털색 at every 크기, walking.
    private struct CatSheet: View {
        var body: some View {
            Grid(alignment: .bottom, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text(verbatim: "")
                    ForEach(DriftCatSize.allCases, id: \.self) { Text($0.label).font(.system(size: 11, weight: .semibold)) }
                }
                ForEach(DriftCoat.allCases, id: \.self) { coat in
                    GridRow {
                        Text(coat.label).font(.system(size: 11, weight: .semibold))
                        ForEach(DriftCatSize.allCases, id: \.self) { size in
                            let cache = DogSpriteCache(coat.character!, pixelSize: size.pixelSize, outfit: .some(nil))
                            Image(nsImage: DriftCatArt.image(cache, pose: .walk, coat: coat.profile, paw: .none)).interpolation(.none)
                        }
                    }
                }
            }
        }
    }

    /// The nudge's frames at 크게: running, paw up (just up, half, about to land), caught, landed.
    private struct PawSheet: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                ForEach([DriftCoat.cheese, .black, .tuxedo], id: \.self) { coat in
                    let cache = DogSpriteCache(coat.character!, pixelSize: 3, outfit: .some(nil))
                    HStack(alignment: .bottom, spacing: 14) {
                        frame(cache, coat, .run, .none, L("달려오기"))
                        frame(cache, coat, .walk, .up(0), L("앞발 들기"))
                        frame(cache, coat, .walk, .up(0.9), L("내려찍기 직전"))
                        frame(cache, coat, .walk, .caught, L("잡혔다"))
                        frame(cache, coat, .walk, .down, L("냥펀치"))
                    }
                }
            }
        }

        private func frame(_ cache: DogSpriteCache, _ coat: DriftCoat, _ pose: DogPose, _ paw: PawPose, _ label: String) -> some View {
            VStack(spacing: 4) {
                Image(nsImage: DriftCatArt.image(cache, pose: pose, coat: coat.profile, paw: paw))
                    .interpolation(.none)
                    .background(Rectangle().fill(Color.primary.opacity(0.05)))
                Text(verbatim: label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
