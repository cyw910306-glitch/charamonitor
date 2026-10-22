import CharaCore
import SwiftUI
import UIKit

/// The chosen character big on a soft meadow, doing what the phone is doing; under it the battery, the storage and today.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var shown = false
    @State private var battery = Battery.read()
    @State private var storage = Storage.read()
    @State private var hour = Calendar.current.component(.hour, from: .now)

    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        let idle = Idle.now(battery: battery.level, charging: battery.charging, hour: hour)
        let focused = FocusStore.minutesToday()
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date.now.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
                    Text(verbatim: FocusTalk.today(hour: hour, focused: focused))
                        .font(.title2.bold()).foregroundStyle(Palette.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

                Stage(art: model.chosen, idle: idle)

                HStack(spacing: 12) {
                    BatteryCard(battery: battery)
                    StorageCard(storage: storage)
                }
                .fixedSize(horizontal: false, vertical: true)   // both cards as tall as the taller
                Label("톡 누르면 반응하고, 꾹 누르면 쓰다듬어요", systemImage: "hand.tap")
                    .font(.footnote).foregroundStyle(Palette.muted)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 16)
        }
        .background(Palette.bg.ignoresSafeArea())
        .onAppear { shown = true; monitorBattery(true) }
        .onDisappear { shown = false; monitorBattery(false) }
        .onChange(of: phase) { monitorBattery(shown && phase == .active) }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in batteryChanged() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in batteryChanged() }
        .onReceive(tick) { _ in
            hour = Calendar.current.component(.hour, from: .now)
            storage = Storage.read()
            FocusStore.finishIfDone()
        }
    }
}

extension HomeView {
    /// Battery monitoring only while home shows (it costs a little power).
    private func monitorBattery(_ on: Bool) {
        UIDevice.current.isBatteryMonitoringEnabled = on
        if on { battery = Battery.read() }
    }

    private func batteryChanged() {
        battery = Battery.read()
        SharedState.saveBattery()   // so the widgets' saved battery stays fresh
        SharedState.changed()
    }
}

// MARK: The stage

/// The character on its meadow. Tap: a reaction, a line, a cry and a tap you feel (3 in a row = dizzy, 5 = pout).
/// Long press: petted, with hearts.
struct Stage: View {
    let art: CharaArt
    let idle: Idle

    @State private var combo = TapCombo()
    @State private var playing: (reaction: Reaction, start: Date)?
    @State private var bubble: Bubble?
    @State private var marks: [Mark] = []
    @State private var feel = 0
    @State private var feelKind: SensoryFeedback = .impact(weight: .light)
    /// A reaction or its hearts are moving: draw smoothly until `busyUntil`, else only as often as the frames change.
    @State private var busy = false
    @State private var busyUntil = Date.distantPast
    @AppStorage(SharedState.hapticsKey, store: Shared.defaults) private var haptics = true

    struct Bubble: Equatable { let id = UUID(); let text: String }
    struct Mark: Identifiable { let id = UUID(); let text: String; let start: Date; let dx: CGFloat }

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Palette.sky, Palette.soft], startPoint: .top, endPoint: .bottom)
                    .overlay(alignment: .bottom) {   // an overlay: the wide hill never widens the stage
                        Ellipse().fill(Palette.ground).frame(width: 560, height: 150).offset(y: 80)
                    }
                TimelineView(.animation(minimumInterval: busy || idle == .sleepy ? 1 / 30 : max(0.05, art.seconds(idle.pose, extra: idle.extra)))) { context in
                    character(at: context.date)
                }
                .frame(height: 230)
                .padding(.bottom, 26)
                if let bubble {
                    Text(verbatim: bubble.text)
                        .font(.callout.weight(.medium)).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: Palette.ink.opacity(0.12), radius: 8, y: 3)
                        .frame(maxWidth: 270)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 16)
                        .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                        .id(bubble.id)
                }
            }
            .frame(height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            .onLongPressGesture(minimumDuration: 0.45, perform: pet)
            .sensoryFeedback(trigger: feel) { _, _ in haptics ? feelKind : nil }
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: "\(art.displayName), \(idle.label)"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("쓰다듬기"), pet)
            .task(id: busyUntil) {
                guard busy else { return }
                try? await Task.sleep(for: .seconds(max(0, busyUntil.timeIntervalSinceNow)))
                if !Task.isCancelled { busy = false }
            }
            .task(id: bubble) {
                guard bubble != nil else { return }
                try? await Task.sleep(for: .seconds(2.8))
                withAnimation(.easeOut(duration: 0.25)) { bubble = nil }
            }

            VStack(spacing: 2) {
                Text(verbatim: art.displayName).font(.title3.bold()).foregroundStyle(Palette.ink)
                Text(verbatim: idle.label).font(.subheadline).foregroundStyle(Palette.muted)
            }
        }
        .task {
            while UserDefaults.standard.bool(forKey: "qaPet") {   // QA screenshots: always a bubble and hearts
                pet()
                try? await Task.sleep(for: .seconds(0.8))
            }
        }
    }

    @ViewBuilder
    private func character(at now: Date) -> some View {
        let active = playing.flatMap { now.timeIntervalSince($0.start) < $0.reaction.duration ? $0 : nil }
        let t = active.map { now.timeIntervalSince($0.start) } ?? 0
        let move = (active?.reaction ?? .pout).pose(active == nil ? -1 : t)
        let extra = active.map { $0.reaction.extra } ?? idle.extra
        let pose = active == nil ? idle.pose : .walk
        let count = max(1, art.frames(pose, extra: extra).count)
        let seconds = max(0.05, art.seconds(pose, extra: extra))
        let index = Int(now.timeIntervalSinceReferenceDate / seconds) % count
        let size = CGSize(width: 34 * 8, height: 20 * 8)
        ZStack(alignment: .bottom) {
            Ellipse().fill(Palette.ink.opacity(0.10))
                .frame(width: size.width * 0.55 * (1 - move.lift * 0.6), height: 16)
                .offset(y: 6)
            FrameImage(art: art, pose: pose, extra: extra, index: index, playing: true)
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: move.sx, y: move.sy, anchor: .bottom)
                .rotationEffect(.radians(move.angle), anchor: active?.reaction == .spin ? .center : .bottom)
                .offset(y: -move.lift * size.height)
            ForEach(marks) { mark in
                let u = now.timeIntervalSince(mark.start) / 1.1
                if u < 1 {
                    Text(verbatim: mark.text)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(mark.text == "♥" ? Color.pink : Palette.accent)
                        .opacity(u < 0.15 ? u / 0.15 : 1 - (u - 0.15) / 0.85)
                        .offset(x: mark.dx, y: -size.height - 10 - u * 70)
                }
            }
            if idle == .sleepy && active == nil {
                let u = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                Text(verbatim: "z z")
                    .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Palette.muted)
                    .opacity(1 - u)
                    .offset(x: 70, y: -size.height * 0.6 - u * 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func tap() {
        let r = combo.tap(at: ProcessInfo.processInfo.systemUptime)
        play(r, line: r.lines.randomElement()!)
        feelKind = switch r {
        case .dizzy: .impact(weight: .medium)
        case .pout: .warning
        default: .impact(weight: .light)
        }
        feel += 1
    }

    private func pet() {
        play(.blush, line: Reaction.petLines.randomElement()!)
        let now = Date.now
        marks += (0..<5).map { i in Mark(text: "♥", start: now.addingTimeInterval(Double(i) * 0.12), dx: CGFloat(i - 2) * 26) }
        feelKind = .impact(flexibility: .soft, intensity: 0.8)
        feel += 1
    }

    private func play(_ r: Reaction, line: String) {
        let now = Date.now
        playing = (r, now)
        busy = true
        busyUntil = now.addingTimeInterval(max(r.duration, 1.7))   // the hearts float 1.1 s, the last starts 0.48 s in
        marks.removeAll { now.timeIntervalSince($0.start) > 1.2 }
        if let m = r.mark { marks.append(Mark(text: m, start: now, dx: 0)) }
        let own = r.extra.map { art.lines($0) } ?? []
        withAnimation(.spring(duration: 0.3, bounce: 0.4)) {
            bubble = Bubble(text: art.persona().dress(own.randomElement() ?? line))
        }
        CrySound.play(r, art: art)
    }
}

// MARK: Status cards

struct Battery {
    /// 0...1, nil when the phone does not say (the simulator).
    var level: Double?
    var state: UIDevice.BatteryState

    var charging: Bool { state == .charging }

    static func read() -> Battery {
        let d = UIDevice.current
        return Battery(level: d.batteryLevel < 0 ? nil : Double(d.batteryLevel), state: d.batteryState)
    }

    var stateText: String {
        switch state {
        case .charging: L("충전 중이에요")
        case .full: L("꽉 찼어요")
        case .unplugged: level.map { $0 <= Idle.lowBattery } == true ? L("충전이 필요해요") : L("배터리로 쓰는 중")
        default: L("알 수 없어요")
        }
    }

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch level ?? 1 {
        case ..<0.2: return "battery.0percent"
        case ..<0.5: return "battery.25percent"
        case ..<0.8: return "battery.50percent"
        default: return "battery.100percent"
        }
    }
}

struct Storage {
    var free: Int64, total: Int64

    static func read() -> Storage {
        let v = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return Storage(free: v?.volumeAvailableCapacityForImportantUsage ?? 0, total: Int64(v?.volumeTotalCapacity ?? 0))
    }
}

struct BatteryCard: View {
    let battery: Battery

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("배터리", systemImage: battery.symbol)
                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
            Text(verbatim: battery.level.map { "\(Int(($0 * 100).rounded()))%" } ?? "-")
                .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                .monospacedDigit()
            Text(verbatim: battery.stateText).font(.footnote).foregroundStyle(Palette.muted)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

struct StorageCard: View {
    let storage: Storage

    var body: some View {
        let used = storage.total > 0 ? Double(storage.total - storage.free) / Double(storage.total) : 0
        VStack(alignment: .leading, spacing: 6) {
            Label("저장 공간", systemImage: "internaldrive")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
            Text(verbatim: storage.free.formatted(.byteCount(style: .file)))
                .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                .minimumScaleFactor(0.6).lineLimit(1)
            ProgressView(value: used).tint(Palette.accent)
            Text("전체 \(storage.total.formatted(.byteCount(style: .file))) 중 남은 공간")
                .font(.footnote).foregroundStyle(Palette.muted).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}
