#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import AppKit
import SwiftUI

/// Latest 보안 점검 and its actions. Scans a few seconds after launch, then once a day (a single timer, no polling),
/// and when the owner presses 다시 검사.
@MainActor
final class SecurityCenter: ObservableObject {
    static let shared = SecurityCenter()
    @Published var report: SecurityReport?
    @Published private(set) var scanning = false
    @Published var note: String?
    @Published private(set) var busy: String?      // id of the row whose action is running
    private var timer: Timer?

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.scan() }
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            Task { @MainActor in SecurityCenter.shared.scan() }
        }
        timer?.tolerance = 3600
    }

    func scanIfNeeded() { if report == nil { scan() } }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            report = await Task.detached(priority: .utility) { SecurityScanner.scan() }.value
            scanning = false
        }
    }

    /// Runs one fix, then scans again so the page shows the new state.
    private func act(_ id: String, _ work: @escaping @MainActor () async -> String?) {
        guard busy == nil else { return }
        busy = id
        note = nil
        Task {
            note = await work()
            busy = nil
            scan()
        }
    }

    func toggle(_ i: LaunchItem) {
        if i.place == .userAgent {
            guard SecurityActions.confirmUser(i) else { return }
            act(i.id) { await Task.detached { SecurityActions.toggleUser(i) }.value }
        } else {
            act(i.id) { await SecurityActions.toggleAdmin(i) }
        }
    }

    func trash(_ a: AppFinding) { act(a.id) { await SecurityActions.trashApp(a) } }

    func updateXProtect() { act("xprotect") { await SecurityActions.updateXProtect() } }
}

/// "보안" page: macOS protections, launch items, unsigned apps, recent XProtect detections.
struct SecurityView: View {
    @ObservedObject var center: SecurityCenter
    let onBack: () -> Void

    var body: some View {
        PageScaffold(title: L("보안"), onBack: onBack, footer: AnyView(footer)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("실시간 백신이 아니라, macOS 기본 보호가 켜져 있는지와 악성코드가 숨기 쉬운 곳을 점검해요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                if let note = center.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Color.warn).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                if let r = center.report { sections(r) } else {
                    Panel {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("맥을 점검하는 중이에요").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }
        }
        .onAppear { center.scanIfNeeded() }
    }

    @ViewBuilder private func sections(_ r: SecurityReport) -> some View {
        title(L("기본 보호"))
        Panel {
            ForEach(Array(r.protections.enumerated()), id: \.element.id) { n, p in
                if n > 0 { Divider() }
                protectionRow(p)
            }
        }

        title(L("수상한 자동 실행 항목")).padding(.top, 4)
        Panel {
            if r.launchItems.isEmpty { empty(L("Apple 것 말고 등록된 자동 실행 항목이 없어요")) }
            ForEach(Array(r.launchItems.enumerated()), id: \.element.id) { n, i in
                if n > 0 { Divider() }
                launchRow(i)
            }
        }
        caption(L("~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons 에서 Apple 서명 항목을 뺀 것이에요. 끄기는 파일을 옮겨 두는 거라 다시 켤 수 있어요."))

        title(L("서명이 없는 앱")).padding(.top, 4)
        Panel {
            if r.apps.isEmpty { empty(L("응용 프로그램 폴더의 앱은 모두 서명돼 있어요")) }
            ForEach(Array(r.apps.enumerated()), id: \.element.id) { n, a in
                if n > 0 { Divider() }
                appRow(a)
            }
        }

        if let lines = r.detections {
            title(L("최근 차단 기록")).padding(.top, 4)
            Panel {
                if lines.isEmpty { empty(L("최근 7일 차단 기록 없음")) }
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func protectionRow(_ p: ProtectionRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            LevelIcon(level: p.level)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(.system(size: 12, weight: .medium))
                Text(p.line).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let button = p.button {
                if center.busy == p.id { ProgressView().controlSize(.small) } else {
                    Button(button) {
                        if let pane = p.pane { SecurityActions.open(pane) } else { center.updateXProtect() }
                    }
                    .controlSize(.small).disabled(center.busy != nil)
                }
            }
        }
    }

    private func launchRow(_ i: LaunchItem) -> some View {
        let flagged = i.level >= .warn || i.parked
        let system = i.place != .userAgent
        let hands = !i.label.hasPrefix("com.apple.")   // a com.apple name that is not Apple-signed: shown, never touched
        return HStack(alignment: .top, spacing: 8) {
            LevelIcon(level: i.parked ? .info : i.level)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(i.label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if i.mine { tag(L("내가 만든 항목"), .accentColor) }
                    if i.parked { tag(L("꺼 둠"), .secondary) }
                    if system { tag(i.place == .daemon ? L("시스템 데몬") : L("모든 사용자"), .secondary) }
                }
                Text(i.reason).font(.system(size: 11))
                    .foregroundStyle(i.parked ? Color.secondary : i.level == .danger ? Color.red : i.level == .warn ? Color.warn : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(i.signer + " · " + RunawayRules.pathHint(i.target)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if flagged && system {
                    HStack(spacing: 6) {
                        Button("Finder에서 보기") { SecurityActions.reveal(i.plist) }.controlSize(.small)
                        if !hands {
                        } else if center.busy == i.id { ProgressView().controlSize(.small) } else {
                            Button(i.parked ? "다시 켜기" : "관리자 권한으로 끄기") { center.toggle(i) }
                                .controlSize(.small).disabled(center.busy != nil)
                        }
                    }
                    .padding(.top, 2)
                    if !i.parked && hands {
                        Text("모든 사용자 항목이라 지우거나 끄려면 관리자 암호가 필요해요").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 4)
            if flagged && !system && !hands {
                Button("Finder에서 보기") { SecurityActions.reveal(i.plist) }.controlSize(.small)
            } else if flagged && !system {
                if center.busy == i.id { ProgressView().controlSize(.small) } else {
                    Button(i.parked ? "다시 켜기" : "끄기") { center.toggle(i) }.controlSize(.small).disabled(center.busy != nil)
                        .accessibilityLabel("\(i.label) \(i.parked ? L("다시 켜기") : L("끄기"))")
                }
            }
        }
        .help(i.plist)
    }

    private func appRow(_ a: AppFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(a.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    tag(a.level.label, a.level == .info ? .secondary : Color.warn)
                }
                Text(a.reason).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(a.signature.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if a.level >= .warn {
                if center.busy == a.id { ProgressView().controlSize(.small) } else {
                    Button("휴지통으로") { center.trash(a) }.controlSize(.small).disabled(center.busy != nil)
                }
            }
        }
        .help(a.path)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let r = center.report {
                Text("\(r.scannedAt.formatted(date: .omitted, time: .shortened)) 점검 · \(String(format: "%.1f", r.seconds))초")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if center.scanning { ProgressView().controlSize(.small) }
            Button("다시 검사") { center.scan() }.disabled(center.scanning || center.busy != nil)
        }
        .padding(.horizontal, 16)
    }

    private func title(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4)
    }

    private func caption(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
    }

    private func empty(_ t: String) -> some View { Text(t).font(.system(size: 12)).foregroundStyle(.secondary) }

    private func tag(_ t: String, _ color: Color) -> some View {
        Text(t).font(.system(size: 10, weight: .medium)).foregroundStyle(color).fixedSize()
    }
}

/// Status icon of one finding.
struct LevelIcon: View {
    let level: SecurityLevel
    var body: some View {
        let (symbol, color): (String, Color) = switch level {
        case .ok: ("checkmark.circle.fill", .green)
        case .info: ("info.circle.fill", .blue)
        case .warn: ("exclamationmark.triangle.fill", Color.warn)
        case .danger: ("xmark.octagon.fill", .red)
        }
        Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(color).frame(width: 18)
            .accessibilityLabel(level.label)
    }
}
#endif
