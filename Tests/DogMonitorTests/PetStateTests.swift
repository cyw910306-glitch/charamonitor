import XCTest
@testable import DogMonitor

/// 펫 키우기 rules: gauges and signals, offline cap, 가출, level and evolution, coins, missions, 출석, focus, diary, room.
final class PetStateTests: XCTestCase {
    /// Noon on a fixed day, so day boundaries are a whole number of days away.
    private let t0: Date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
    private func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }
    private func battery(_ percent: Int, charging: Bool = false, plugged: Bool = false) -> BatteryStats {
        BatteryStats(percent: percent, isCharging: charging, isPluggedIn: plugged || charging, isCharged: false,
                     minutesRemaining: nil, cycleCount: nil, healthPercent: nil)
    }
    private func fresh() -> PetState {
        var s = PetState(now: t0)
        s.adopted = true
        return s
    }

    // MARK: Gauges

    func testGaugesDecayPerHour() {
        var s = fresh()
        var e: [PetEvent] = []
        s.advance(to: at(2), events: &e)
        XCTAssertEqual(s.food, 80 - 10, accuracy: 0.001)
        XCTAssertEqual(s.mood, 80 - 8, accuracy: 0.001)
        XCTAssertEqual(s.energy, 80 - 6, accuracy: 0.001)
        XCTAssertEqual(s.clean, 80 - 5, accuracy: 0.001)
    }

    func testOfflineDecayIsCappedAtTwelveHours() {
        var a = fresh(), b = fresh()
        var e: [PetEvent] = []
        a.advance(to: at(12), events: &e)
        b.advance(to: at(40), events: &e)
        XCTAssertEqual(a.food, b.food, accuracy: 0.001)
        XCTAssertEqual(b.food, 80 - 60, accuracy: 0.001)
        XCTAssertEqual(b.mood, 80 - 48, accuracy: 0.001)
    }

    func testTimeGoingBackwardsIsTakenAndTimeFlowsOnFromThere() {
        var s = fresh()
        var e: [PetEvent] = []
        XCTAssertEqual(s.advance(to: at(-1), events: &e), 0)
        XCTAssertEqual(s.food, 80, "no decay for a clock set back")
        XCTAssertEqual(s.updated, at(-1))
        // A year ahead once, then set right: the gauges keep decaying from the real time.
        var y = fresh()
        y.advance(to: at(24 * 365), events: &e)
        let futureDay = y.today.day
        y.advance(to: t0, events: &e)
        XCTAssertEqual(y.updated, t0)
        let before = y.food
        y.advance(to: at(2), events: &e)
        XCTAssertEqual(y.food, max(0, before - 10), accuracy: 0.001)
        XCTAssertEqual(y.today.day, futureDay, "the day only moves forward")
        XCTAssertLessThanOrEqual(y.lastCare, at(2))
    }

    func testDateTogglingPaysNothingTwice() {
        var s = fresh()
        var e: [PetEvent] = []
        s.attend(t0, events: &e)
        let coins = s.coins
        for i in 0..<10 {
            _ = s.apply(.sample(battery: nil, load: 0, idle: 5), now: at(24 + Double(i) / 60))   // tomorrow
            _ = s.apply(.sample(battery: nil, load: 0, idle: 5), now: at(Double(i) / 60))        // back to today
        }
        XCTAssertEqual(s.coins, coins + 12, "tomorrow's 출석 once (streak 2), nothing for going back and forth")
    }

    func testClockJumpOverAFocusPaysNothing() {
        var s = fresh()
        s.startFocus(now: t0)
        var e: [PetEvent] = []
        s.advance(to: t0.addingTimeInterval(60), events: &e)
        s.advance(to: t0.addingTimeInterval(25 * 60 + 5), events: &e)   // the clock moved 24 minutes in one step
        XCTAssertNil(s.focus)
        XCTAssertFalse(e.contains(.focusDone(coins: 15)))
        // Set back far: a timer ending more than 25 minutes away is dropped.
        var b = fresh()
        b.startFocus(now: t0)
        b.advance(to: at(-1), events: &e)
        XCTAssertNil(b.focus)
    }

    func testOldOrNewerSavesStillLoad() throws {
        var s = fresh()
        _ = s.care(.feed, now: t0)
        s.coins = 321
        s.level = 7
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        json.removeValue(forKey: "eyeRest")                  // a field this version adds
        json["hat"] = "crown"                               // a field a newer version adds
        json["slots"] = [NSNull()]                          // too few slots
        var today = try XCTUnwrap(json["today"] as? [String: Any])
        today["done"] = ["breaks", "juggling"]              // a mission that no longer exists
        today["counts"] = ["juggling", 4, "feed", 1]
        json["today"] = today
        json["focus"] = ["mode": "nap", "endsAt": 0]        // an unknown focus mode
        let loaded = try JSONDecoder().decode(PetState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.coins, 321)
        XCTAssertEqual(loaded.level, 7)
        XCTAssertEqual(loaded.slots.count, PetState.slotCount)
        XCTAssertEqual(loaded.today.done, [.breaks])
        XCTAssertEqual(loaded.today[.feed], 1)
        XCTAssertNil(loaded.focus)
        XCTAssertFalse(loaded.eyeRest)
    }

    func testAnUnreadableSaveIsKeptAside() {
        let suite = "pet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let junk = Data("{\"food\": 1}".utf8)
        d.set(junk, forKey: PetModel.key)
        XCTAssertNil(PetModel.load(d))
        XCTAssertEqual(d.data(forKey: PetModel.corruptKey), junk)
    }

    func testGaugeDriftIsNotWrittenEverySample() {
        let suite = "pet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let model = PetModel(defaults: d, signals: PetSignals())
        model.adopt()
        let saved = d.data(forKey: PetModel.key)
        model.state.food -= 0.5   // what a sample does
        XCTAssertEqual(d.data(forKey: PetModel.key), saved, "drift waits for the next write")
        model.state.coins += 1
        XCTAssertEqual(PetModel.load(d), model.state, "a real change is written at once, drift included")
    }

    func testGaugesStayInRange() {
        var s = fresh()
        for i in 0..<10 { _ = s.care(.feed, now: at(Double(i) / 100)) }
        XCTAssertEqual(s.food, 100)
        var e: [PetEvent] = []
        s.advance(to: at(30), events: &e)
        s.advance(to: at(60), events: &e)
        XCTAssertGreaterThanOrEqual(s.clean, 0)
    }

    // MARK: Signals

    func testChargingFeedsButOnlyOverTheLiveMinute() {
        var s = fresh()
        _ = s.apply(.sample(battery: battery(50, charging: true), load: 0, idle: 0), now: at(1 / 60))   // 1 minute later
        // 1 minute: -5/60 decay, +25/60 from charging.
        XCTAssertEqual(s.food, 80 + 20.0 / 60, accuracy: 0.001)
        var long = fresh()
        _ = long.apply(.sample(battery: battery(50, charging: true), load: 0, idle: 0), now: at(10))
        // 10 h offline decay, but charging counts for one minute only.
        XCTAssertEqual(long.food, 80 - 50 + 25.0 / 60, accuracy: 0.001)
    }

    func testLowBatteryDoublesHunger() {
        var low = fresh(), ok = fresh()
        _ = low.apply(.sample(battery: battery(15), load: 0, idle: 0), now: at(1 / 60))
        _ = ok.apply(.sample(battery: battery(60), load: 0, idle: 0), now: at(1 / 60))
        XCTAssertEqual(80 - low.food, 2 * (80 - ok.food), accuracy: 0.0001)
        var plugged = fresh()
        _ = plugged.apply(.sample(battery: battery(15, plugged: true), load: 0, idle: 0), now: at(1 / 60))
        XCTAssertEqual(plugged.food, ok.food, accuracy: 0.0001)
    }

    func testBusyTiresAndIdleRests() {
        var busy = fresh(), calm = fresh(), rest = fresh()
        _ = busy.apply(.sample(battery: nil, load: 0.9, idle: 0), now: at(1 / 60))
        _ = calm.apply(.sample(battery: nil, load: 0.3, idle: 0), now: at(1 / 60))
        _ = rest.apply(.sample(battery: nil, load: 0, idle: 600), now: at(1 / 60))
        XCTAssertLessThan(busy.energy, calm.energy)
        XCTAssertGreaterThan(rest.energy, calm.energy)
    }

    func testABreakCountsOncePerIdleStretch() {
        var s = fresh()
        var t = 0.0
        func sample(_ idle: TimeInterval) { t += 10.0 / 3600; _ = s.apply(.sample(battery: nil, load: 0, idle: idle), now: at(t)) }
        sample(0)
        for i in 0..<5 { sample(300 + Double(i) * 10) }   // one long break
        XCTAssertEqual(s.today[.breaks], 1)
        sample(120)   // between: still away, no new break, no reset
        sample(400)
        XCTAssertEqual(s.today[.breaks], 1)
        sample(0)     // back at the keys
        sample(310)   // the next break
        XCTAssertEqual(s.today[.breaks], 2)
    }

    func testCleanerAndSpeedTest() {
        var s = fresh()
        s.clean = 20
        _ = s.apply(.cleaned(bytes: 2_000_000_000), now: t0)
        XCTAssertEqual(s.clean, 50, accuracy: 0.001)   // 10 + 2 GB × 10
        _ = s.apply(.cleaned(bytes: 50_000_000_000), now: t0)
        XCTAssertEqual(s.clean, 90, accuracy: 0.001)   // capped at +40
        s.mood = 50
        _ = s.apply(.speedTest, now: t0)
        XCTAssertEqual(s.mood, 65, accuracy: 0.001)
        XCTAssertEqual(s.today[.cleaner], 2)
        XCTAssertEqual(s.today[.speedTest], 1)
    }

    func testHungryIsSaidOncePerHungerSpell() {
        var s = fresh()
        s.food = 26
        var e: [PetEvent] = []
        s.advance(to: at(0.5), events: &e)
        XCTAssertEqual(e, [.hungry])
        e = []
        s.advance(to: at(1), events: &e)
        XCTAssertFalse(e.contains(.hungry))
        _ = s.care(.feed, now: at(1.1))
        _ = s.care(.feed, now: at(1.2))
        XCTAssertFalse(s.hungryNoted)
    }

    // MARK: 가출

    func testGoesForAWalkAfterThreeDaysWithAnEmptyBowl() {
        var s = fresh()
        s.food = 5
        var e: [PetEvent] = []
        s.advance(to: at(71), events: &e)
        XCTAssertFalse(s.isAway)
        s.advance(to: at(72), events: &e)
        XCTAssertTrue(s.isAway)
        XCTAssertTrue(e.contains(.wentAway))
        // Out: gauges stand still and other care does nothing.
        let mood = s.mood
        s.advance(to: at(90), events: &e)
        XCTAssertEqual(s.mood, mood)
        _ = s.care(.pet, now: at(91))
        XCTAssertEqual(s.mood, mood)
        // 밥 brings it home.
        let back = s.care(.feed, now: at(92))
        XCTAssertTrue(back.contains(.cameHome))
        XCTAssertFalse(s.isAway)
        XCTAssertGreaterThanOrEqual(s.mood, 40)
    }

    func testAFedPetNeverLeaves() {
        var s = fresh()
        var t = 0.0
        while t < 100 { t += 6; _ = s.care(.feed, now: at(t)) }
        XCTAssertFalse(s.isAway)
        // Three days without care but a full bowl (the cap keeps it above the floor): stays.
        var e: [PetEvent] = []
        s.food = 100
        s.advance(to: at(t + 80), events: &e)
        XCTAssertFalse(s.isAway)
    }

    // MARK: Level, evolution, coins

    func testLevelUpPaysAndEvolvesAtFive() {
        var s = fresh()
        var e: [PetEvent] = []
        let need = (1..<5).map(PetState.xpNeeded).reduce(0, +)
        s.gainXP(need - 1, events: &e)
        XCTAssertEqual(s.level, 4)
        XCTAssertEqual(s.stage, .baby)
        s.gainXP(1, events: &e)
        XCTAssertEqual(s.level, 5)
        XCTAssertEqual(s.stage, .ribbon)
        XCTAssertEqual(e.filter { if case .levelUp = $0 { return true } else { return false } }.count, 4)
        XCTAssertEqual(e.last, .evolved(.ribbon))
        XCTAssertEqual(s.coins, (2...5).map { 10 + $0 }.reduce(0, +))
        XCTAssertEqual(PetStage.forLevel(15), .flowers)
        XCTAssertEqual(PetStage.forLevel(30), .crown)
        XCTAssertEqual(PetStage.forLevel(29), .flowers)
    }

    func testCareGivesXPOnlyWhenNeeded() {
        var s = fresh()
        s.today.done.insert(.feed)   // 밥 mission already paid today, so no mission XP
        s.food = 98
        _ = s.care(.feed, now: t0)
        XCTAssertEqual(s.xp, 0)
        s.food = 40
        _ = s.care(.feed, now: t0)
        XCTAssertEqual(s.xp, 3)
    }

    // MARK: Missions and 출석

    func testMissionsRotateThreeDistinctADay() {
        XCTAssertEqual(PetMissionKind.missions(forDay: 0), [.breaks, .cleaner, .focus])
        for day in 0..<30 { XCTAssertEqual(Set(PetMissionKind.missions(forDay: day)).count, 3) }
        XCTAssertEqual(PetMissionKind.missions(forDay: -1).count, 3)
    }

    func testMissionPaysOnceWhenReached() {
        var s = fresh()
        s.today = PetDay(day: 7 * 300_000)   // a day whose missions are 쉬는 시간 · 클리너 · 집중
        var e: [PetEvent] = []
        s.count(.cleaner, events: &e)
        XCTAssertEqual(e.first, .missionDone(.cleaner, coins: 20))
        XCTAssertEqual(s.coins, 20)
        e = []
        s.count(.cleaner, events: &e)
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(s.coins, 20)
        s.count(.wash, events: &e)   // not today's mission: counted, not paid
        XCTAssertEqual(s.today[.wash], 1)
        XCTAssertEqual(s.coins, 20)
        s.count(.breaks, events: &e); s.count(.breaks, events: &e)
        XCTAssertFalse(s.today.done.contains(.breaks))
        s.count(.breaks, events: &e)
        XCTAssertTrue(s.today.done.contains(.breaks))
    }

    func testAttendanceOnceADayWithStreak() {
        var s = fresh()
        var e: [PetEvent] = []
        s.attend(t0, events: &e)
        s.attend(at(1), events: &e)
        XCTAssertEqual(e, [.attended(coins: 10, streak: 1)])
        s.attend(at(24), events: &e)
        XCTAssertEqual(e.last, .attended(coins: 12, streak: 2))
        s.attend(at(72), events: &e)   // skipped a day
        XCTAssertEqual(e.last, .attended(coins: 10, streak: 1))
        XCTAssertEqual(s.coins, 32)
        var long = fresh()
        for d in 0..<20 { long.attend(at(Double(d) * 24), events: &e) }
        XCTAssertEqual(e.last, .attended(coins: 22, streak: 20))   // capped after a week
    }

    func testActiveSampleAttends() {
        var s = fresh()
        let e = s.apply(.sample(battery: nil, load: 0, idle: 5), now: t0)
        XCTAssertTrue(e.contains(.attended(coins: 10, streak: 1)))
        var idle = fresh()
        XCTAssertFalse(idle.apply(.sample(battery: nil, load: 0, idle: 900), now: t0).contains(.attended(coins: 10, streak: 1)))
    }

    // MARK: Diary

    func testNewDayWritesTheDiaryAndResetsCounters() {
        var s = fresh()
        _ = s.care(.feed, now: t0)
        _ = s.care(.pet, now: t0)
        var e: [PetEvent] = []
        s.advance(to: at(24), events: &e)
        XCTAssertEqual(s.diary.count, 1)
        XCTAssertTrue(s.diary[0].text.hasPrefix("밥 1번, 쓰다듬기 1번."), s.diary[0].text)
        XCTAssertEqual(s.diary[0].day, PetState.dayNumber(t0))
        XCTAssertEqual(s.today[.feed], 0)
        XCTAssertEqual(PetState.diaryLine(PetDay(day: 0), level: 1), "조용한 하루였어요.")
        // Not adopted: nothing written.
        var quiet = PetState(now: t0)
        quiet.advance(to: at(24), events: &e)
        XCTAssertTrue(quiet.diary.isEmpty)
    }

    func testDiaryKeepsAtMostSixtyDays() {
        var s = fresh()
        var e: [PetEvent] = []
        for d in 1...70 { s.advance(to: at(Double(d) * 24), events: &e) }
        XCTAssertEqual(s.diary.count, PetState.maxDiary)
        XCTAssertGreaterThan(s.diary[0].day, s.diary[1].day)
    }

    // MARK: Focus and 20-20-20

    func testFocusPaysThenRests() {
        var s = fresh()
        s.startFocus(now: t0)
        var e: [PetEvent] = []
        s.advance(to: t0.addingTimeInterval(24 * 60), events: &e)
        XCTAssertEqual(s.focus?.mode, .work)
        s.advance(to: t0.addingTimeInterval(25 * 60 + 5), events: &e)
        XCTAssertTrue(e.contains(.focusDone(coins: 15)))
        XCTAssertEqual(s.focus?.mode, .rest)
        XCTAssertEqual(s.today[.focus], 1)
        e = []
        s.advance(to: t0.addingTimeInterval(30 * 60 + 5), events: &e)
        XCTAssertEqual(e, [.restDone])
        XCTAssertNil(s.focus)
    }

    func testStaleFocusFromAClosedAppPaysNothing() {
        var s = fresh()
        s.startFocus(now: t0)
        var e: [PetEvent] = []
        s.advance(to: at(3), events: &e)
        XCTAssertNil(s.focus)
        XCTAssertEqual(s.coins, 0)
        XCTAssertEqual(s.today[.focus], 0)
    }

    func testEyeRestEveryTwentyActiveMinutesWhenOn() {
        var off = fresh(), on = fresh()
        on.eyeRest = true
        var heard = 0, heardOff = 0
        for i in 0...150 {   // 25 minutes of 10 s samples at the keys
            let now = t0.addingTimeInterval(Double(i) * 10)
            heard += on.apply(.sample(battery: nil, load: 0, idle: 1), now: now).filter { $0 == .eyeRest }.count
            heardOff += off.apply(.sample(battery: nil, load: 0, idle: 1), now: now).filter { $0 == .eyeRest }.count
        }
        XCTAssertEqual(heard, 1)
        XCTAssertEqual(heardOff, 0)
        // Looking away for a while starts the count over.
        _ = on.apply(.sample(battery: nil, load: 0, idle: 120), now: t0.addingTimeInterval(1510))
        XCTAssertNil(on.activeSince)
    }

    // MARK: Room

    func testBuyNeedsCoinsAndOnlyOnce() {
        var s = fresh()
        XCTAssertFalse(s.buy("sofa"))
        s.coins = 100
        XCTAssertTrue(s.buy("sofa"))
        XCTAssertEqual(s.coins, 10)
        s.coins = 100
        XCTAssertFalse(s.buy("sofa"))
        XCTAssertFalse(s.buy("no-such-thing"))
        XCTAssertEqual(s.coins, 100)
    }

    func testPlaceRespectsWallAndFloor() {
        var s = fresh()
        s.coins = 1000
        XCTAssertTrue(s.buy("window"))
        XCTAssertFalse(s.place("window", slot: 4))   // wall piece on the floor
        XCTAssertTrue(s.place("window", slot: 1))
        XCTAssertFalse(s.place("bed", slot: 0))      // floor piece on the wall
        XCTAssertFalse(s.place("plant", slot: 5))    // not owned
        XCTAssertTrue(s.place("bed", slot: 5))       // moves from slot 3
        XCTAssertNil(s.slots[3])
        XCTAssertEqual(s.slots[5], "bed")
        XCTAssertTrue(s.place(nil, slot: 5))
        XCTAssertFalse(s.place("bed", slot: 9))
        XCTAssertFalse(s.cover("paper-night"))
        XCTAssertTrue(s.buy("paper-night"))
        XCTAssertTrue(s.cover("paper-night"))
        XCTAssertEqual(s.wallpaper, "paper-night")
        XCTAssertFalse(s.cover("window"))
    }

    func testCodableRoundTrip() throws {
        var s = fresh()
        _ = s.care(.feed, now: t0)
        s.startFocus(now: t0)
        s.awaySince = at(1)
        var e: [PetEvent] = []
        s.advance(to: at(30), events: &e)
        let back = try JSONDecoder().decode(PetState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testModelSavesAndReloads() {
        let suite = "pet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let signals = PetSignals()
        let model = PetModel(defaults: d, signals: signals)
        model.adopt()
        model.care(.feed)
        signals.send(.speedTest)
        XCTAssertEqual(PetModel.load(d), model.state)
        XCTAssertEqual(model.state.today[.speedTest], 1)
        XCTAssertTrue(model.state.adopted)
    }

    func testMenuBarHintsOnlyForAnAdoptedHungryPet() {
        let suite = "pet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let model = PetModel(defaults: d, signals: PetSignals())
        model.state.food = 10
        let playing = Date(timeIntervalSince1970: 45 * 1000 + 2)
        XCTAssertNil(model.menuBarMotion(now: playing, available: [.hungry]))
        XCTAssertNil(model.menuBarNote)
        model.state.adopted = true
        XCTAssertEqual(model.menuBarMotion(now: playing, available: [.hungry]), .hungry)
        XCTAssertNil(model.menuBarMotion(now: playing.addingTimeInterval(20), available: [.hungry]))
        XCTAssertNil(model.menuBarMotion(now: playing, available: [.eat]))
        XCTAssertEqual(model.menuBarNote, "펫이 배고파요")
    }

    func testEveryPetEventHasLines() {
        XCTAssertNotNil(PetModel.line(.eyeRest))
        for e: PetEvent in [.attended(coins: 1, streak: 1), .levelUp(2), .evolved(.crown), .missionDone(.wash, coins: 1),
                            .hungry, .wentAway, .cameHome, .focusDone(coins: 15), .restDone, .eyeRest] {
            XCTAssertFalse(PetModel.lines(e).isEmpty)
            for l in PetModel.lines(e) { XCTAssertFalse(l.contains("\u{2014}")) }
        }
    }
}

/// The room art: enough pieces, clean ASCII, everything fits its slot.
final class PetRoomArtTests: XCTestCase {
    func testCatalogHasSixteenPlusPiecesWithUniqueIDs() {
        XCTAssertGreaterThanOrEqual(PetCatalog.all.count, 16)
        XCTAssertEqual(Set(PetCatalog.all.map(\.id)).count, PetCatalog.all.count)
        for id in PetCatalog.starterItems { XCTAssertNotNil(PetCatalog.item(id), id) }
        XCTAssertTrue(PetCatalog.all.filter { !PetCatalog.starterItems.contains($0.id) }.allSatisfy { $0.price > 0 })
    }

    func testFurnitureRowsAreRectangularAndInPalette() {
        for item in PetCatalog.all where item.kind == .wall || item.kind == .floor {
            XCTAssertFalse(item.rows.isEmpty, item.id)
            XCTAssertEqual(Set(item.rows.map(\.count)).count, 1, "\(item.id) rows differ in width")
            for ch in item.rows.joined() where ch != "." { XCTAssertNotNil(PetRoomArt.palette[ch], "\(item.id): \(ch)") }
        }
    }

    func testPiecesFitTheirSlots() {
        for item in PetCatalog.all where item.kind == .wall || item.kind == .floor {
            let s = PetRoomArt.sprite(item.rows)
            XCTAssertLessThanOrEqual(s.width, 40, item.id)   // three per row on a 124 px room
            if item.kind == .wall {
                XCTAssertLessThanOrEqual(PetRoomArt.wallTop + s.height, PetRoomArt.baseboard, item.id)
            } else {
                XCTAssertGreaterThanOrEqual(PetRoomArt.floorFeet - s.height, 0, item.id)
            }
        }
        let room = PetRoomArt.room(wallpaper: "paper-night", floor: "floor-carpet", slots: ["window", "clock", "garland", "bed", "desk", "lamp"])
        XCTAssertEqual(room.width, PetRoomArt.width)
        XCTAssertEqual(room.height, PetRoomArt.height)
    }

    func testOutlineSurroundsSprites() {
        let s = PetRoomArt.sprite(["w"])
        XCTAssertEqual(s.width, 3)
        XCTAssertEqual(s.height, 3)
        XCTAssertEqual(s.px[(1 * 3 + 0) * 4 + 3], 255)   // left of the pixel: outline
        XCTAssertEqual(s.px[(0 * 3 + 0) * 4 + 3], 0)     // corner stays see-through
        XCTAssertEqual(Array(s.px[(1 * 3 + 0) * 4..<(1 * 3 + 0) * 4 + 3]), [0x5A, 0x3E, 0x36])
        for stage in PetStage.allCases.dropFirst() { XCTAssertNotNil(PetRoomArt.accessory(stage)) }
        XCTAssertNil(PetRoomArt.accessory(.baby))
    }
}

/// 집중 잔디 and the focus line in the menu bar tooltip.
final class PetFocusLogTests: XCTestCase {
    private let t0: Date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!

    func testRolloverKeepsFocusCountsAndPrunesOldDays() {
        var s = PetState(now: t0)
        let day0 = s.today.day
        s.focusLog[day0 - PetState.focusLogDays] = 9   // falls out of the year at the next rollover
        var e: [PetEvent] = []
        s.count(.focus, events: &e); s.count(.focus, events: &e)
        s.advance(to: t0.addingTimeInterval(86_400), events: &e)
        XCTAssertEqual(s.focusLog, [day0: 2])
        XCTAssertEqual(s.focusCount(day0), 2)
        s.count(.focus, events: &e)
        XCTAssertEqual(s.focusCount(day0 + 1), 1)   // today, live
        s.advance(to: t0.addingTimeInterval(2 * 86_400), events: &e)   // a day with focus, then one without
        s.advance(to: t0.addingTimeInterval(3 * 86_400), events: &e)
        XCTAssertEqual(s.focusLog, [day0: 2, day0 + 1: 1])
        XCTAssertEqual(s.focusBest(day0...(day0 + 3))?.day, day0)
        XCTAssertNil(s.focusBest((day0 + 2)...(day0 + 3)))
    }

    func testFocusLogSurvivesSaving() throws {
        var s = PetState(now: t0)
        s.focusLog = [100: 3]
        let loaded = try JSONDecoder().decode(PetState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(loaded.focusLog, [100: 3])
    }

    func testTooltipNoteRoundsMinutesUp() {
        let work = PetFocus(mode: .work, endsAt: t0.addingTimeInterval(11 * 60 + 5))
        XCTAssertEqual(PetModel.focusNote(work, now: t0), "집중 중 · 12분 남음")
        XCTAssertEqual(PetModel.focusNote(PetFocus(mode: .rest, endsAt: t0.addingTimeInterval(170)), now: t0), "쉬는 중 · 3분")
        XCTAssertNil(PetModel.focusNote(work, now: t0.addingTimeInterval(12 * 60)))
    }
}
