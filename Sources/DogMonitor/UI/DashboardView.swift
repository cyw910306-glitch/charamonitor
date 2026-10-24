import AppKit
import SwiftUI

/// Pages of the popover. Everything is navigated inside the same popover.
/// `editor` opens a saved custom character by id (rename, new pictures, delete).
/// `preview` shows an original character's motions by OriginalCatalog id.
enum DashboardPage: Equatable {
    case main, dog, customize, settings, cleaner, security, creator, editor(UUID), preview(String)
    case pet, assistant
}

/// Popover content: dog header, a stats panel on the left and a column of tile buttons on the right.
struct DashboardView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: AppSettings
    let onQuit: () -> Void
    @State private var page: DashboardPage
    @StateObject private var sprites = SpriteHolder()
    #if !MAS   // the App Store build has no 보안 점검 and no self-updater (docs/appstore/review-notes.md)
    @ObservedObject private var security = SecurityCenter.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var drift = DriftCenter.shared
    #endif

    init(monitor: SystemMonitor, settings: AppSettings, onQuit: @escaping () -> Void) {
        self.init(monitor: monitor, settings: settings, onQuit: onQuit, startPage: .main)
    }

    /// `startPage` lets the QA snapshot open a sub page directly.
    init(monitor: SystemMonitor, settings: AppSettings, onQuit: @escaping () -> Void, startPage: DashboardPage) {
        self.monitor = monitor
        self.settings = settings
        self.onQuit = onQuit
        _page = State(initialValue: startPage)
    }

    var body: some View {
        Group {
            switch page {
            case .main: dashboard
            case .dog:
                DogPickerView(settings: settings, sprites: sprites, onCreate: { page = .creator }, onEdit: { page = .editor($0) },
                              onPreview: { page = .preview($0) }) {
                    page = .main
                }
            case .preview(let id):
                if let c = OriginalCatalog.character(id) {
                    // With its 꾸미기 colours, as it will look in the menu bar.
                    CharacterPreviewView(settings: settings, character: CharacterColors.apply(settings.characterColors[id], to: c)) { page = .dog }.id(id)
                } else {
                    Color.clear.onAppear { page = .dog }
                }
            case .customize:
                if let custom = settings.activeCustom {
                    CharacterCreatorView(settings: settings, editing: custom) { page = .main }.id(custom.id)
                } else {
                    CustomizeView(settings: settings, sprites: sprites, load: monitor.load) { page = .main }
                }
            case .creator: CharacterCreatorView(settings: settings, editing: nil) { page = .dog }
            case .editor(let id):
                if let custom = CustomCharacterStore.shared.character(id.uuidString) {
                    CharacterCreatorView(settings: settings, editing: custom) { page = .dog }.id(id)
                } else {
                    Color.clear.onAppear { page = .dog }
                }
            case .settings: SettingsView(settings: settings, available: sprites.cache(for: settings).availableExtras) { page = .main }
            #if MAS
            case .cleaner, .security: Color.clear.onAppear { page = .main }
            #else
            case .cleaner: CleanerView(monitor: monitor) { page = .main }
            case .security: SecurityView(center: security) { page = .main }
            #endif
            case .pet: PetHomeView(monitor: monitor, settings: settings) { page = .main }
            case .assistant:
                AssistantView(monitor: monitor, settings: settings, onBack: { page = .main },
                              startOnSettings: PopoverMemory.shared.assistantSettings)
            }
        }
        .frame(width: 400)
        .onChange(of: page) { p in   // reopening the popover soon comes back here (PopoverMemory)
            PopoverMemory.shared.page = p
            if p != .assistant { PopoverMemory.shared.assistantSettings = false }
        }
    }

    private var dashboard: some View {
        VStack(spacing: 10) {
            header
            #if !MAS
            if let m = updater.available { updateLine(m) }
            if security.report?.needsAttention == true { securityLine }
            if isBusy { busyBanner }
            if drift.on || drift.withTimer { DriftSummaryRow() }
            #endif
            HStack(alignment: .top, spacing: 10) {
                statsPanel
                buttons.frame(width: 96)
            }
            .fixedSize(horizontal: false, vertical: true)   // lets the tile column match the panel height
        }
        .padding(12)
    }

    // MARK: Header

    private var header: some View {
        let pose = DogPose.forCPU(monitor.load)
        let character = settings.shownCharacter
        let name = settings.characterName
        return HStack(spacing: 12) {
            if character == .dog { DogPhoto(path: settings.photoPath, size: 46) }   // the photo is of the dog
            VStack(alignment: .leading, spacing: 3) {
                (Text(name).fontWeight(.bold) + Text(" · \(pose.label)").foregroundColor(.secondary))
                    .font(.system(size: 15))
                    .lineLimit(1)
                if let s = monitor.snapshot {
                    HStack(spacing: 6) {
                        Text("켜진 지 \(Fmt.uptime(s.uptime))").foregroundStyle(.secondary).monospacedDigit()
                        if RestartAdvice.recommend(uptime: s.uptime, swapUsed: s.memory.swapUsed, pressure: s.memory.pressureLevel) {
                            Label("재시동 권장", systemImage: "arrow.clockwise").foregroundStyle(Color.warn)
                        }
                        // Heat already has its own label below; only name memory as the reason.
                        if pose != .lying, monitor.loadCause == .memory, let why = monitor.loadCause.reason {
                            Label(why, systemImage: "memorychip").foregroundStyle(Color.warn)
                        }
                        if let heat = thermalText(s.thermalState) {
                            Label(heat, systemImage: "thermometer.medium").foregroundStyle(Color.warn)
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            let cache = sprites.cache(for: settings)
            if let motion = StatusItemController.playing, cache.frames(forExtra: motion) != nil {
                let frames = cache.frames(for: pose, extra: motion, variant: StatusItemController.playingTake)
                FramesPlayer(frames: frames, size: cache.imageSize, every: DogSpriteCache.extraFrameDuration(StatusItemController.playing),
                             smooth: cache.smooth)
            } else {
                AnimatedDog(cache: cache, pose: pose, cpu: monitor.load)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    /// Memory is tight or the CPU is past 60%: point at the cleaner. Memory as the load cause counts only
    /// once the dog is up (the header's gate), since on an idle Mac a tiny memory score already beats the CPU.
    private var isBusy: Bool {
        let level = (monitor.memory ?? monitor.snapshot?.memory)?.pressureLevel ?? .normal
        let memoryLoad = monitor.loadCause == .memory && DogPose.forCPU(monitor.load) != .lying
        return memoryLoad || level != .normal || monitor.cpuUsage > 0.6
    }

    private var busyBanner: some View {
        Button { page = .cleaner } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("맥이 바빠요 · 클리너로 정리하기").fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.warn)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    #if !MAS
    /// A newer signed build is on the site: open 설정 and start the install there, where the progress shows.
    private func updateLine(_ m: UpdateManifest) -> some View {
        Button {
            page = .settings
            updater.install()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle.fill")
                Text("새 버전 \(m.version) 나왔어요 · 업데이트").fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(.blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.blue.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The latest 보안 점검 found a 위험 item or a key protection off.
    private var securityLine: some View {
        Button { page = .security } label: {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.shield.fill")
                Text("보안 점검이 필요해요").fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    #endif

    // MARK: Stats panel

    private var statsPanel: some View {
        VStack(spacing: 0) {
            if let s = monitor.snapshot {
                cpuSection(s.cpu)
                Divider().padding(.horizontal, 12)
                memorySection(s.memory)
                if let d = s.disk {
                    Divider().padding(.horizontal, 12)
                    diskSection(d)
                }
                if let b = s.battery {
                    Divider().padding(.horizontal, 12)
                    batterySection(b)
                }
                Divider().padding(.horizontal, 12)
                networkSection(s.network)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func cpuSection(_ c: CPUStats) -> some View {
        StatSection(symbol: "cpu", title: "CPU: \(Fmt.percent1(c.usage))") {
            Text("시스템: \(Fmt.percent1(c.system))")
            Text("사용자: \(Fmt.percent1(c.user))")
            Text("대기: \(Fmt.percent1(c.idle))")
            Sparkline(values: monitor.cpuHistory, maxValue: 1, color: .blue)
                .frame(height: 20)
                .padding(.top, 4)
        }
    }

    private func memorySection(_ m: MemoryStats) -> some View {
        let used = m.total > 0 ? Double(m.used) / Double(m.total) : 0
        return StatSection(symbol: "memorychip", title: L("메모리: \(Fmt.percent1(min(1, used)))")) {
            Text("압력: \(Fmt.percent1(m.pressure))")
                .foregroundStyle(m.pressureLevel == .critical ? Color.red : m.pressureLevel == .warning ? Color.warn : Color.secondary)
            Text("앱 메모리: \(Fmt.mem(m.app))")
            Text("와이어드 메모리: \(Fmt.mem(m.wired))")
            Text("압축됨: \(Fmt.mem(m.compressed))")
        }
    }

    private func diskSection(_ d: DiskStats) -> some View {
        let used = d.total > 0 ? Double(d.used) / Double(d.total) : 0
        return StatSection(symbol: "internaldrive", title: L("저장 용량: \(Fmt.percent1(used)) 사용됨")) {
            Text("\(Fmt.disk(d.used)) / \(Fmt.disk(d.total))")
            FillBar(fraction: used, color: used > 0.9 ? .red : .blue)
                .padding(.top, 4)
        }
        .help(d.volumeName)
    }

    private func batterySection(_ b: BatteryStats) -> some View {
        let level = b.levelPrecise ?? Double(b.percent)
        let health = b.healthPrecise ?? b.healthPercent.map(Double.init)
        return StatSection(symbol: batterySymbol(b, level: level), title: L("배터리: \(String(format: "%.1f%%", level))")) {
            Text("전원 공급원: \(b.isPluggedIn ? L("전원 어댑터") : L("배터리"))")
            if let health { Text("성능 최대치: \(String(format: "%.1f%%", health))") }
            if let c = b.cycleCount { Text("사이클 수: \(c)") }
            if let t = b.temperatureCelsius { Text("온도: \(String(format: "%.1f°C", t))") }
            if let extra = batteryStatus(b) { Text(extra) }
        }
    }

    private func networkSection(_ n: NetworkStats) -> some View {
        let primary = n.interfaces.first   // the sampler lists the primary interface first
        return StatSection(symbol: "globe", title: L("네트워크: \(primary?.displayName ?? L("연결 안 됨"))")) {
            Text("로컬 IP: \(primary?.ipv4 ?? L("없음"))")
            Text("업로드: \(Fmt.rate(n.uploadBytesPerSec))")
            Text("다운로드: \(Fmt.rate(n.downloadBytesPerSec))")
            SpeedRow()
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        VStack(spacing: 8) {
            #if !MAS
            TileButton(symbol: "sparkles", title: L("클리너")) { page = .cleaner }
            TileButton(symbol: "shield.lefthalf.filled", title: L("보안")) { page = .security }
            #endif
            TileButton(symbol: "person.crop.square", title: L("캐릭터 선택")) { page = .dog }
            TileButton(symbol: "square.and.pencil", title: L("꾸미기")) { page = .customize }
            TileButton(symbol: "house", title: L("펫 키우기")) { page = .pet }
            TileButton(symbol: "bubble.left.and.bubble.right", title: L("AI 비서")) { page = .assistant }
            TileButton(symbol: "waveform.path.ecg", title: L("활성 상태 보기"), action: openActivityMonitor)
            TileButton(symbol: "gearshape", title: L("설정")) { page = .settings }
            TileButton(symbol: "ellipsis", title: L("더보기")) { MoreMenu.show(onCheckUpdate: checkUpdate, onQuit: onQuit) }
        }
    }

    // MARK: Helpers

    private func batterySymbol(_ b: BatteryStats, level: Double) -> String {
        if b.isCharging { return "battery.100.bolt" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    /// Short extra line: charging state or time left, nil when there is nothing useful to say.
    private func batteryStatus(_ b: BatteryStats) -> String? {
        if b.isCharged { return L("충전 완료") }
        if b.isCharging { return b.minutesRemaining.map { L("충전 중 · \(Fmt.duration(minutes: $0)) 남음") } ?? L("충전 중") }
        if b.isPluggedIn { return nil }
        return b.minutesRemaining.map { L("남은 시간: \(Fmt.duration(minutes: $0))") }
    }

    private func thermalText(_ t: ProcessInfo.ThermalState) -> String? {
        switch t {
        case .fair: return L("조금 따뜻해요")
        case .serious: return L("뜨거워요")
        case .critical: return L("아주 뜨거워요")
        default: return nil
        }
    }

    /// The App Store updates the App Store build: no 업데이트 확인 there.
    private var checkUpdate: (() -> Void)? {
        #if MAS
        return nil
        #else
        return {
            page = .settings
            Updater.shared.check(manual: true)
        }
        #endif
    }

    private func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        External.openApp(at: url)
    }
}

/// "더보기" pop-up menu: 업데이트 확인, 정보 and 종료.
private enum MoreMenu {
    private final class Item: NSMenuItem {
        private let run: () -> Void
        init(_ title: String, key: String = "", run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: key)
            target = self
        }
        required init(coder: NSCoder) { fatalError("not used") }
        @objc private func fire() { run() }
    }

    

    static func show(onCheckUpdate: (() -> Void)?, onQuit: @escaping () -> Void) {
        let menu = NSMenu()
        if let onCheckUpdate { menu.addItem(Item(L("업데이트 확인"), run: onCheckUpdate)) }
        menu.addItem(Item(L("정보")) { showAbout() })
        menu.addItem(.separator())
        menu.addItem(Item(L("종료"), key: "q", run: onQuit))
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: L("캐릭모니터"),
            .applicationVersion: AppInfo.version,
            // The license and its Required Notice travel with every copy (PolyForm Noncommercial, Notices).
            .credits: NSAttributedString(string: L("무료 오픈 소스") + "\nPolyForm Noncommercial 1.0.0\n" + AppInfo.licenseURL.absoluteString
                                             + "\n" + AppInfo.requiredNotice + "\n" + AppInfo.repoURL.absoluteString,
                                         attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]),
        ])
    }
}
