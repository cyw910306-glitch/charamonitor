import ActivityKit
import CharaCore
import SwiftUI
import UserNotifications

/// The 집중 타이머 run, kept in the app group so it outlives the app: start, stop, and the minutes it adds up today.
/// It also runs the Live Activity and the "done" notification.
enum FocusStore {
    static var minutes: Int { Shared.defaults.integer(forKey: SharedState.focusMinutesKey) }

    static func start(_ minutes: Int, art: CharaArt) {
        let end = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
        Shared.defaults.set(end, forKey: SharedState.focusEndKey)
        Shared.defaults.set(minutes, forKey: SharedState.focusMinutesKey)
        let title = L("집중 \(minutes)분")
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            let attributes = CharaActivityAttributes(characterID: art.id, title: title, startDate: .now, endDate: end)
            _ = try? Activity.request(attributes: attributes, content: .init(state: .init(pose: DogPose.walk.rawValue), staleDate: end))
        }
        guard !UserDefaults.standard.bool(forKey: "qaNoAsk") else { return }   // QA screenshots: no permission alert
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = L("집중 끝!")
            content.body = art.persona().dress(L("\(minutes)분 동안 정말 잘했어요. 잠깐 쉬어요"))
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
            center.add(UNNotificationRequest(identifier: "focus", content: content, trigger: trigger))
        }
        SharedState.changed()
    }

    /// Stops the run; `done` (it reached its end) counts its minutes on the day it ended.
    static func stop(done: Bool) {
        if done, let end = SharedState.focusEnd { add(minutes, on: end) }
        Shared.defaults.removeObject(forKey: SharedState.focusEndKey)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["focus"])
        Task {
            for a in Activity<CharaActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: done ? .default : .immediate)
            }
        }
        SharedState.changed()
    }

    /// A run that ended while the app was away is finished now (the app calls this whenever it comes forward).
    static func finishIfDone(_ now: Date = .now) {
        if let end = SharedState.focusEnd, end <= now { stop(done: true) }
    }

    static func minutesToday() -> Int {
        Shared.defaults.string(forKey: SharedState.focusDayKey) == FocusTalk.day(.now) ? Shared.defaults.integer(forKey: SharedState.focusTodayKey) : 0
    }

    static func add(_ m: Int, on date: Date) {
        let kept = (Shared.defaults.string(forKey: SharedState.focusDayKey) ?? "", Shared.defaults.integer(forKey: SharedState.focusTodayKey))
        let t = FocusTalk.tally(m, on: FocusTalk.day(date), kept: kept)
        Shared.defaults.set(t.minutes, forKey: SharedState.focusTodayKey)
        Shared.defaults.set(t.day, forKey: SharedState.focusDayKey)
    }
}

struct FocusView: View {
    @Environment(AppModel.self) private var model
    @State private var end = SharedState.focusEnd
    @State private var feel = 0
    @AppStorage(SharedState.hapticsKey, store: Shared.defaults) private var haptics = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        dial(at: context.date)
                    }
                    .card(padding: 24)

                    if end == nil {
                        HStack(spacing: 12) {
                            startButton(25, note: "한 번 집중")
                            startButton(50, note: "깊게 집중")
                        }
                    } else {
                        Button(role: .destructive) {
                            FocusStore.stop(done: false)
                            end = nil
                            feel += 1
                        } label: {
                            Text("그만하기").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                    }

                    Text("잠금 화면과 다이내믹 아일랜드에서도 남은 시간이 보여요")
                        .font(.footnote).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                }
                .padding(16)
            }
            .background(Palette.bg.ignoresSafeArea())
            .navigationTitle("집중 타이머")
            .sensoryFeedback(trigger: feel) { _, _ in haptics ? .success : nil }
            .task(id: end) {
                FocusStore.finishIfDone()
                end = SharedState.focusEnd
                guard let e = end else { return }
                try? await Task.sleep(for: .seconds(max(0, e.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                FocusStore.finishIfDone()
                end = SharedState.focusEnd
                feel += 1
            }
            .onAppear {
                let m = UserDefaults.standard.integer(forKey: "qaFocus")   // QA screenshots: a run going
                if end == nil, m > 0 { start(m) }
            }
        }
    }

    @ViewBuilder
    private func dial(at now: Date) -> some View {
        let total = TimeInterval(max(1, FocusStore.minutes) * 60)
        let left = end.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        let progress = end == nil ? 0 : 1 - left / total
        let hour = Calendar.current.component(.hour, from: now)
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Palette.soft, lineWidth: 14)
                Circle().trim(from: 0, to: progress)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 6) {
                    let pose: DogPose = end == nil ? .lying : .slowWalk
                    let count = max(1, model.chosen.frames(pose).count)
                    FrameImage(art: model.chosen, pose: pose, index: Int(now.timeIntervalSinceReferenceDate / model.chosen.seconds(pose)) % count, playing: true)
                        .frame(width: 136, height: 80)
                    Text(verbatim: end == nil ? "--:--" : FocusTalk.clock(left))
                        .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Palette.ink)
                }
            }
            .frame(width: 250, height: 250)
            .accessibilityElement(children: .combine)
            Text(verbatim: end == nil ? L("\(model.chosen.displayName)랑 같이 집중해 봐요") : FocusTalk.mood(left: left, total: total, hour: hour))
                .font(.headline).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
            Text("오늘 \(FocusStore.minutesToday())분 집중했어요").font(.subheadline).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func startButton(_ minutes: Int, note: LocalizedStringKey) -> some View {
        Button { start(minutes) } label: {
            VStack(spacing: 2) {
                Text("\(minutes)분").font(.title2.bold())
                Text(note).font(.caption).opacity(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .foregroundStyle(Palette.onPrimary)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).tint(Palette.primary)
    }

    private func start(_ minutes: Int) {
        FocusStore.start(minutes, art: model.chosen)
        end = SharedState.focusEnd
        feel += 1
    }
}
