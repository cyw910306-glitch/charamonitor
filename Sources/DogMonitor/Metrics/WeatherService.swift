import Combine
import CoreLocation
import Foundation

/// The 날씨 창문's seven scenes, read from MET Norway's symbol_code.
enum WeatherKind: String, CaseIterable, Equatable {
    case clear, partly, cloudy, fog, rain, snow, thunder

    /// "lightrainshowers_day" -> (.rain, false). `night` is nil for symbols with no day/night variant (cloudy, rain, fog).
    /// Sleet counts as snow; an unknown symbol as clear.
    static func from(symbol: String) -> (kind: WeatherKind, night: Bool?) {
        let parts = symbol.lowercased().split(separator: "_").map(String.init)
        let base = parts.first ?? ""
        let night: Bool? = parts.count > 1 ? parts[1] == "night" : nil   // "polartwilight" is not night
        let kind: WeatherKind
        if base.contains("thunder") { kind = .thunder }
        else if base.contains("snow") || base.contains("sleet") { kind = .snow }
        else if base.contains("rain") { kind = .rain }
        else if base == "fog" { kind = .fog }
        else if base == "cloudy" { kind = .cloudy }
        else if base.hasPrefix("partlycloudy") || base == "fair" { kind = .partly }
        else { kind = .clear }
        return (kind, night)
    }

    var title: String {
        switch self {
        case .clear: return L("맑음")
        case .partly: return L("구름 조금")
        case .cloudy: return L("흐림")
        case .fog: return L("안개")
        case .rain: return L("비")
        case .snow: return L("눈")
        case .thunder: return L("천둥 번개")
        }
    }

    /// What the 날씨 창문's character says now and then on a click (WeatherWindow.clicked).
    var quips: [String] {
        switch self {
        case .clear: return [L("햇살 냠냠, 기분 좋아요!"), L("오늘 산책 각이에요")]
        case .partly: return [L("구름이 풍선 같아요"), L("해님이랑 숨바꼭질 중이에요")]
        case .cloudy: return [L("구름 뒤에 해님 숨었어요"), L("포근한 회색 하늘이에요")]
        case .fog: return [L("어디 있어요? 손전등 켰어요"), L("뿌연 게 솜사탕 같아요")]
        case .rain: return [L("우산 챙겼어요?"), L("찰박찰박 재밌어요")]
        case .snow: return [L("눈사람 만들고 싶어요"), L("발 시려요")]
        case .thunder: return [L("쾅! 무서워요…"), L("꼭 안아 주세요")]
        }
    }

    /// Asleep in the window at night.
    static var nightQuips: [String] { [L("쿨쿨… 깨우지 마요"), L("좋은 꿈 꿀게요")] }

    /// "지금 서울 날씨는 12도이고 ___." in (반말, 존댓말).
    var phrase: (String, String) {
        switch self {
        case .clear: return (L("맑아"), L("맑아요"))
        case .partly: return (L("구름이 조금 있어"), L("구름이 조금 있어요"))
        case .cloudy: return (L("흐려"), L("흐려요"))
        case .fog: return (L("안개가 꼈어"), L("안개가 꼈어요"))
        case .rain: return (L("비가 와"), L("비가 와요"))
        case .snow: return (L("눈이 와"), L("눈이 와요"))
        case .thunder: return (L("천둥 번개가 쳐"), L("천둥 번개가 쳐요"))
        }
    }

    var wet: Bool { self == .rain || self == .thunder }
}

/// A place to show. Presets need no lookup; any other comes from CLGeocoder (no location permission).
struct WeatherCity: Equatable {
    var name: String
    var lat: Double
    var lon: Double
    /// Its clock, for night on symbols without a day/night variant.
    var timeZone = "Asia/Seoul"

    static let presets: [WeatherCity] = [
        WeatherCity(name: L("서울"), lat: 37.5665, lon: 126.9780), WeatherCity(name: L("인천"), lat: 37.4563, lon: 126.7052),
        WeatherCity(name: L("수원"), lat: 37.2636, lon: 127.0286), WeatherCity(name: L("춘천"), lat: 37.8813, lon: 127.7298),
        WeatherCity(name: L("강릉"), lat: 37.7519, lon: 128.8761), WeatherCity(name: L("대전"), lat: 36.3504, lon: 127.3845),
        WeatherCity(name: L("청주"), lat: 36.6424, lon: 127.4890), WeatherCity(name: L("전주"), lat: 35.8242, lon: 127.1480),
        WeatherCity(name: L("광주"), lat: 35.1595, lon: 126.8526), WeatherCity(name: L("대구"), lat: 35.8714, lon: 128.6014),
        WeatherCity(name: L("부산"), lat: 35.1796, lon: 129.0756), WeatherCity(name: L("울산"), lat: 35.5384, lon: 129.3114),
        WeatherCity(name: L("제주"), lat: 33.4996, lon: 126.5312),
    ]
}

/// One day of the forecast, local to the city.
struct WeatherDay: Equatable {
    var high: Int
    var low: Int
    /// Rain or thunder some hour of the day.
    var wet: Bool
    var snowy: Bool
}

/// The forecast as the app uses it: now, and today and tomorrow in the city.
struct WeatherNow: Equatable {
    var city: String
    var kind: WeatherKind
    /// nil: the symbol has no day/night variant (see WeatherService.night).
    var night: Bool?
    var temperature: Int
    /// m/s, for the 대롱대롱 친구's wind.
    var wind: Double
    var today: WeatherDay
    var tomorrow: WeatherDay?

    private struct Doc: Decodable {
        struct Props: Decodable { let timeseries: [Entry] }
        struct Entry: Decodable {
            struct DataPart: Decodable {
                struct Instant: Decodable { struct Details: Decodable { let air_temperature: Double?; let wind_speed: Double? }; let details: Details }
                struct Span: Decodable {
                    struct Summary: Decodable { let symbol_code: String }
                    struct Details: Decodable { let precipitation_amount: Double? }
                    let summary: Summary?
                    let details: Details?
                }
                let instant: Instant
                let next_1_hours: Span?
                let next_6_hours: Span?
                let next_12_hours: Span?
            }
            let time: String
            let data: DataPart
        }
        let properties: Props
    }

    /// Reads a locationforecast/2.0/compact body. nil when it is not one or has no hour at or after `now` minus an hour.
    static func parse(_ body: Data, city: WeatherCity, now: Date) -> WeatherNow? {
        guard let doc = try? JSONDecoder().decode(Doc.self, from: body) else { return nil }
        let iso = ISO8601DateFormatter()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: city.timeZone) ?? .current
        let hours = doc.properties.timeseries.compactMap { e in iso.date(from: e.time).map { ($0, e.data) } }
        guard hours.contains(where: { $0.0 >= now - 3600 }), let first = hours.last(where: { $0.0 <= now }) ?? hours.first,
              let temp = first.1.instant.details.air_temperature else { return nil }
        let symbol = first.1.next_1_hours?.summary?.symbol_code ?? first.1.next_6_hours?.summary?.symbol_code
            ?? first.1.next_12_hours?.summary?.symbol_code ?? "clearsky_day"
        let (kind, night) = WeatherKind.from(symbol: symbol)

        func day(_ offset: Int) -> WeatherDay? {
            guard let date = cal.date(byAdding: .day, value: offset, to: now) else { return nil }
            let these = hours.filter { cal.isDate($0.0, inSameDayAs: date) && $0.0 >= now - 3600 }
            let temps = these.compactMap { $0.1.instant.details.air_temperature }
            guard let hi = temps.max(), let lo = temps.min() else { return nil }
            var wet = false, snowy = false
            for (_, d) in these {
                let span = d.next_1_hours ?? d.next_6_hours
                let k = span?.summary.map { WeatherKind.from(symbol: $0.symbol_code).kind }
                // A trace in the hourly amount alone is not a reason to carry an umbrella.
                let one = d.next_1_hours?.details?.precipitation_amount
                let mm = one.map { $0 >= 0.5 } ?? ((d.next_6_hours?.details?.precipitation_amount ?? 0) >= 1.5)
                if k?.wet == true || (mm && k != .snow) { wet = true }
                if k == .snow { snowy = true }
            }
            return WeatherDay(high: Int(hi.rounded()), low: Int(lo.rounded()), wet: wet, snowy: snowy)
        }
        guard let today = day(0) else { return nil }
        return WeatherNow(city: city.name, kind: kind, night: night, temperature: Int(temp.rounded()),
                          wind: first.1.instant.details.wind_speed ?? 0, today: today, tomorrow: day(1))
    }

    /// The AI 비서's answer to "오늘 날씨 어때?" (0) or "내일 비 와?" (1); nil for other days (it does not keep them).
    func answer(polite: Bool, dayOffset: Int = 0) -> String? {
        func say(_ banmal: String, _ yo: String) -> String { polite ? yo : banmal }
        switch dayOffset {
        case 0:
            let p = kind.phrase
            let base = say(L("지금 \(city) 날씨는 \(temperature)도이고 \(p.0). 오늘 최고 \(today.high)도, 최저 \(today.low)도야."),
                           L("지금 \(city) 날씨는 \(temperature)도이고 \(p.1). 오늘 최고 \(today.high)도, 최저 \(today.low)도예요."))
            guard today.wet, !kind.wet else { return base }
            return base + " " + say(L("이따 비 소식이 있으니 우산 챙겨."), L("이따 비 소식이 있으니 우산 챙기세요."))
        case 1:
            guard let t = tomorrow else { return nil }
            let temps = say(L("내일 \(city) 날씨는 최고 \(t.high)도, 최저 \(t.low)도야."), L("내일 \(city) 날씨는 최고 \(t.high)도, 최저 \(t.low)도예요."))
            let sky = t.wet ? say(L("비 소식이 있어."), L("비 소식이 있어요.")) : t.snowy ? say(L("눈 소식이 있어."), L("눈 소식이 있어요."))
                            : say(L("비 소식은 없어."), L("비 소식은 없어요."))
            return temps + " " + sky
        default:
            return nil
        }
    }

    /// The morning line's LinePick key and its (반말, 존댓말) choices; nil on a plain day. Rain first, then snow, cold, heat.
    func advice() -> (key: String, lines: [(String, String)])? {
        if today.wet {
            return ("weather.rain", [
                (L("오늘 \(city)에 비 소식이 있어. 나갈 때 우산 챙겨."), L("오늘 \(city)에 비 소식이 있어요. 나갈 때 우산 챙기세요.")),
                (L("이따 비가 올 것 같아. 가방에 우산 하나 넣어 두자."), L("이따 비가 올 것 같아요. 가방에 우산 하나 넣어 두세요.")),
            ])
        }
        if today.snowy {
            return ("weather.snow", [
                (L("오늘 \(city)에 눈 소식이 있어. 길이 미끄러우니 천천히 걷자."), L("오늘 \(city)에 눈 소식이 있어요. 길이 미끄러우니 천천히 걸으세요.")),
                (L("눈이 올 것 같아. 따뜻한 신발 신고 나가."), L("눈이 올 것 같아요. 따뜻한 신발 신고 나가세요.")),
            ])
        }
        if today.low < 0 {
            return ("weather.cold", [
                (L("오늘 최저 \(today.low)도, 영하야. 두꺼운 겉옷 꼭 입어."), L("오늘 최저 \(today.low)도로 영하예요. 두꺼운 겉옷 꼭 입으세요.")),
                (L("밖은 영하래. 장갑이랑 겉옷 챙겨."), L("밖은 영하래요. 장갑이랑 겉옷 챙기세요.")),
            ])
        }
        if today.high >= 30 {
            return ("weather.hot", [
                (L("오늘 낮 최고 \(today.high)도까지 올라. 물 자주 마셔."), L("오늘 낮 최고 \(today.high)도까지 올라요. 물 자주 드세요.")),
                (L("많이 더운 날이야. 물병 하나 곁에 두자."), L("많이 더운 날이에요. 물병 하나 곁에 두세요.")),
            ])
        }
        return nil
    }
}

/// MET Norway locationforecast (CC BY 4.0, credited in the app): one GET per city at most every 30 minutes,
/// later when the answer's Expires says so, with If-Modified-Since. It runs only while the 날씨 창문 is on (the AI 비서's
/// weather answer uses it then too); the city is a preset or a CLGeocoder search, never this Mac's location.
final class WeatherService: ObservableObject {
    static let shared = WeatherService()
    static let minInterval: TimeInterval = 30 * 60
    static let userAgent = "CharaMonitor/\(AppInfo.version) https://jelly-monitor.vercel.app/support.html"

    @Published private(set) var current: WeatherNow?
    /// The last fetch failed (offline, refused); `current` is kept as it was.
    @Published private(set) var failed = false
    @Published var city: WeatherCity {
        didSet {
            guard city != oldValue else { return }
            defaults.set(city.name, forKey: "weatherCity")
            defaults.set(city.lat, forKey: "weatherLat")
            defaults.set(city.lon, forKey: "weatherLon")
            defaults.set(city.timeZone, forKey: "weatherTimeZone")
            body = nil; lastModified = nil; due = .distantPast; current = nil   // the 날씨 창문 asks again (WeatherWindow)
        }
    }
    /// 날씨 미리보기 (screenshots): this scene whatever the sky does. Not saved.
    @Published var preview: WeatherKind?
    /// 밤으로 보기. Not saved.
    @Published var previewNight = false

    private let defaults: UserDefaults
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)
    private var body: Data?
    private var lastModified: String?
    private var due = Date.distantPast
    private var inFlight: Task<Void, Never>?

    /// Tests pass their own `fetch`; nothing here reaches the network then.
    init(defaults: UserDefaults = AppDefaults.store,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
        self.fetch = fetch
        if let name = defaults.string(forKey: "weatherCity"), defaults.object(forKey: "weatherLat") != nil {
            city = WeatherCity(name: name, lat: defaults.double(forKey: "weatherLat"), lon: defaults.double(forKey: "weatherLon"),
                               timeZone: defaults.string(forKey: "weatherTimeZone") ?? "Asia/Seoul")
        } else {
            city = WeatherCity.presets[0]
        }
    }

    /// The GET for `city`: coordinates at 4 decimals (MET caches by them), our User-Agent, If-Modified-Since when known.
    static func request(_ city: WeatherCity, lastModified: String?) -> URLRequest {
        let url = URL(string: String(format: "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=%.4f&lon=%.4f", city.lat, city.lon))!
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let lastModified { r.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        return r
    }

    /// When the next GET may go: the answer's Expires, never sooner than `minInterval` from `now`.
    static func nextFetch(expires: Date?, now: Date) -> Date { max(expires ?? now, now + minInterval) }

    static func httpDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }

    /// Night on a symbol without a day/night variant: 19:00 to 6:00 on the city's clock.
    static func night(_ w: WeatherNow?, city: WeatherCity, now: Date) -> Bool {
        if let n = w?.night { return n }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: city.timeZone) ?? .current
        let h = cal.component(.hour, from: now)
        return h >= 19 || h < 6
    }

    /// What the window draws: the preview, or the real sky (clear until the first answer comes).
    func scene(now: Date = Date()) -> (kind: WeatherKind, night: Bool) {
        (preview ?? current?.kind ?? .clear, previewNight || Self.night(current, city: city, now: now))
    }

    /// GETs when due, else re-reads the kept answer for the new hour. Callers can call it as often as they like.
    @MainActor
    func refresh(now: Date = Date()) async {
        // A GET already going: wait for it, then look again (a city picked meanwhile is due at once).
        while let t = inFlight { await t.value }   // the task clears inFlight before it ends, so this never spins
        guard now >= due else { return reread(now) }
        let task = Task { @MainActor in
            await self.load(now: now)
            self.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    /// The kept answer read at `now`; nil when it has nothing left for today (an old one is not today's weather).
    @MainActor
    private func reread(_ now: Date) {
        current = body.flatMap { WeatherNow.parse($0, city: city, now: now) }
    }

    @MainActor
    private func load(now: Date) async {
        let asked = city
        do {
            let (data, response) = try await fetch(Self.request(asked, lastModified: lastModified))
            guard asked == city, let http = response as? HTTPURLResponse else { return }
            due = Self.nextFetch(expires: Self.httpDate(http.value(forHTTPHeaderField: "Expires")), now: now)
            switch http.statusCode {
            case 200:
                body = data
                lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            case 304: break
            default:
                failed = true
                return reread(now)
            }
            if let body, let w = WeatherNow.parse(body, city: asked, now: now) { current = w; failed = false } else { failed = true }
        } catch {
            guard asked == city else { return }
            due = now + Self.minInterval
            failed = true
            reread(now)
        }
    }

    /// The forecast, fetched first when due (the AI 비서's weather answer).
    @MainActor
    func forecast() async -> WeatherNow? {
        await refresh()
        return current
    }

    /// The day's morning advice: from 5:00 to 13:00, once a day (the day is marked even on a plain one).
    static func adviceDue(lastDay: String?, now: Date) -> Bool {
        let h = Calendar.current.component(.hour, from: now)
        return (5..<13).contains(h) && lastDay != dayKey(now)
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// The morning line in the character's voice, at most once a day; nil when not due, offline or a plain day.
    @MainActor
    func morningLine(now: Date = Date()) async -> String? {
        guard Self.adviceDue(lastDay: defaults.string(forKey: "weatherAdviceDay"), now: now) else { return nil }
        await refresh(now: now)
        // Offline (often right after waking): no line and the day stays unmarked, so a later wake tries again.
        guard let w = current, !failed else { return nil }
        defaults.set(Self.dayKey(now), forKey: "weatherAdviceDay")
        guard let advice = w.advice() else { return nil }
        let persona = AssistantModel.persona()
        let pair = LinePick.pick(advice.key, advice.lines)
        return persona.dress(persona.style.banmal ? pair.0 : pair.1)   // a free line: Persona.flavor may dress it
    }

    /// A city by name ("춘천", "Tokyo"), through Apple's geocoder. nil when nothing matched.
    static func search(_ query: String) async -> WeatherCity? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let place = try? await CLGeocoder().geocodeAddressString(q).first, let at = place.location?.coordinate else { return nil }
        return WeatherCity(name: place.locality ?? place.name ?? q, lat: at.latitude, lon: at.longitude,
                           timeZone: place.timeZone?.identifier ?? TimeZone.current.identifier)
    }

    /// QA renders: a made-up answer, nothing fetched.
    func show(_ w: WeatherNow) { current = w }

    /// "서울 · 12° 흐림" for the window's menu and its accessibility label.
    var summary: String {
        guard let w = current else { return failed ? L("\(city.name) · 연결 안 됨") : L("\(city.name) · 불러오는 중") }
        return "\(w.city) · \(w.temperature)° \(w.kind.title)"
    }
}
