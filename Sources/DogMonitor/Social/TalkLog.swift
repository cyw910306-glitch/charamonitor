import AppKit
import SwiftUI

// 대화 모아보기: 근처 친구 chats and the 원격 모임 in one timeline, newest last. In memory unless 3일 보관 is on (off at
// first): then Application Support/DogMonitor/TalkLog.json, this Mac only, owner-read, lines older than 3 days dropped
// on every write and read. Never in 내 설정 파일, never sent anywhere. Key: talk.keep3d (OFF).

/// A 한마디 of mine on its way: 보내는 중, 보냄 (the relay has it) or 못 보냄 (다시 보내기 sends it under the same id).
enum TalkState: String, Codable { case pending, sent, failed }

struct TalkEntry: Codable, Identifiable, Equatable {
    static let meet = "meet"

    var id = UUID()
    var date = Date()
    /// `meet`, or a 근처 친구's id.
    var thread: String
    /// The sender's name as it came ("" for mine).
    var name: String
    var text: String
    var mine: Bool
    /// The app's own line (a dropped talk), not anyone's words.
    var note = false
    /// A 원격 모임 한마디's id (MeetEvent.id).
    var msgID: String?
    var state: TalkState?
}

/// What the file keeps. Pure, tested (RemoteMeetTests).
enum TalkFile {
    static let keepDays = 3
    static let keep = 300
    /// A bigger file is not read (300 full lines are well under it).
    static let maxBytes = 512 * 1024

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DogMonitor/TalkLog.json")
    }

    /// The last `keep` lines of the last 3 days.
    static func trimmed(_ all: [TalkEntry], now: Date) -> [TalkEntry] {
        let from = now.addingTimeInterval(-Double(keepDays) * 86400)
        return Array(all.filter { $0.date >= from && $0.date <= now.addingTimeInterval(60) }.suffix(keep))
    }

    /// The lines in `data`: none when too big or broken; text cut to 200, a 보내는 중 left from last time is 못 보냄.
    static func decode(_ data: Data, now: Date) -> [TalkEntry] {
        guard data.count <= maxBytes, let raw = try? JSONDecoder().decode([TalkEntry].self, from: data) else { return [] }
        return trimmed(raw.map { e in
            var e = e
            e.text = String(e.text.prefix(SocialText.maxChat))
            e.name = String(e.name.prefix(16))
            if e.state == .pending { e.state = .failed }
            return e
        }, now: now)
    }
}

final class TalkLog: ObservableObject {
    static let shared = TalkLog()
    static let keepKey = "talk.keep3d"

    @Published private(set) var entries: [TalkEntry] = []
    var defaults: UserDefaults = AppDefaults.store
    /// nil: never on disk (tests, QA renders).
    var url: URL? = TalkFile.defaultURL
    private var loaded = false

    var keeps: Bool { defaults.bool(forKey: Self.keepKey) }

    /// Call once at launch: the kept lines, when 3일 보관 is on.
    func start() {
        guard !loaded else { return }
        loaded = true
        guard keeps, let url, let d = try? Data(contentsOf: url) else { return }
        entries = TalkFile.decode(d, now: Date()) + entries
    }

    func add(_ e: TalkEntry) {
        entries = TalkFile.trimmed(entries + [e], now: Date())
        save()
    }

    func has(_ msgID: String) -> Bool { entries.contains { $0.msgID == msgID } }
    func state(_ msgID: String) -> TalkState? { entries.last { $0.msgID == msgID }?.state }

    func mark(_ msgID: String, _ state: TalkState) {
        guard let i = entries.lastIndex(where: { $0.msgID == msgID }), entries[i].state != state else { return }
        entries[i].state = state
        save()
    }

    /// 3일 보관 on writes what is in memory now; off deletes the file.
    func setKeeps(_ on: Bool) {
        defaults.set(on, forKey: Self.keepKey)
        if on { save() } else if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func save() {
        guard keeps, let url, let d = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? d.write(to: url, options: [.atomic])) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    #if !MAS
    /// QA renders: lines as they would be, no file.
    func qaShow(_ e: [TalkEntry]) {
        url = nil
        entries = e
    }
    #endif
}

/// The 대화 모아보기 window. While it is open the 원격 모임 polls fast.
enum RecentLog {
    private static var window: NSPanel?
    private static var closer: Closer?

    static func open() {
        RemoteMeet.shared.watch("recent", true)
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = L("대화 모아보기")
        w.contentView = NSHostingView(rootView: RecentLogView())
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.sharingType = .none   // friends' words stay out of screen shares
        let c = Closer()
        w.delegate = c
        closer = c
        window = w
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private final class Closer: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) { RemoteMeet.shared.watch("recent", false) }
    }
}

/// One timeline: day headings, then time, where (🌏 원격 모임 or the friend), who and what; mine show 보내는 중, 보냄 or
/// 못 보냄 with 다시 보내기. A 원격 모임 composer at the bottom while in a room (typing in it tells the room 입력 중).
struct RecentLogView: View {
    @ObservedObject var log: TalkLog = .shared
    @ObservedObject var meet: RemoteMeet = .shared
    /// A friend's name by id (QA passes its own).
    var name: (String) -> String = { SocialBus.shared.friend($0)?.nickname ?? L("친구") }
    /// QA renders: what the composer holds.
    var draft = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if log.entries.isEmpty {
                            Text(L("아직 기록이 없어요")).font(.system(size: 13, weight: .semibold)).padding(.vertical, 6)
                        }
                        ForEach(Array(log.entries.enumerated()), id: \.element.id) { i, e in
                            if i == 0 || !Calendar.current.isDate(e.date, inSameDayAs: log.entries[i - 1].date) { day(e.date) }
                            row(e).id(e.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: log.entries.last?.id) { last in if let last { proxy.scrollTo(last, anchor: .bottom) } }
            }
            if meet.isOn, meet.code != nil { composer }
            Toggle(L("3일 동안 이 맥에 보관"), isOn: Binding(get: { log.keeps }, set: { log.setKeeps($0); log.objectWillChange.send() }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            Text(log.keeps ? L("이 맥에만 3일 동안 남고 그보다 오래된 줄은 지워져요. 끄면 파일을 바로 지워요.")
                           : L("기록은 이 맥 메모리에만 있어서 앱을 끄면 사라져요."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(minWidth: 300, minHeight: 240)
        .onAppear { if text.isEmpty { text = draft } }
    }

    private func day(_ d: Date) -> some View {
        let label = Calendar.current.isDateInToday(d) ? L("오늘") : Calendar.current.isDateInYesterday(d) ? L("어제")
            : d.formatted(.dateTime.month().day().weekday(.abbreviated))
        return Text(verbatim: label).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.top, 6)
    }

    private func row(_ e: TalkEntry) -> some View {
        let place = e.thread == TalkEntry.meet ? "🌏 " + L("원격 모임") : "📶 " + name(e.thread)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: e.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                Text(verbatim: place).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Spacer(minLength: 0)
                if e.mine, let s = e.state { state(s, e) }
            }
            Text(verbatim: "\(e.mine ? L("나") : e.name.isEmpty ? name(e.thread) : e.name): \(e.text)")
                .font(.system(size: 12)).foregroundStyle(e.note ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(e.mine ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
    }

    @ViewBuilder private func state(_ s: TalkState, _ e: TalkEntry) -> some View {
        switch s {
        case .pending:
            Text(L("보내는 중")).font(.system(size: 10)).foregroundStyle(.secondary)
        case .sent:
            Label(L("보냄"), systemImage: "checkmark").font(.system(size: 10)).foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 4) {
                Label(L("못 보냄"), systemImage: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                Button(L("다시 보내기")) { _ = meet.sendLine(e.text, again: e.msgID) }.controlSize(.mini)
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextField(L("원격 모임에 한마디 (200자까지)"), text: $text).textFieldStyle(.roundedBorder).onSubmit(send)
                .onChange(of: text) { t in if !t.isEmpty { meet.typed() } }
            Text(verbatim: "\(MeetWire.chat(text).count)/\(MeetWire.maxChat)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            Button(L("보내기"), action: send).controlSize(.small).disabled(MeetWire.chat(text).isEmpty)
        }
    }

    private func send() { if meet.sendLine(text) { text = "" } }
}
