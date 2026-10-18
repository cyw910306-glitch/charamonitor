#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import AppKit
import SwiftUI

/// What one press of 정리하기 did.
struct CleanerResult: Equatable {
    var quit: [String]
    var asked: [String]        // still running after 5 s: a save dialog is probably up
    var freed: UInt64
    var trashEmptied: Bool
    var memoryBefore: UInt64?
    var memoryAfter: UInt64?
    var skipped: [String] = []  // already gone when we asked, or refused the quit request
    var stopped: [String] = []  // runaway processes that ended after SIGTERM
    var stubborn: [String] = [] // still running 5 s after SIGTERM (never escalated to SIGKILL)
}

/// Scan, picks and the clean itself. Lives as long as the cleaner page.
@MainActor
final class CleanerModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, ready, cleaning, done(CleanerResult) }

    @Published var phase = Phase.idle
    @Published private(set) var apps: [CleanerCandidate] = []
    @Published private(set) var files: [CleanTarget]?   // nil while sizes are still being counted
    @Published var pickedApps: Set<pid_t> = []
    @Published var pickedFiles: Set<CleanTarget.Kind> = []
    @Published private(set) var runaways: [RunawayCandidate] = []
    @Published var pickedRunaways: Set<ProcKey> = []
    @Published var pickedModules: Set<String> = []    // node_modules paths, never pre-picked
    @Published var showModules = false
    @Published private(set) var agents: [LaunchAgent] = []
    @Published var agentNote: String?
    @Published private(set) var busyAgent: String?     // plist whose launchctl call is running
    /// QA renders: draw the restart card with these numbers instead of the Mac's own.
    var restartSample: (uptime: TimeInterval, swap: UInt64)?
    @Published private(set) var protected = CleanerProtection.load()

    /// QA renders hand in a finished scan so the page draws without waiting.
    func show(_ scan: CleanerScan) {
        apps = scan.apps
        files = scan.files
        pickedApps = Set(scan.apps.filter(\.recommended).map(\.id))
        pickedFiles = Set(scan.files.filter { $0.recommended && $0.blocked == nil }.map(\.kind))
        pickedModules = []
        agents = scan.agents
        runaways = scan.runaways
        pickedRunaways = []
        phase = .ready
    }

    func scan() {
        phase = .scanning
        files = nil
        let refs = Cleaner.runningApps()
        let tracker = ActivityTracker.shared
        let launch = tracker.launch, frontmost = tracker.lastOtherFrontmost, own = Bundle.main.bundleIdentifier
        let running = Cleaner.runningIDs()
        // Runaways are never pre-picked; the rules run off the main thread (launchctl, code signatures).
        let context = RunawayTracker.shared.context(), histories = RunawayTracker.shared.histories
        runaways = []
        pickedRunaways = []
        Task {
            runaways = await Task.detached { RunawayTracker.offer(histories, context) }.value
            let measured = await Task.detached { Cleaner.measure(refs, ourLaunch: launch) }.value
            apps = CleanerRules.candidates(measured, protected: protected, frontmost: frontmost, own: own)
            pickedApps = Set(apps.filter(\.recommended).map(\.id))
            phase = .ready
            let (found, agentList) = await Task.detached {
                let paths = Array(Cleaner.processPaths().values)
                return (Cleaner.scanFiles(home: FileManager.default.homeDirectoryForCurrentUser, runningIDs: running,
                                          xcodeRunning: CleanerRules.xcodeBusy(runningIDs: running, processPaths: paths),
                                          processPaths: paths), LaunchAgents.scan())
            }.value
            files = found
            pickedFiles = Set(found.filter { $0.recommended && $0.blocked == nil }.map(\.kind))
            pickedModules = []
            agents = agentList
        }
    }

    /// Locking an app also takes it out of the picks; unlocking does not pick it.
    func toggleProtection(_ c: CleanerCandidate) {
        let id = c.app.bundleID
        if protected.contains(id) { protected.remove(id) } else { protected.insert(id); pickedApps.remove(c.id) }
        CleanerProtection.save(protected)
        apps = apps.map { var x = $0; x.isProtected = protected.contains(x.app.bundleID); return x }
    }

    var hasPicks: Bool { !pickedApps.isEmpty || !pickedFiles.isEmpty || !pickedRunaways.isEmpty || !pickedModules.isEmpty }

    /// Picked file groups; node_modules narrowed to the projects ticked one by one.
    var chosenFiles: [CleanTarget] {
        (files ?? []).compactMap { t in
            guard t.blocked == nil else { return nil }
            guard t.kind == .nodeModules else { return pickedFiles.contains(t.kind) ? t : nil }
            var t = t
            t.projects = t.projects.filter { pickedModules.contains($0.modules) }
            t.paths = t.projects.map(\.modules)
            t.bytes = t.projects.map(\.bytes).reduce(0, +)
            return t.paths.isEmpty ? nil : t
        }
    }

    /// 끄기 / 다시 켜기 on one launch agent. Separate from 정리하기 and reversible. 끄기 asks first.
    func toggleAgent(_ a: LaunchAgent) {
        guard busyAgent == nil, a.disabled || confirmDisable(a) else { return }
        busyAgent = a.id
        Task {
            let dir = LaunchAgents.userDir
            let (note, list) = await Task.detached {
                (a.disabled ? LaunchAgents.enable(a, dir: dir, run: Shell.run) : LaunchAgents.disable(a, dir: dir, run: Shell.run),
                 LaunchAgents.scan())
            }.value
            agentNote = note
            agents = list
            busyAgent = nil
        }
    }

    private func confirmDisable(_ a: LaunchAgent) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("\(a.label) 을(를) 끌까요?")
        alert.informativeText = L("\(a.when) \(RunawayRules.pathHint(a.program)) 을(를) 실행하는 항목이에요.")
            + (a.mine ? L(" 내가 만든 항목이에요. 이 작업이 멈춰도 괜찮은지 확인해 주세요.") : "")
            + (a.pid > 0 ? L(" 지금 실행 중이라 끝난 뒤에 끌 수 있어요.") : "")
            + L(" 끄면 보관 폴더(LaunchAgents 안)에 옮겨 두어서 다시 켜기로 되돌릴 수 있어요.")
        alert.addButton(withTitle: L("끄기"))
        alert.addButton(withTitle: L("취소"))
        NSApp.activate(ignoringOtherApps: true)
        return PopoverLayer.runModal { alert.runModal() } == .alertFirstButtonReturn
    }

    /// What one press will do, so picks below the fold are not a surprise.
    var summary: String {
        let quit = apps.filter { pickedApps.contains($0.id) && !$0.isProtected }.count
        guard files != nil else { return L("앱 \(quit)개 종료 · 파일 크기를 세는 중") }
        let chosen = chosenFiles
        var parts = [L("앱 \(quit)개 종료"), L("파일 \(Fmt.size(chosen.compactMap(\.bytes).reduce(0, +))) 정리")]
        if chosen.contains(where: { $0.kind == .trash }) { parts.append(L("휴지통 비움")) }
        let stops = runaways.filter { pickedRunaways.contains($0.id) }.count
        if stops > 0 { parts.insert(L("프로세스 \(stops)개 멈춤"), at: 1) }
        return parts.joined(separator: " · ")
    }

    func clean(monitor: SystemMonitor) {
        let targets = apps.filter { pickedApps.contains($0.id) && !$0.isProtected }.map(\.app)
        let chosen = chosenFiles
        let before = (monitor.memory ?? monitor.snapshot?.memory)?.used
        phase = .cleaning
        Task {
            // terminate() only: the app gets a normal quit request and can ask to save. Never forced.
            var pending: [(CleanerApp, NSRunningApplication)] = [], skipped: [String] = []
            for app in targets {
                guard let running = NSRunningApplication(processIdentifier: app.pid),
                      running.bundleIdentifier == app.bundleID, !running.isTerminated, running.terminate() else {
                    skipped.append(app.name); continue
                }
                pending.append((app, running))
            }
            // Runaways get SIGTERM only, and only if pid, start time and executable are still the ones shown.
            let stop = RunawayStop.send(runaways.filter { pickedRunaways.contains($0.id) },
                                        identify: RunawayTracker.identify, signal: { Darwin.kill($0, $1) })
            skipped += stop.skipped.map(\.name)
            let deadline = Date().addingTimeInterval(5)
            while pending.contains(where: { !$0.1.isTerminated })
                    || !RunawayStop.stillAlive(stop.sent, identify: RunawayTracker.identify).isEmpty, Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let quit = pending.filter { $0.1.isTerminated }.map(\.0.name)
            let asked = pending.filter { !$0.1.isTerminated }.map(\.0.name)
            let stubborn = RunawayStop.stillAlive(stop.sent, identify: RunawayTracker.identify)
            let stopped = stop.sent.filter { !stubborn.contains($0) }.map(\.name)

            // Apps may have started since the scan: check the caches and DerivedData again right before deleting.
            let runningNow = Cleaner.runningIDs()
            var freed = await Task.detached {
                Cleaner.delete(CleanerRules.recheck(chosen, runningIDs: runningNow,
                                                    processPaths: Array(Cleaner.processPaths().values),
                                                    tools: Cleaner.toolProcs()))
            }.value
            var trashEmptied = false
            if let trash = chosen.first(where: { $0.kind == .trash }) {
                trashEmptied = PermissionFlow.hold { Cleaner.emptyTrash() }   // first time: macOS asks for Finder automation
                if trashEmptied { freed += trash.bytes ?? 0 }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // let the freed memory show up
            let after = monitor.sampleNow().memory.used
            phase = .done(CleanerResult(quit: quit, asked: asked, freed: freed, trashEmptied: trashEmptied,
                                        memoryBefore: before, memoryAfter: after, skipped: skipped,
                                        stopped: stopped, stubborn: stubborn.map(\.name)))
            PetSignals.shared.send(.cleaned(bytes: freed))
        }
    }
}

/// "클리너" page: quit idle apps and clear old files with one press of 정리하기.
struct CleanerView: View {
    @ObservedObject var monitor: SystemMonitor
    let onBack: () -> Void
    @StateObject private var model: CleanerModel

    /// `model` lets the QA render hand in a finished scan; the app always starts a fresh one.
    init(monitor: SystemMonitor, model: CleanerModel? = nil, onBack: @escaping () -> Void) {
        self.monitor = monitor
        self.onBack = onBack
        _model = StateObject(wrappedValue: model ?? CleanerModel())
    }

    var body: some View {
        PageScaffold(title: L("클리너"), onBack: onBack, footer: AnyView(footer)) {
            VStack(alignment: .leading, spacing: 8) {
                switch model.phase {
                case .idle, .scanning: working(L("맥을 살펴보는 중이에요"))
                case .cleaning: working(L("정리하는 중이에요. 앱이 저장을 물으면 답해 주세요"))
                case .ready: lists
                case .done(let r): resultCard(r)
                }
            }
        }
        .onAppear { if model.phase == .idle { model.scan() } }
    }

    // MARK: Lists

    @ViewBuilder private var lists: some View {
        restartCard
        sectionTitle(L("안 쓰는 앱 종료"), picked: model.pickedApps.count)
        Panel {
            if model.apps.isEmpty {
                Text("지금 켜진 다른 앱이 없어요").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(model.apps.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Divider() }
                appRow(c)
            }
        }
        Text("30분 넘게 안 쓴 앱, 10분 넘게 안 쓰면서 CPU를 30% 넘게 쓰는 앱을 골라 뒀어요. 자물쇠를 누르면 보호돼요.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)

        sectionTitle(L("폭주 프로세스"), picked: model.pickedRunaways.count).padding(.top, 4)
        Panel {
            if model.runaways.isEmpty {
                Text("CPU를 붙잡고 도는 백그라운드 프로세스가 없어요").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(model.runaways.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Divider() }
                runawayRow(r)
            }
        }
        Text("3분 넘게 CPU를 절반 넘게 쓰는 백그라운드 프로세스예요. 앱·터미널·Claude Code·로그인 항목이 띄운 건 빼요. 켜 둔 서비스일 수 있어 미리 골라 두지 않아요. 고르면 종료 요청만 보내요.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)

        sectionTitle(L("정리할 파일"), picked: model.pickedFiles.count + model.pickedModules.count).padding(.top, 4)
        Panel {
            if let files = model.files {
                if files.isEmpty { Text("정리할 파일이 없어요").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(Array(files.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { Divider() }
                    fileRow(t)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("크기를 세는 중이에요").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        if model.files != nil { agentSection }
    }

    // MARK: Login and background items

    @ViewBuilder private var agentSection: some View {
        sectionTitle(L("로그인·백그라운드 항목"), picked: nil).padding(.top, 4)
        Panel {
            if model.agents.isEmpty {
                Text("내가 설치한 백그라운드 항목이 없어요").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(model.agents.enumerated()), id: \.element.id) { i, a in
                if i > 0 { Divider() }
                agentRow(a)
            }
            if let note = model.agentNote {
                Text(note).font(.system(size: 11)).foregroundStyle(Color.warn).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button {
                if let url = URL(string: LaunchAgents.loginItemsURL) { External.open(url) }
            } label: {
                Label("시스템 설정에서 로그인 항목 열기", systemImage: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
        }
        Text("~/Library/LaunchAgents 에 있는 항목이에요. 끄기 전에 한 번 물어보고, 실행 중인 항목은 끝난 뒤에 꺼요. 끄면 보관 폴더에 옮겨 두어서 다시 켤 수 있어요. 정리하기에는 안 들어가요. 앱이 등록한 로그인 항목은 시스템 설정에서 봐요.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func agentRow(_ a: LaunchAgent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: a.disabled ? "moon.zzz" : "gearshape.2").font(.system(size: 14))
                .foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(a.label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if a.mine {
                        Text("내가 만든 항목").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor)
                            .fixedSize()
                    }
                }
                Text(a.state + " · " + a.when + " · " + RunawayRules.pathHint(a.program))
                    .font(.system(size: 11)).foregroundStyle(a.pid > 0 && !a.disabled ? Color.warn : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if model.busyAgent == a.id {
                ProgressView().controlSize(.small)
            } else {
                Button(a.disabled ? "다시 켜기" : "끄기") { model.toggleAgent(a) }.controlSize(.small)
                    .disabled(model.busyAgent != nil || (a.pid > 0 && !a.disabled))
                    .help(a.pid > 0 && !a.disabled ? L("지금 실행 중이라 끝난 뒤에 끌 수 있어요") : a.plist)
                    .accessibilityLabel("\(a.label) \(a.disabled ? L("다시 켜기") : L("끄기"))")
            }
        }
        .help(a.plist)
    }

    private func sectionTitle(_ title: String, picked: Int?) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let picked { Text("\(picked)개 선택").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 4)
    }

    private func appRow(_ c: CleanerCandidate) -> some View {
        HStack(spacing: 8) {
            Toggle(c.app.name, isOn: pick(c.id, in: \.pickedApps)).toggleStyle(.checkbox).labelsHidden()
                .disabled(c.isProtected)
            Image(nsImage: NSWorkspace.shared.icon(forFile: c.app.path)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(CleanerText.appLine(c.app)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.toggleProtection(c) } label: {
                Image(systemName: c.isProtected ? "lock.fill" : "lock.open")
                    .foregroundStyle(c.isProtected ? Color.accentColor : Color.secondary.opacity(0.6))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(c.isProtected ? "보호 풀기" : "보호하기(종료 안 함)")
            .accessibilityLabel(c.isProtected ? "\(c.app.name) 보호 풀기" : "\(c.app.name) 보호하기")
        }
        .opacity(c.isProtected ? 0.7 : 1)
    }

    /// Shown only when RestartAdvice says so: a long uptime with swap grown, or two weeks on.
    @ViewBuilder private var restartCard: some View {
        let uptime = model.restartSample?.uptime ?? monitor.snapshot?.uptime ?? Sysctl.uptime()
        if let m = monitor.memory ?? monitor.snapshot?.memory {
            let swap = model.restartSample?.swap ?? m.swapUsed
            if RestartAdvice.recommend(uptime: uptime, swapUsed: swap, pressure: m.pressureLevel) { restartPanel(uptime, swap) }
        }
    }

    private func restartPanel(_ uptime: TimeInterval, _ swap: UInt64) -> some View {
        Panel {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle").font(.system(size: 18)).foregroundStyle(Color.warn)
                Text(RestartAdvice.text(uptime: uptime, swapUsed: swap)).font(.system(size: 12))
                    .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("재시동…") { RestartAdvice.confirmAndRestart() }.controlSize(.small)
            }
        }
    }

    private func runawayRow(_ r: RunawayCandidate) -> some View {
        HStack(spacing: 8) {
            Toggle(r.name, isOn: pick(r.id, in: \.pickedRunaways)).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: "flame").font(.system(size: 15)).foregroundStyle(Color.warn).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(r.name).font(.system(size: 12, weight: .medium))
                    Text(RunawayRules.pathHint(r.path)).font(.system(size: 11)).foregroundStyle(.secondary).truncationMode(.middle)
                }
                .lineLimit(1)
                Text(RunawayRules.why(r)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .help(r.path)
    }

    private func fileRow(_ t: CleanTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if t.kind == .nodeModules {
                        // Mixed when only some projects are ticked; on picks every project, off clears them.
                        Toggle(t.title, sources: t.projects.map { pick($0.modules, in: \.pickedModules) }, isOn: \.self)
                    } else {
                        Toggle(t.title, isOn: pick(t.kind, in: \.pickedFiles))
                    }
                }
                .toggleStyle(.checkbox).labelsHidden().disabled(t.blocked != nil)
                Image(systemName: t.symbol).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.system(size: 12, weight: .medium))
                    Text(t.blocked ?? t.detail).font(.system(size: 11))
                        .foregroundStyle(t.blocked == nil ? Color.secondary : Color.warn)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let b = t.bytes { Text(sizeLabel(t, total: b)).font(.system(size: 12)).monospacedDigit() }
            }
            .opacity(t.blocked == nil ? 1 : 0.6)
            if t.kind == .nodeModules {
                DisclosureGroup(isExpanded: $model.showModules) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(t.projects) { p in projectRow(p) }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("프로젝트 \(t.projects.count)개 보기 · 하나씩 고를 수 있어요").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.leading, 30)
            }
        }
    }

    private func projectRow(_ p: NodeProject) -> some View {
        HStack(spacing: 6) {
            Toggle(p.name, isOn: pick(p.modules, in: \.pickedModules)).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 0) {
                Text(p.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(CleanerText.lastUsed(p.lastUsed)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            Text(Fmt.size(p.bytes)).font(.system(size: 11)).monospacedDigit()
        }
        .help(p.project)
    }

    /// node_modules with only some projects ticked shows "picked / total".
    private func sizeLabel(_ t: CleanTarget, total: UInt64) -> String {
        guard t.kind == .nodeModules else { return Fmt.size(total) }
        let picked = t.projects.filter { model.pickedModules.contains($0.modules) }
        guard !picked.isEmpty, picked.count < t.projects.count else { return Fmt.size(total) }
        return "\(Fmt.size(picked.map(\.bytes).reduce(0, +))) / \(Fmt.size(total))"
    }

    private func pick<ID: Hashable>(_ id: ID, in set: ReferenceWritableKeyPath<CleanerModel, Set<ID>>) -> Binding<Bool> {
        Binding(get: { model[keyPath: set].contains(id) },
                set: { on in if on { model[keyPath: set].insert(id) } else { model[keyPath: set].remove(id) } })
    }

    // MARK: States

    private func working(_ text: String) -> some View {
        Panel {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    private func resultCard(_ r: CleanerResult) -> some View {
        Panel {
            Label("정리했어요", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
            resultLine(L("종료한 앱"), r.quit.isEmpty ? L("없음") : L("\(r.quit.count)개 · \(r.quit.joined(separator: ", "))"))
            if !r.asked.isEmpty {
                resultLine(L("확인 창이 떴어요"), L("\(r.asked.joined(separator: ", ")) (저장 안 한 문서가 있을 수 있어요)"))
                    .foregroundStyle(Color.warn)
            }
            if !r.stopped.isEmpty {
                resultLine(L("멈춘 프로세스"), L("\(r.stopped.count)개 · \(r.stopped.joined(separator: ", "))"))
            }
            if !r.stubborn.isEmpty {
                resultLine(L("아직 도는 프로세스"), L("\(r.stubborn.joined(separator: ", ")) (종료 요청을 받지 않았어요. 강제로 끄지는 않아요)"))
                    .foregroundStyle(Color.warn)
            }
            if !r.skipped.isEmpty {
                resultLine(L("종료하지 않았어요"), L("\(r.skipped.joined(separator: ", ")) (이미 꺼졌거나 요청을 받지 않았어요)"))
            }
            resultLine(L("확보한 공간"), String(format: "%.2f GB", Double(r.freed) / 1e9) + (r.trashEmptied ? L(" · 휴지통 비움") : ""))
            if let b = r.memoryBefore, let a = r.memoryAfter {
                resultLine(L("메모리 사용"), "\(Fmt.mem(b)) → \(Fmt.mem(a))")
            }
        }
    }

    private func resultLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        VStack(spacing: 5) {
            if case .done = model.phase {
                Button { model.scan() } label: { Text("다시 검사").frame(maxWidth: .infinity) }
                    .controlSize(.large)
            } else {
                Button { model.clean(monitor: monitor) } label: {
                    Label("정리하기", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(model.phase != .ready || model.files == nil || !model.hasPicks)
                Text(model.summary).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
                Text("한 번 더 누르는 건 저장 안 한 작업을 지키기 위해서예요")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.9)
            }
        }
        .padding(.horizontal, 12)
    }
}
#endif
