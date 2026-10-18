import XCTest
@testable import DogMonitor

/// The goals scheduler with a fake clock and fakes for every collaborator: no network, no AI, nothing executed.
@MainActor
final class GoalsTests: XCTestCase {
    var dir: URL!
    var store: GoalStore!
    var clock: Date!
    var priceQueue: [[GoalRunner.PriceItem]] = []
    var priceCalls = 0
    var plans: [Result<AgentPlan, Error>] = []
    var prompts: [(String, Origin)] = []
    var proposals: [AgentAction] = []
    var alerts: [GoalRunner.Alert] = []
    var runner: GoalRunner!

    /// 01:00 local on a fixed day, so 12 hourly runs stay inside one day.
    let base = Calendar.current.date(byAdding: .hour, value: 1, to: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)))!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("goals-\(UUID().uuidString)", isDirectory: true)
        store = GoalStore(root: dir)
        clock = base
        runner = GoalRunner(
            store: store,
            prices: { [unowned self] _ in priceCalls += 1; return priceQueue.isEmpty ? [] : priceQueue.removeFirst() },
            planner: { [unowned self] prompt, origin in
                prompts.append((prompt, origin))
                return try (plans.isEmpty ? .success(AgentPlan(say: "")) : plans.removeFirst()).get()
            },
            propose: { [unowned self] _, action in proposals.append(action); return UUID() },
            notify: { [unowned self] in alerts.append($0) },
            clock: { [unowned self] in clock })
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func agentGoal(_ title: String = "제주 항공권", every: Int = 60) -> Goal {
        let g = Goal(title: title, ownerWords: "\(title) 지켜봐 줘", kind: .agent(prompt: "\(title) 가격 확인"), everyMinutes: every, now: base)
        XCTAssertTrue(store.add(g))
        return g
    }

    func priceGoal(target: Int? = nil, drop: Int? = nil) -> Goal {
        let g = Goal(title: "하기스", ownerWords: "하기스 3만 원 아래면 알려줘", kind: .priceWatch(query: "하기스 4단계", target: target, dropPercent: drop),
                     everyMinutes: 60, now: base)
        XCTAssertTrue(store.add(g))
        return g
    }

    func item(_ price: Int) -> [GoalRunner.PriceItem] {
        [GoalRunner.PriceItem(title: "하기스", price: price + 500, mall: "B", url: nil),
         GoalRunner.PriceItem(title: "하기스 4단계", price: price, mall: "A", url: URL(string: "https://shopping.naver.com/x"))]
    }

    /// Advances the fake clock and ticks at that moment.
    @discardableResult
    func tick(after minutes: Int = 0) async -> UUID? {
        clock = clock.addingTimeInterval(Double(minutes) * 60)
        return await runner.tick(clock)
    }

    func testMinimumIntervalIsAnHour() {
        XCTAssertEqual(Goal(title: "t", ownerWords: "t", kind: .agent(prompt: "p"), everyMinutes: 5).everyMinutes, 60)
    }

    func testSerialOneGoalPerTick() async {
        let a = agentGoal("A"), b = agentGoal("B")
        let first = await tick()
        XCTAssertEqual(prompts.count, 1)
        let second = await tick(after: 1)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(Set([first, second].compactMap { $0 }), [a.id, b.id])
        let third = await tick(after: 1)
        XCTAssertNil(third, "both ran; neither is due again for an hour")
    }

    func testCatchUpAfterLongSleepRunsOnce() async {
        let g = agentGoal()
        await tick()
        XCTAssertEqual(prompts.count, 1)
        clock = clock.addingTimeInterval(10 * 3600)   // asleep for 10 hours: ten missed runs
        await runner.wake(clock)
        let woke = clock!
        await tick(after: 1)
        await tick(after: 1)
        XCTAssertEqual(prompts.count, 2, "ten missed hours collapse into one catch-up run")
        XCTAssertEqual(store.goal(g.id)?.nextRun, woke.addingTimeInterval(3600), "next run is an hour after the catch-up finished")
    }

    func testNextRunFromFinishTime() async {
        let g = agentGoal()
        runner = GoalRunner(store: store, prices: { _ in [] },
                            planner: { [unowned self] _, _ in clock = clock.addingTimeInterval(300); return AgentPlan(say: "") },
                            propose: { _, _ in UUID() }, notify: { _ in }, clock: { [unowned self] in clock })
        await runner.tick(base)
        XCTAssertEqual(store.goal(g.id)?.nextRun, base.addingTimeInterval(300 + 3600))
        XCTAssertEqual(store.goal(g.id)?.lastRun, base.addingTimeInterval(300))
    }

    func testRunsPerDay() async {
        let g = priceGoal(target: 1)
        for _ in 0..<14 { await tick(after: 60) }
        XCTAssertEqual(priceCalls, Goal.runsPerDay)
        XCTAssertEqual(store.goal(g.id)?.runsToday, 12)
        // The next local day starts a new count.
        clock = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: base))!.addingTimeInterval(60)
        await tick()
        XCTAssertEqual(priceCalls, 13)
        XCTAssertEqual(store.goal(g.id)?.runsToday, 1)
    }

    func testDailyModelCapAcrossGoals() async {
        for i in 0..<3 { _ = agentGoal("goal \(i)") }
        _ = priceGoal(target: 1)
        for _ in 0..<40 { await tick(after: 20) }   // 3 agent goals hourly would want ~39 runs in 13 hours
        XCTAssertEqual(prompts.count, GoalRunner.dailyModelCap)
        XCTAssertEqual(store.modelCalls(on: Goals.day(clock)), 24)
        XCTAssertGreaterThan(priceCalls, 0, "price watch uses no model, so the cap never stops it")
        XCTAssertTrue(prompts.allSatisfy { $0.1 == .background })
        // The count survives a restart.
        XCTAssertEqual(GoalStore(root: dir).modelCalls(on: Goals.day(clock)), 24)
    }

    func testPriceAlertOnlyOnNewLowAtOrBelowTarget() async {
        let g = priceGoal(target: 30_000)
        priceQueue = [item(32_000), item(30_000), item(30_000), item(31_000), item(29_000), item(29_000)]
        for _ in 0..<6 { await tick(after: 60) }
        XCTAssertEqual(alerts.map(\.kind), [.price, .price], "30,000 (at target) and 29,000 (a new low); repeats and rises stay quiet")
        XCTAssertEqual(alerts.first?.url, URL(string: "https://shopping.naver.com/x"))
        XCTAssertTrue(alerts.first?.text.contains("하기스 4단계") ?? false)
        XCTAssertEqual(store.goal(g.id)?.lastSeenLowest, 29_000)
        XCTAssertEqual(store.notes(g.id).all().filter { $0.contains("최저가") }.count, 6)
        XCTAssertEqual(prompts.count, 0, "price watch never calls the model")
    }

    func testDropPercent() {
        XCTAssertNil(GoalRunner.priceAlert(price: 30_000, previous: nil, target: nil, dropPercent: 10), "first sighting has nothing to drop from")
        XCTAssertNil(GoalRunner.priceAlert(price: 27_500, previous: 30_000, target: nil, dropPercent: 10))
        XCTAssertEqual(GoalRunner.priceAlert(price: 27_000, previous: 30_000, target: nil, dropPercent: 10), .drop)
        XCTAssertNil(GoalRunner.priceAlert(price: 27_000, previous: 27_000, target: 28_000, dropPercent: 10), "the same low alerts once")
        XCTAssertEqual(GoalRunner.priceAlert(price: 28_000, previous: nil, target: 28_000, dropPercent: nil), .target)
        // "내려가면 알려줘" with no number: any new low (review 2026-10-06).
        XCTAssertEqual(GoalRunner.priceAlert(price: 29_000, previous: 30_000, target: nil, dropPercent: nil), .drop)
        XCTAssertNil(GoalRunner.priceAlert(price: 30_000, previous: nil, target: nil, dropPercent: nil))
    }

    func testDropPercentThroughRunner() async {
        _ = priceGoal(drop: 10)
        // 27,500 is 8.3% under 30,000 and 26,000 is 3.7% under 27,000: quiet, but each new low is remembered.
        priceQueue = [item(30_000), item(35_000), item(27_500), item(27_000), item(26_000)]
        for _ in 0..<5 { await tick(after: 60) }
        XCTAssertEqual(alerts.count, 0)
        priceQueue = [item(23_000), item(23_000)]   // 11.5% under 26,000, then the same low again
        await tick(after: 60)
        await tick(after: 60)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(alerts[0].text.contains("10%"))
    }

    func testAgentGoalLeavesProposalAndWaitsNeverExecutes() async {
        let g = agentGoal()
        plans = [.success(AgentPlan(say: "진에어 2/10 왕복 18.9만 원, 어제보다 2만 원 내렸어요. 예매 준비할까요?",
                                    action: .flightSearch(FlightQuery(from: "GMP", to: "CJU", depart: base))))]
        await tick()
        XCTAssertEqual(prompts.first?.1, .background)
        XCTAssertTrue(prompts.first?.0.contains("제주 항공권 가격 확인") ?? false)
        XCTAssertEqual(proposals.count, 1, "the action went to the card sink")
        guard case .waiting(let card)? = store.goal(g.id)?.state else { return XCTFail("goal should wait on its card") }
        XCTAssertEqual(alerts.map(\.kind), [.checkIn])
        XCTAssertTrue(store.notes(g.id).tail(5).contains { $0.contains("비서: 진에어") })

        // While waiting it does not run again, however long the owner is away.
        await tick(after: 600)
        XCTAssertEqual(prompts.count, 1)
        store.cardResolved(card)
        await tick(after: 1)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].0.contains("제안 남김: flight_search"), "the notes tail carries what was already proposed")
    }

    func testCheckInsAtMostThreePerHour() async {
        let g = agentGoal()
        var goal = store.goal(g.id)!
        goal.checkIns = [clock, clock, clock].map { $0.addingTimeInterval(-600) }
        store.update(goal)
        plans = [.success(AgentPlan(say: "아직 그대로예요"))]
        await tick()
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertTrue(store.notes(g.id).all().contains { $0.contains("아직 그대로예요") }, "the say still goes to the notes")
    }

    func testUsageLimitPausesUntilResetOrAnHour() async {
        let g = agentGoal()
        plans = [.failure(ChatError.server("Claude AI usage limit reached|\(Int(base.timeIntervalSince1970) + 7200)"))]
        await tick()
        guard case .paused(_, let until?)? = store.goal(g.id)?.state else { return XCTFail("should pause") }
        XCTAssertEqual(until, base.addingTimeInterval(7200))
        XCTAssertEqual(alerts.map(\.kind), [.paused])
        await tick(after: 90)
        XCTAssertEqual(prompts.count, 1, "still paused")
        await tick(after: 31)
        XCTAssertEqual(prompts.count, 2, "resumed by itself after the reset")
        XCTAssertEqual(store.goal(g.id)?.state, .active)

        XCTAssertEqual(GoalRunner.limitReset(ChatError.rateLimited, now: base), base.addingTimeInterval(3600))
        XCTAssertEqual(GoalRunner.limitReset(ChatError.server("429 Too Many Requests"), now: base), base.addingTimeInterval(3600))
        XCTAssertNil(GoalRunner.limitReset(ChatError.network, now: base))
        let seven = GoalRunner.limitReset(ChatError.server("You've hit your limit · resets 7pm (Asia/Seoul)"), now: base)
        XCTAssertEqual(seven.map { Calendar.current.component(.hour, from: $0) }, 19)
        XCTAssertGreaterThan(seven!, base)
        let korean = GoalRunner.limitReset(ChatError.server("Claude 사용 한도에 도달했어요. 오후 4:30 이후에 다시 시도해 주세요."), now: base)
        XCTAssertEqual(korean.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }, DateComponents(hour: 16, minute: 30))
    }

    func testOwnerPauseResumeDelete() async {
        let g = agentGoal()
        store.pause(g.id, reason: "잠깐")
        await tick(after: 600)
        XCTAssertEqual(prompts.count, 0, "an owner pause has no end date")
        store.resume(g.id)
        plans = [.success(AgentPlan(say: "확인했어요"))]
        await tick()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertFalse(store.notes(g.id).all().isEmpty)
        store.delete(g.id)
        XCTAssertNil(store.goal(g.id))
        XCTAssertTrue(store.notes(g.id).all().isEmpty)
        XCTAssertTrue(GoalStore(root: dir).list().isEmpty)
    }

    func testStoreCapAndReload() {
        for i in 0..<10 {
            XCTAssertTrue(store.add(Goal(title: "g\(i)", ownerWords: "", kind: .agent(prompt: ""), now: base.addingTimeInterval(Double(i)))))
        }
        XCTAssertFalse(store.add(Goal(title: "11", ownerWords: "", kind: .agent(prompt: ""))))
        XCTAssertEqual(GoalStore(root: dir).list().count, 10)
        XCTAssertEqual(GoalStore(root: dir).list().map(\.title), (0..<10).map { "g\($0)" }, "reloads in creation order")
    }

    func testNotesCap() {
        let notes = GoalNotes(url: dir.appendingPathComponent("n.notes.md"))
        for i in 0..<400 { notes.append("최저가 \(i)원 · 네이버 · 꽤 긴 상품 이름이 여기에 들어가요", now: base) }
        let size = (try? Data(contentsOf: notes.url).count) ?? 0
        XCTAssertLessThanOrEqual(size, GoalNotes.cap)
        XCTAssertGreaterThan(size, GoalNotes.cap - 200)
        XCTAssertTrue(notes.tail(1)[0].hasSuffix("최저가 399원 · 네이버 · 꽤 긴 상품 이름이 여기에 들어가요"), "newest kept")
        XCTAssertFalse(notes.all().contains { $0.contains("최저가 0원") }, "oldest dropped")
        XCTAssertEqual(notes.tail(3).count, 3)
        XCTAssertTrue(notes.tail(1)[0].hasPrefix(Goals.stamp(base)))
    }

    func testOwnerMemoryVisibility() {
        let url = dir.appendingPathComponent("profile.json")
        let memory = OwnerMemory(url: url)
        memory.add(key: "배송지", value: "집")
        let seat = memory.add(key: "좌석", value: "창가", showToAI: false)
        memory.add(key: "배송지", value: "회사")
        XCTAssertEqual(memory.entries.count, 2, "the same key replaces")
        XCTAssertEqual(memory.linesForAI, ["배송지: 회사"])
        memory.edit(seat.id, showToAI: true)
        XCTAssertEqual(memory.linesForAI, ["배송지: 회사", "좌석: 창가"])
        memory.edit(seat.id, value: "통로")
        memory.delete(memory.entries[0].id)
        XCTAssertEqual(OwnerMemory(url: url).linesForAI, ["좌석: 통로"])
    }
}
