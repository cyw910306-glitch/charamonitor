import XCTest
@testable import DogMonitor

/// 날씨 창문: MET symbol mapping, forecast parsing, the lines it says, fetch pacing (with a fake fetch, never the network)
/// and the crystal ball's click-through shape and lens.
final class WeatherTests: XCTestCase {
    private let seoul = WeatherCity.presets[0]
    private let iso = ISO8601DateFormatter()
    private var now: Date { iso.date(from: "2026-10-18T00:30:00Z")! }   // 9:30 in Seoul

    private func entry(_ time: String, _ temp: Double, one: (String, Double)? = nil, six: (String, Double)? = nil) -> String {
        func span(_ s: (String, Double)?) -> String? { s.map { #"{"summary":{"symbol_code":"\#($0.0)"},"details":{"precipitation_amount":\#($0.1)}}"# } }
        let parts = [span(one).map { #""next_1_hours":\#($0)"# }, span(six).map { #""next_6_hours":\#($0)"# }].compactMap { $0 }
        return #"{"time":"\#(time)","data":{"instant":{"details":{"air_temperature":\#(temp),"wind_speed":3.2}}\#(parts.isEmpty ? "" : ",")\#(parts.joined(separator: ","))}}"#
    }

    private var body: Data {
        let series = [
            entry("2026-10-18T00:00:00Z", 12.4, one: ("cloudy", 0)),
            entry("2026-10-18T01:00:00Z", 15.6, one: ("lightrain", 0.8)),
            entry("2026-10-18T06:00:00Z", 18.2, six: ("partlycloudy_day", 0)),
            entry("2026-10-18T14:00:00Z", 9.6, one: ("clearsky_night", 0)),
            entry("2026-10-18T18:00:00Z", 3.1, six: ("fair_night", 0)),
            entry("2026-10-19T03:00:00Z", 16, six: ("rain", 4)),
        ]
        return Data(#"{"type":"Feature","properties":{"timeseries":[\#(series.joined(separator: ","))]}}"#.utf8)
    }

    func testSymbolTable() {
        let table: [(String, WeatherKind, Bool?)] = [
            ("clearsky_day", .clear, false), ("clearsky_night", .clear, true), ("clearsky_polartwilight", .clear, false),
            ("fair_day", .partly, false), ("partlycloudy_night", .partly, true), ("cloudy", .cloudy, nil), ("fog", .fog, nil),
            ("lightrain", .rain, nil), ("heavyrainshowers_day", .rain, false), ("sleet", .snow, nil), ("lightsnowshowers_night", .snow, true),
            ("rainandthunder", .thunder, nil), ("heavysnowshowersandthunder_day", .thunder, false), ("nonsense", .clear, nil),
        ]
        for (symbol, kind, night) in table {
            let got = WeatherKind.from(symbol: symbol)
            XCTAssertEqual(got.kind, kind, symbol)
            XCTAssertEqual(got.night, night, symbol)
        }
    }

    func testParseNowTodayAndTomorrowInTheCitysDay() throws {
        let w = try XCTUnwrap(WeatherNow.parse(body, city: seoul, now: now))
        XCTAssertEqual(w.kind, .cloudy)
        XCTAssertNil(w.night)
        XCTAssertEqual(w.temperature, 12)
        XCTAssertEqual(w.wind, 3.2)
        XCTAssertEqual(w.today, WeatherDay(high: 18, low: 10, wet: true, snowy: false))
        XCTAssertEqual(w.tomorrow, WeatherDay(high: 16, low: 3, wet: true, snowy: false))
        XCTAssertNil(WeatherNow.parse(Data("{}".utf8), city: seoul, now: now))
        XCTAssertNil(WeatherNow.parse(body, city: seoul, now: now + 7 * 86_400), "an old answer is not today's weather")
    }

    func testAnswersAndAdvice() throws {
        var w = try XCTUnwrap(WeatherNow.parse(body, city: seoul, now: now))
        XCTAssertEqual(w.answer(polite: true), "지금 서울 날씨는 12도이고 흐려요. 오늘 최고 18도, 최저 10도예요. 이따 비 소식이 있으니 우산 챙기세요.")
        XCTAssertEqual(w.answer(polite: false, dayOffset: 1), "내일 서울 날씨는 최고 16도, 최저 3도야. 비 소식이 있어.")
        XCTAssertNil(w.answer(polite: true, dayOffset: 3))
        XCTAssertEqual(w.advice()?.key, "weather.rain")
        w.today = WeatherDay(high: 4, low: -3, wet: false, snowy: false)
        XCTAssertEqual(w.advice()?.key, "weather.cold")
        w.today = WeatherDay(high: 31, low: 24, wet: false, snowy: false)
        XCTAssertEqual(w.advice()?.key, "weather.hot")
        w.today = WeatherDay(high: 20, low: 12, wet: false, snowy: false)
        XCTAssertNil(w.advice())
        for line in [w.answer(polite: true), w.answer(polite: false)].compactMap({ $0 }) { XCTAssertFalse(line.contains("\u{2014}")) }
    }

    func testAssistantUsesTheForecastInsteadOfSayingItCannotKnow() throws {
        var r = ChatRequest(persona: Persona(name: "젤리", style: .friendly), summary: "", history: [], facts: [], personal: [], question: "오늘 날씨 어때?")
        XCTAssertTrue(TemplateEngine.fixed(r)?.contains("알 수 없") ?? false)
        r.weather = try XCTUnwrap(WeatherNow.parse(body, city: seoul, now: now))
        XCTAssertTrue(TemplateEngine.fixed(r)?.contains("12도") ?? false)
        XCTAssertFalse(TemplateEngine.modelTakes(r), "no model knows the sky better than the forecast")
    }

    func testRequestCarriesCoordinatesUserAgentAndIfModifiedSince() {
        let r = WeatherService.request(seoul, lastModified: "Sat, 18 Oct 2026 00:00:00 GMT")
        XCTAssertEqual(r.url?.absoluteString, "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=37.5665&lon=126.9780")
        XCTAssertTrue(r.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("CharaMonitor/") ?? false)
        XCTAssertTrue(r.value(forHTTPHeaderField: "User-Agent")?.contains("https://") ?? false, "MET asks for a way to reach us")
        XCTAssertEqual(r.value(forHTTPHeaderField: "If-Modified-Since"), "Sat, 18 Oct 2026 00:00:00 GMT")
        XCTAssertNil(WeatherService.request(seoul, lastModified: nil).value(forHTTPHeaderField: "If-Modified-Since"))
    }

    func testNextFetchKeepsThirtyMinutesAndHonoursExpires() {
        XCTAssertEqual(WeatherService.nextFetch(expires: nil, now: now), now + 1800)
        XCTAssertEqual(WeatherService.nextFetch(expires: now + 60, now: now), now + 1800)
        XCTAssertEqual(WeatherService.nextFetch(expires: now + 3600, now: now), now + 3600)
        XCTAssertEqual(WeatherService.httpDate("Sat, 18 Oct 2026 01:00:00 GMT"), iso.date(from: "2026-10-18T01:00:00Z"))
    }

    @MainActor
    func testRefreshFetchesOnlyWhenDueAndKeepsDataOn304() async {
        let suite = "test.weather.service"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var sent: [URLRequest] = []
        var status = 200
        let body = self.body
        let service = WeatherService(defaults: defaults) { req in
            sent.append(req)
            let url = req.url!
            let headers = ["Expires": "Sat, 18 Oct 2026 01:30:00 GMT", "Last-Modified": "Sat, 18 Oct 2026 00:10:00 GMT"]
            return (status == 200 ? body : Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        await service.refresh(now: now)
        XCTAssertEqual(service.current?.temperature, 12)
        await service.refresh(now: now + 600)
        XCTAssertEqual(sent.count, 1, "not again within Expires")
        status = 304
        await service.refresh(now: now + 3700)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].value(forHTTPHeaderField: "If-Modified-Since"), "Sat, 18 Oct 2026 00:10:00 GMT")
        XCTAssertEqual(service.current?.temperature, 16, "the kept answer read for the new hour")
        XCTAssertFalse(service.failed)
    }

    private final class Box { var service: WeatherService?; var later: Task<Void, Never>? }

    @MainActor
    func testFailedFetchRereadsTheKeptAnswerAndSkipsTheMorningLine() async {
        let suite = "test.weather.offline"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var online = true
        let body = self.body
        let service = WeatherService(defaults: defaults) { req in
            guard online else { throw URLError(.notConnectedToInternet) }
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await service.refresh(now: now)
        XCTAssertEqual(service.current?.today.high, 18)
        online = false
        await service.refresh(now: now + 86_400)
        XCTAssertTrue(service.failed)
        XCTAssertEqual(service.current?.temperature, 3, "the kept answer read for the next morning, not last night's")
        XCTAssertEqual(service.current?.today.high, 16)
        await service.refresh(now: now + 9 * 86_400)
        XCTAssertNil(service.current, "nothing left for that day")
        let morning = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 8))!
        let line = await service.morningLine(now: morning)
        XCTAssertNil(line)
        XCTAssertNil(defaults.string(forKey: "weatherAdviceDay"), "offline does not use up the day's line")
    }

    @MainActor
    func testCityPickedDuringAFetchIsFetchedRightAfter() async {
        let suite = "test.weather.city"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let box = Box()
        var sent: [URLRequest] = []
        let body = self.body, now = self.now, other = WeatherCity.presets[1]
        let service = WeatherService(defaults: defaults) { req in
            sent.append(req)
            if sent.count == 1 {
                await MainActor.run {
                    box.service?.city = other   // picked from the menu while the first GET is out
                    box.later = Task { @MainActor in await box.service?.refresh(now: now) }   // the city sink
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        box.service = service
        await service.refresh(now: now)
        await box.later?.value
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent.last?.url?.absoluteString.contains("lat=37.4563") ?? false)
        XCTAssertEqual(service.current?.city, other.name)
    }

    func testOnlyTheWalkPoseWalks() {
        XCTAssertEqual(WeatherSceneView.pose((.rain, false)), .walk)
        XCTAssertEqual(WeatherSceneView.pose((.clear, true)), .lying)
        XCTAssertEqual(WeatherSceneView.pose((.thunder, true)), .exhausted)
    }

    func testNightFallsBackToTheCitysClock() {
        XCTAssertFalse(WeatherService.night(nil, city: seoul, now: now))                 // 9:30
        XCTAssertTrue(WeatherService.night(nil, city: seoul, now: now + 11 * 3600))      // 20:30
        var w = WeatherNow.parse(body, city: seoul, now: now)
        w?.night = true
        XCTAssertTrue(WeatherService.night(w, city: seoul, now: now))
    }

    func testMorningAdviceOncePerDayInTheMorning() {
        var c = DateComponents(year: 2026, month: 10, day: 18, hour: 8)
        let morning = Calendar.current.date(from: c)!
        c.hour = 15
        let afternoon = Calendar.current.date(from: c)!
        XCTAssertTrue(WeatherService.adviceDue(lastDay: nil, now: morning))
        XCTAssertFalse(WeatherService.adviceDue(lastDay: WeatherService.dayKey(morning), now: morning))
        XCTAssertFalse(WeatherService.adviceDue(lastDay: nil, now: afternoon))
    }

    func testWindowShapeAndSizes() {
        let size = WeatherFrame.size(WeatherFrame.defaultStep)
        XCTAssertEqual(size.width, 160)
        XCTAssertTrue(WeatherFrame.hits(CGPoint(x: 80, y: size.height - 77), size: size), "the middle of the ball")
        XCTAssertFalse(WeatherFrame.hits(CGPoint(x: 2, y: size.height - 2), size: size), "the empty top-left corner passes clicks")
        XCTAssertTrue(WeatherFrame.hits(CGPoint(x: 80, y: 12), size: size), "the stand")
        XCTAssertFalse(WeatherFrame.hits(CGPoint(x: 4, y: 10), size: size))
        XCTAssertFalse(WeatherFrame.hits(CGPoint(x: 80, y: 1), size: size), "the shadow under the stand passes clicks")
        let (c0, r0) = WeatherFrame.orb(size)
        XCTAssertFalse(WeatherFrame.hits(CGPoint(x: c0.x + 0.8 * r0, y: size.height - (c0.y + 0.75 * r0)), size: size),
                       "the empty corner beside the neck passes clicks")
        XCTAssertTrue(WeatherFrame.hits(CGPoint(x: c0.x + 0.75 * r0, y: size.height - (c0.y + 1.12 * r0)), size: size), "the foot's side")
        XCTAssertEqual(WeatherFrame.size(-5), WeatherFrame.size(0))
        XCTAssertEqual(WeatherFrame.size(99).width, 320)
        for s in WeatherFrame.scales { XCTAssertEqual((2 * s * 2).truncatingRemainder(dividingBy: 1), 0, "whole Retina pixels at \(s)") }
        for step in WeatherFrame.scales.indices {
            let size = WeatherFrame.size(step), (c, r) = WeatherFrame.orb(size), collar = WeatherArt.standRings(c: c, r: r).collar
            XCTAssertGreaterThanOrEqual(c.y - r, 0, "the ball fits under the top")
            XCTAssertLessThan(collar.minY, c.y + r, "the ball sits in the stand")
            XCTAssertLessThanOrEqual(c.y + r * 1.53, size.height + 0.5, "the shadow fits in the window")
        }
    }

    func testOrbLensKeepsCentreAndRimAndMagnifiesTheMiddle() {
        XCTAssertEqual(OrbLens.bend(0), 0)
        XCTAssertEqual(OrbLens.bend(1), 1, accuracy: 1e-9)
        var last: CGFloat = -1
        for i in 0...150 {
            let b = OrbLens.bend(CGFloat(i) / 100)
            XCTAssertGreaterThan(b, last, "never folds back, past the rim too")
            last = b
        }
        let lens = OrbLens(s: 100)
        XCTAssertEqual(lens(CGPoint(x: 50, y: 50)), CGPoint(x: 50, y: 50))
        XCTAssertGreaterThan(lens(CGPoint(x: 50, y: 70)).y, 70, "the middle is pushed out")
        XCTAssertEqual(lens(CGPoint(x: 100, y: 50)).x, 100, accuracy: 1e-9, "the rim stays")
        XCTAssertLessThan(lens.scale(CGPoint(x: 95, y: 50)), lens.scale(CGPoint(x: 55, y: 50)), "things shrink toward the glass")
        // A flat horizon bows: its ends sit higher than its middle.
        XCTAssertLessThan(lens(CGPoint(x: 10, y: 74)).y, lens(CGPoint(x: 50, y: 74)).y)
    }

    func testTemperatureDressesASunnyDayAndEverySkyHasLines() {
        XCTAssertTrue(WeatherProps.prop(.clear, night: false, temp: 31)?.image === WeatherProps.sunglasses.image)
        XCTAssertTrue(WeatherProps.prop(.partly, night: false, temp: -2)?.image === WeatherProps.knitHat.image)
        XCTAssertNil(WeatherProps.prop(.clear, night: false, temp: 18), "a mild clear day keeps no prop")
        XCTAssertNil(WeatherProps.prop(.clear, night: true, temp: 31), "asleep, nothing worn")
        XCTAssertTrue(WeatherProps.prop(.rain, night: false, temp: 31)?.image === WeatherProps.umbrella.image, "rain still means the umbrella")
        for k in WeatherKind.allCases {
            XCTAssertFalse(k.quips.isEmpty)
            XCTAssertEqual(WeatherArt.reaction(k, asleep: false).marks.count, 3)
        }
        XCTAssertFalse((WeatherKind.allCases.flatMap(\.quips) + WeatherKind.nightQuips).contains { $0.contains("\u{2014}") })
    }
}
