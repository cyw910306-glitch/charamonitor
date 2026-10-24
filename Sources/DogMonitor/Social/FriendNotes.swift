import AppKit
import SwiftUI

// 오늘 한마디 and the profile card, and 낙서 쪽지. Both travel to 근처 친구 (SocialMessage .note/.doodle, version 2 and up)
// and to the 원격 모임 (MeetEvent .note/.doodle). A doodle shows 5 s over a character and is never kept; notes live in
// memory only. Keys: social.line, social.lineDay (the 한마디 holds for the day it was written).

/// What a friend's profile card shows besides the name and status. 운세 travels as its draw only: (day, draw) makes the
/// same reading on every Mac (Fortune.reading).
struct FriendNote: Codable, Equatable {
    static let maxLine = 40

    /// "2026-10-24": the sender's day; a card shows the parts while it is within a day of the viewer's (time zones).
    var day: String
    /// 오늘 한마디, 40 characters.
    var line: String?
    /// 0, or 1 after 다시 뽑기.
    var fortune: Int
    /// Today's 점심 뽑기 result.
    var lunch: String?

    /// A friend's note as this Mac keeps it: a real day, a cleaned line and lunch, the draw in range; nil when the day
    /// is not one.
    static func received(_ n: FriendNote) -> FriendNote? {
        guard isDay(n.day) else { return nil }
        let line = n.line.map { SocialText.clean($0, max: maxLine) }.flatMap { $0.isEmpty ? nil : $0 }
        let lunch = n.lunch.flatMap { LunchRules.clean(SocialText.clean($0, max: LunchRules.maxName)) }
        return FriendNote(day: n.day, line: line, fortune: min(max(n.fortune, 0), Fortune.redrawsPerDay), lunch: lunch)
    }

    /// "YYYY-MM-DD" and nothing else.
    static func isDay(_ s: String) -> Bool {
        s.utf8.count == 10 && s.utf8.enumerated().allSatisfy { i, c in i == 4 || i == 7 ? c == UInt8(ascii: "-") : (48...57).contains(c) }
    }

    var reading: FortuneReading { Fortune.reading(day: day, draw: fortune) }

    /// The sender's day against the viewer's: the same, or one apart (a friend an hour ahead is already on tomorrow).
    /// Same time zone at midnight: SocialBus sends a new note when the day changes.
    static func current(_ day: String, today: String) -> Bool {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let a = f.date(from: day), let b = f.date(from: today) else { return false }
        return abs(a.timeIntervalSince(b)) <= 86_400
    }
}

/// One profile card: a friend's (or a 원격 모임 member's) name, status and note.
struct FriendCard: Equatable {
    var name: String
    /// nil: offline, or a 원격 모임 member (no chip).
    var status: OfficeStatus?
    var note: FriendNote?
}

extension SocialBus {
    /// 오늘 한마디, or "" when none was written today.
    func todayLine(now: Date = Date()) -> String {
        defaults.string(forKey: "social.lineDay") == WorkHours.day(now) ? defaults.string(forKey: "social.line") ?? "" : ""
    }

    func setTodayLine(_ s: String, now: Date = Date()) {
        defaults.set(SocialText.clean(s, max: FriendNote.maxLine), forKey: "social.line")
        defaults.set(WorkHours.day(now), forKey: "social.lineDay")
        objectWillChange.send()
        shareNote()
    }

    func myNote(now: Date = Date()) -> FriendNote {
        let line = todayLine(now: now)
        return FriendNote(day: WorkHours.day(now), line: line.isEmpty ? nil : line, fortune: Fortune.today(now: now).draw,
                          lunch: Lunch.today?.menu.name)
    }

    /// To online friends that read notes and to the 원격 모임: after a new 한마디, 운세 다시 뽑기 or 점심.
    func shareNote() {
        let n = myNote()
        RoomRules.emoteTargets(online: online, versions: versions).forEach { send(.note(n), to: $0) }
        RemoteMeet.shared.sendNote(n)
    }

    func card(_ id: String) -> FriendCard? {
        friend(id).map { FriendCard(name: $0.nickname, status: online.contains(id) ? $0.status : nil, note: notes[id]) }
    }

    /// 오늘 한마디… in a small dialog.
    func askLine() {
        let a = NSAlert()
        a.messageText = L("오늘 한마디")
        a.informativeText = L("친구에게만 보여요. 오늘 하루 동안 프로필 카드에 남아요.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L("40자까지")
        field.stringValue = todayLine()
        a.accessoryView = field
        a.addButton(withTitle: L("저장"))
        a.addButton(withTitle: L("취소"))
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { setTodayLine(field.stringValue) }
    }
}

// MARK: 낙서 쪽지

/// A doodle as it travels: each stroke is x,y byte pairs on a 64 x 64 grid (top left 0,0). 300 points at most, so it
/// fits one sealed 원격 모임 event.
struct Doodle: Codable, Equatable {
    static let grid = 64, maxStrokes = 24, maxPoints = 300

    var strokes: [Data]

    var pointCount: Int { strokes.reduce(0) { $0 + $1.count / 2 } }

    /// Strokes drawn in a `size` canvas, snapped to the grid with repeats dropped; points past 300 are cut. nil when
    /// nothing is left.
    static func pack(_ lines: [[CGPoint]], in size: CGSize) -> Doodle? {
        guard size.width > 0, size.height > 0 else { return nil }
        func cell(_ v: CGFloat, _ side: CGFloat) -> UInt8 { UInt8(min(max(Int(v / side * CGFloat(grid)), 0), grid - 1)) }
        var out: [Data] = [], left = maxPoints
        for line in lines.prefix(maxStrokes) where left > 0 {
            var d = Data()
            for p in line where left > 0 {
                let x = cell(p.x, size.width), y = cell(p.y, size.height)
                if d.count >= 2, d[d.count - 2] == x, d[d.count - 1] == y { continue }
                d.append(contentsOf: [x, y])
                left -= 1
            }
            if !d.isEmpty { out.append(d) }
        }
        return out.isEmpty ? nil : Doodle(strokes: out)
    }

    /// A doodle from the network: 1 to 24 strokes of whole points, 300 points at most, every value on the grid.
    static func received(_ d: Doodle) -> Doodle? {
        guard (1...maxStrokes).contains(d.strokes.count), d.pointCount <= maxPoints,
              d.strokes.allSatisfy({ !$0.isEmpty && $0.count % 2 == 0 && $0.allSatisfy { Int($0) < grid } }) else { return nil }
        return d
    }

    /// The strokes in 0...1 of the canvas, each point in the middle of its cell.
    var unitStrokes: [[CGPoint]] {
        let g = CGFloat(Self.grid)
        return strokes.map { s -> [CGPoint] in
            let b = [UInt8](s)
            var out: [CGPoint] = []
            for i in stride(from: 0, to: b.count - 1, by: 2) {
                out.append(CGPoint(x: (CGFloat(b[i]) + 0.5) / g, y: (CGFloat(b[i + 1]) + 0.5) / g))
            }
            return out
        }
    }
}

enum DoodleTarget: Equatable {
    case friend(String)
    case meet
}

/// The pad, sending, and a received doodle over a character.
enum DoodleCenter {
    static let showSeconds: TimeInterval = 5
    /// Between two of my doodles (a friend's Mac takes 2 in 10 s).
    static let cooldown: TimeInterval = 3

    private static var lastSend: TimeInterval = -.infinity
    private static var pad: NSPanel?
    private static var shown: NSPanel?
    private static var hide: DispatchWorkItem?
    /// A received doodle is on screen now (QA reads it).
    static var showing: Bool { shown?.isVisible == true }

    /// 낙서 쪽지 보내기… for a friend or the 원격 모임.
    static func open(_ target: DoodleTarget, name: String) {
        pad?.close()
        let p = OfficeCenter.floatingPanel(title: L("\(name)에게 낙서 쪽지"), size: CGSize(width: 240, height: 290), resizable: false)
        p.contentView = NSHostingView(rootView: DoodlePadView { [weak p] d in
            guard send(d, to: target) else { return false }
            p?.close()
            return true
        })
        p.center()
        p.orderFrontRegardless()
        pad = p
    }

    /// False while waiting out the cooldown or when the friend cannot take it now.
    @discardableResult
    static func send(_ d: Doodle, to target: DoodleTarget) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSend >= cooldown else { return false }
        switch target {
        case .friend(let id):
            let bus = SocialBus.shared
            guard bus.online.contains(id), RoomRules.canEmote(version: bus.versions[id]) else { return false }
            bus.send(.doodle(d), to: id)
        case .meet:
            guard RemoteMeet.shared.sendDoodle(d) else { return false }
        }
        lastSend = now
        return true
    }

    /// Over the friend's seat on the Dock when it is there, else over my own friend. Nothing in a call or a recording.
    static func received(_ d: Doodle, from name: String, seat id: String?) {
        guard !FriendVisit.quiet() else { return }
        let seat = id.flatMap { id in FriendRoom.shared.seats.first { $0.id == id }?.panel }
        let anchor: CGPoint? = seat.map { CGPoint(x: $0.frame.midX, y: $0.frame.maxY) } ?? DesktopFriends.speaker?()
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let at = anchor ?? CGPoint(x: vf.midX, y: vf.maxY - 140)
        shown?.orderOut(nil)
        let size = CGSize(width: 116, height: 132)
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.sharingType = .none
        p.contentView = NSHostingView(rootView: DoodleNoteView(doodle: d, name: name))
        let x = min(max(at.x - size.width / 2, vf.minX), vf.maxX - size.width)
        p.setFrameOrigin(CGPoint(x: x, y: min(at.y + 2, vf.maxY - size.height)))
        p.orderFrontRegardless()
        shown = p
        hide?.cancel()
        let w = DispatchWorkItem { [weak p] in
            p?.orderOut(nil)
            if shown === p { shown = nil }
        }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + showSeconds, execute: w)
    }
}

/// The strokes, round-capped, in the given frame.
struct DoodleView: View {
    let doodle: Doodle
    var color: Color = Color(red: 0.2, green: 0.2, blue: 0.28)

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for s in doodle.unitStrokes {
                guard let first = s.first else { continue }
                let pt = { (p: CGPoint) in CGPoint(x: p.x * size.width, y: p.y * size.height) }
                path.move(to: pt(first))
                if s.count == 1 { path.addLine(to: pt(first).applying(.init(translationX: 0.5, y: 0))) }
                s.dropFirst().forEach { path.addLine(to: pt($0)) }
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(2, size.width / 40), lineCap: .round, lineJoin: .round))
        }
    }
}

/// A received doodle: a little paper note with the sender's name, a tail toward the character under it.
struct DoodleNoteView: View {
    let doodle: Doodle
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                DoodleView(doodle: doodle).frame(width: 96, height: 96)
                Text(verbatim: name).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(white: 0.3)).lineLimit(1)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 1, green: 0.98, blue: 0.9)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.55), lineWidth: 1))
            Triangle().fill(Color(red: 1, green: 0.98, blue: 0.9)).frame(width: 12, height: 7)
                .overlay(Triangle().stroke(Color(white: 0.55), lineWidth: 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("\(name)의 낙서 쪽지")))
    }

    private struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.minX, y: r.minY))
                p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            }
        }
    }
}

/// The pad: draw with the mouse, 지우기, 보내기. `send` false keeps the pad open (cooldown, friend gone).
struct DoodlePadView: View {
    static let side: CGFloat = 192
    var send: (Doodle) -> Bool
    @State var lines: [[CGPoint]] = []
    @State private var failed = false

    private var doodle: Doodle? { Doodle.pack(lines, in: CGSize(width: Self.side, height: Self.side)) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(red: 1, green: 0.98, blue: 0.9))
                if let d = doodle { DoodleView(doodle: d) }
            }
            .frame(width: Self.side, height: Self.side)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if v.translation == .zero || lines.isEmpty { lines.append([]) }
                lines[lines.count - 1].append(v.location)
            }.onEnded { _ in lines.append([]) })
            .accessibilityLabel(Text(L("낙서 칸")))
            HStack {
                Text(verbatim: "\(doodle?.pointCount ?? 0)/\(Doodle.maxPoints)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(L("지우기")) { lines = []; failed = false }.controlSize(.small)
                Button(L("보내기")) { if let d = doodle { failed = !send(d) } }
                    .controlSize(.small).keyboardShortcut(.defaultAction).disabled(doodle == nil)
            }
            .frame(width: Self.side)
            Text(failed ? L("지금은 못 보내요. 잠깐 뒤에 다시 해 주세요.") : L("5초 동안 친구 화면에 떴다가 사라져요. 저장하지 않아요."))
                .font(.system(size: 10)).foregroundStyle(failed ? .red : .secondary).frame(width: Self.side, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }
}

// MARK: 프로필 카드

enum FriendCardPanel {
    private static var panel: NSPanel?

    static func show(_ card: FriendCard) {
        panel?.close()
        let p = OfficeCenter.floatingPanel(title: L("프로필 카드"), size: CGSize(width: 260, height: 210), resizable: false)
        p.contentView = NSHostingView(rootView: FriendCardView(card: card, today: WorkHours.day(Date())))
        p.setContentSize(p.contentView?.fittingSize ?? p.frame.size)
        p.center()
        p.orderFrontRegardless()
        panel = p
    }
}

/// 닉네임, 상태, 오늘 한마디, 오늘 운세, 오늘 점심. An older note shows nothing but the name and status.
struct FriendCardView: View {
    let card: FriendCard
    let today: String

    var body: some View {
        let note = card.note.flatMap { FriendNote.current($0.day, today: today) ? $0 : nil }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: card.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Spacer(minLength: 0)
                if let st = card.status {
                    Text(verbatim: "\(st.emoji) \(st.label)")
                        .font(.system(size: 10))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            Text(verbatim: note?.line.map { "\u{201C}\($0)\u{201D}" } ?? L("오늘 한마디가 아직 없어요"))
                .font(.system(size: 12, weight: note?.line == nil ? .regular : .medium))
                .foregroundStyle(note?.line == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            row("sparkles", L("오늘 운세"), note.map { r in
                let f = r.reading
                return String(repeating: "★", count: f.stars) + " " + f.headline
            })
            row("fork.knife", L("오늘 점심"), note?.lunch)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func row(_ icon: String, _ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            Text(verbatim: title).font(.system(size: 11, weight: .semibold)).frame(width: 52, alignment: .leading)
            Text(verbatim: value ?? L("아직 몰라요")).font(.system(size: 11)).foregroundStyle(value == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if !MAS
/// --render-friend-notes <폴더>: the profile card (full and empty), the pad, and a received doodle, light and dark.
enum FriendNotesQA {
    static func render(to dir: URL) throws {
        let day = WorkHours.day(Date())
        let smile: [[CGPoint]] = [
            (0..<24).map { i in let a = Double(i) / 23 * 2 * .pi; return CGPoint(x: 96 + 70 * cos(a), y: 96 + 70 * sin(a)) },
            [CGPoint(x: 70, y: 74), CGPoint(x: 70, y: 84)], [CGPoint(x: 122, y: 74), CGPoint(x: 122, y: 84)],
            (0..<12).map { i in let a = Double(i) / 11 * .pi; return CGPoint(x: 96 - 36 * cos(a), y: 112 + 24 * sin(a)) },
        ]
        let d = Doodle.pack(smile, in: CGSize(width: 192, height: 192))!
        let full = FriendCard(name: "보리", status: .off, note: FriendNote(day: day, line: L("오늘은 칼퇴 각, 다들 화이팅"), fortune: 1, lunch: "김치찌개"))
        let empty = FriendCard(name: "콩이", status: .working, note: nil)
        for (look, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try DashboardSnapshot.snapshot(FriendCardView(card: full, today: day), appearance: look, to: dir.appendingPathComponent("card-full-\(suffix).png"))
            try DashboardSnapshot.snapshot(FriendCardView(card: empty, today: day), appearance: look, to: dir.appendingPathComponent("card-empty-\(suffix).png"))
            try DashboardSnapshot.snapshot(DoodlePadView(send: { _ in true }, lines: smile), appearance: look,
                                           to: dir.appendingPathComponent("doodle-pad-\(suffix).png"))
        }
        try DashboardSnapshot.snapshot(DoodleNoteView(doodle: d, name: "보리").padding(10), appearance: .aqua,
                                       to: dir.appendingPathComponent("doodle-note.png"))
    }
}
#endif
