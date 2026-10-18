import Foundation
import Security

// 쇼핑과 항공권 (agent v1, design sections 2 and 7): the app never buys or books. It builds a search link the owner opens
// in their own browser (cart, seats, passengers and payment stay theirs), and, when the owner pasted their own Naver
// developer key, reads the 5 lowest prices for the price watch goal. Everything here is pure except the Keychain and the
// one HTTP call, whose transport is swappable so tests never touch the network.
//
// URL formats, checked 2026-10-05 with curl (desktop Chrome User-Agent) and headless Chromium:
// - 네이버쇼핑 `search.shopping.naver.com/ns/search?query=`: curl and headless get 418/405 (bot wall). The format is the
//   one search.naver.com's own 쇼핑 더보기 link uses (that page links both /ns/search and the older /search/all).
// - 쿠팡 `www.coupang.com/np/search?q=`: curl and headless get 403 Access Denied (Akamai). The format is the site's own
//   search form (`action="/np/search"`, input `name="q"`) in the Wayback snapshot of 2026-10-04.
// - 네이버 항공권 `flight.naver.com/flights/{domestic|international}/GMP-CJU-20261110[/CJU-GMP-20261115]?adult=1&fareType=`:
//   200, and headless Chromium rendered the filled search (김포→제주 11.10~11.15 성인 1명; 인천→나리타 편도 성인 2명 일반석).
//   fareType is YC on the domestic page and Y (일반석) on the international one, as the site writes them.
// - 스카이스캐너 `www.skyscanner.co.kr/transport/flights/gmp/cju/261110/[261115/]?adultsv2=1&cabinclass=economy&rtn=0`:
//   curl lands on a PerimeterX captcha. The path is Skyscanner's documented deep-link shape; adultsv2, cabinclass and
//   rtn are the names its own pages use (Wayback CDX, skyscanner.co.kr/transport/flights-from/kr, 2025-09).
// - Google Flights `www.google.com/travel/flights?q=Flights to CJU from GMP on 2026-11-10 through 2026-11-15&hl=ko&curr=KRW`:
//   200, and headless Chromium filled 서울 GMP → 제주 CJU, 11월 10일 ~ 11월 15일.
// - Airline home pages: 아시아나 (flyasiana.com, www redirects there) and 제주항공 answer 200. 티웨이 (twayair.com) now
//   redirects to 트리니티항공 (trinityairways.com), the new name, so the link goes there and both hosts are allowed.
//   대한항공 answers curl 403, and 진에어, 에어부산 and 에어서울 show a Cloudflare challenge; their bare home URLs are kept.

// MARK: - Link builders

/// Search links the app opens for the owner. Builders return nil only when an airport code is not in `Airports`.
enum KoreanLinks {
    static func naverShopping(_ query: String) -> URL {
        URL(string: "https://search.shopping.naver.com/ns/search?query=\(encode(query))")!
    }

    static func coupang(_ query: String) -> URL {
        URL(string: "https://www.coupang.com/np/search?q=\(encode(query))")!
    }

    static func shop(_ query: String, store: ShopStore) -> URL {
        store == .coupang ? coupang(query) : naverShopping(query)
    }

    /// 네이버 항공권. Both airports in Korea = the domestic page (김포-제주, also 인천-제주), else the international one.
    static func naverFlights(_ q: FlightQuery) -> URL? {
        guard Airports.isKnown(q.from), Airports.isKnown(q.to) else { return nil }
        let from = q.from.uppercased(), to = q.to.uppercased()
        let domestic = Airports.isDomestic(from) && Airports.isDomestic(to)
        var path = "\(from)-\(to)-\(day(q.depart, "yyyyMMdd"))"
        if let back = q.returnDate { path += "/\(to)-\(from)-\(day(back, "yyyyMMdd"))" }
        let kind = domestic ? "domestic" : "international"
        return URL(string: "https://flight.naver.com/flights/\(kind)/\(path)?adult=\(adults(q))&fareType=\(domestic ? "YC" : "Y")")
    }

    static func skyscanner(_ q: FlightQuery) -> URL? {
        guard Airports.isKnown(q.from), Airports.isKnown(q.to) else { return nil }
        var path = "\(q.from.lowercased())/\(q.to.lowercased())/\(day(q.depart, "yyMMdd"))/"
        if let back = q.returnDate { path += "\(day(back, "yyMMdd"))/" }
        let rtn = q.returnDate == nil ? 0 : 1
        return URL(string: "https://www.skyscanner.co.kr/transport/flights/\(path)?adultsv2=\(adults(q))&cabinclass=economy&rtn=\(rtn)")
    }

    /// Google reads the plain-English `q` and fills the form.
    /// ponytail: no passenger count (the `q` sentence has no form for it that was checked); the owner sets it on the page.
    static func googleFlights(_ q: FlightQuery) -> URL? {
        guard Airports.isKnown(q.from), Airports.isKnown(q.to) else { return nil }
        var sentence = "Flights to \(q.to.uppercased()) from \(q.from.uppercased()) on \(day(q.depart, "yyyy-MM-dd"))"
        if let back = q.returnDate { sentence += " through \(day(back, "yyyy-MM-dd"))" }
        return URL(string: "https://www.google.com/travel/flights?q=\(encode(sentence))&hl=ko&curr=KRW")
    }

    /// The airline's home page from a name the owner or the model wrote (대한항공, 진에어, "KE"...). Booking deep links
    /// are not pinned: each airline changes them often and most sit behind a bot wall.
    static func airline(_ name: String) -> URL? { Airline.find(name)?.home }

    // MARK: Host allowlist

    /// Hosts (and their subdomains) the app may open. Design section 4: anything else is not opened from a card.
    static let allowedHosts = ["coupang.com", "shopping.naver.com", "smartstore.naver.com", "flight.naver.com",
                               "skyscanner.co.kr"] + Airline.allCases.flatMap(\.hosts)

    /// https only, the host equal to an allowed one or a subdomain of it (so `coupang.com.evil.io` and `evilcoupang.com`
    /// fail), and Google only under /travel.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if host == "google.com" || host == "www.google.com" {
            return url.path == "/travel" || url.path.hasPrefix("/travel/")
        }
        return allowedHosts.contains(where: under)
    }

    // MARK: Plumbing

    /// Unreserved characters only (RFC 3986), so `&`, `+`, `=` and `#` in a product name stay inside the value.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func adults(_ q: FlightQuery) -> Int { min(max(q.adults, 1), 9) }

    /// FlightQuery days are local midnights, so they are written in this Mac's time zone (read at each call: travel).
    private static func day(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f.string(from: date)
    }
}

// MARK: - Airlines

enum Airline: String, CaseIterable {
    case koreanAir = "대한항공", asiana = "아시아나항공", jinAir = "진에어", jejuAir = "제주항공", tway = "티웨이항공",
         airBusan = "에어부산", airSeoul = "에어서울"

    var home: URL {
        switch self {
        case .koreanAir: return URL(string: "https://www.koreanair.com/")!
        case .asiana: return URL(string: "https://flyasiana.com/")!
        case .jinAir: return URL(string: "https://www.jinair.com/")!
        case .jejuAir: return URL(string: "https://www.jejuair.net/")!
        case .tway: return URL(string: "https://www.trinityairways.com/")!
        case .airBusan: return URL(string: "https://www.airbusan.com/")!
        case .airSeoul: return URL(string: "https://flyairseoul.com/")!
        }
    }

    var hosts: [String] {
        switch self {
        case .koreanAir: return ["koreanair.com"]
        case .asiana: return ["flyasiana.com"]
        case .jinAir: return ["jinair.com"]
        case .jejuAir: return ["jejuair.net"]
        case .tway: return ["twayair.com", "trinityairways.com"]
        case .airBusan: return ["airbusan.com"]
        case .airSeoul: return ["flyairseoul.com"]
        }
    }

    /// Short names and IATA designators, all compared without spaces and case.
    var aliases: [String] {
        switch self {
        case .koreanAir: return ["대한", "korean air", "koreanair", "ke"]
        case .asiana: return ["아시아나", "asiana", "oz"]
        case .jinAir: return ["jin air", "jinair", "lj"]
        case .jejuAir: return ["제주에어", "jeju air", "jejuair", "7c"]
        case .tway: return ["티웨이", "트리니티항공", "트리니티", "t'way", "tway", "trinity airways", "tw"]
        case .airBusan: return ["air busan", "airbusan", "bx"]
        case .airSeoul: return ["air seoul", "airseoul", "rs"]
        }
    }

    static func find(_ name: String) -> Airline? {
        let key = Airports.normalize(name)
        return allCases.first { a in ([a.rawValue] + a.aliases).contains { Airports.normalize($0) == key } }
    }
}

// MARK: - Airports

/// About 110 airports people in Korea fly from and to, with Korean names and the words people type for them. A city
/// with several airports gives its name to the one most Korean flights use (도쿄 → 나리타, 오사카 → 간사이);
/// `route(_:_:)` adds the 김포 pairs.
enum Airports {
    /// (IATA, Korean name, aliases). The first block is Korea: both ends there = 네이버 domestic page.
    private static let korea: [(String, String, [String])] = [
        ("ICN", "인천", ["인천", "서울", "서울인천"]),
        ("GMP", "김포", ["김포", "서울김포"]),
        ("CJU", "제주", ["제주", "제주도"]),
        ("PUS", "부산 김해", ["김해", "부산"]),
        ("TAE", "대구", ["대구"]),
        ("CJJ", "청주", ["청주"]),
        ("KWJ", "광주", ["광주"]),
        ("RSU", "여수", ["여수"]),
        ("YNY", "양양", ["양양", "강릉", "속초"]),
        ("USN", "울산", ["울산"]),
        ("MWX", "무안", ["무안", "목포"]),
        ("KPO", "포항경주", ["포항", "경주", "포항경주"]),
        ("HIN", "사천", ["사천", "진주"]),
        ("KUV", "군산", ["군산"]),
        ("WJU", "원주", ["원주"]),
    ]

    private static let abroad: [(String, String, [String])] = [
        // Japan
        ("NRT", "도쿄 나리타", ["도쿄", "동경", "나리타"]),
        ("HND", "도쿄 하네다", ["하네다"]),
        ("KIX", "오사카 간사이", ["오사카", "간사이", "교토", "고베"]),
        ("ITM", "오사카 이타미", ["이타미"]),
        ("FUK", "후쿠오카", ["후쿠오카"]),
        ("CTS", "삿포로 신치토세", ["삿포로", "신치토세", "홋카이도"]),
        ("OKA", "오키나와 나하", ["오키나와", "나하"]),
        ("NGO", "나고야 주부", ["나고야", "주부"]),
        ("KOJ", "가고시마", ["가고시마"]),
        ("KMJ", "구마모토", ["구마모토"]),
        ("OIT", "오이타", ["오이타", "벳푸", "유후인"]),
        ("HIJ", "히로시마", ["히로시마"]),
        ("TAK", "다카마쓰", ["다카마쓰", "다카마츠"]),
        ("MYJ", "마쓰야마", ["마쓰야마", "마츠야마"]),
        ("KMQ", "고마쓰", ["고마쓰", "고마츠", "가나자와"]),
        ("FSZ", "시즈오카", ["시즈오카"]),
        ("SDJ", "센다이", ["센다이"]),
        ("OKJ", "오카야마", ["오카야마"]),
        ("YGJ", "요나고", ["요나고"]),
        ("NGS", "나가사키", ["나가사키"]),
        // China, Hong Kong, Macau, Taiwan, Mongolia
        ("PEK", "베이징 서우두", ["베이징", "북경"]),
        ("PKX", "베이징 다싱", ["다싱"]),
        ("PVG", "상하이 푸둥", ["상하이", "상해", "푸둥"]),
        ("SHA", "상하이 훙차오", ["훙차오", "홍차오"]),
        ("TAO", "칭다오", ["칭다오", "청도"]),
        ("CAN", "광저우", ["광저우"]),
        ("SZX", "선전", ["선전", "심천"]),
        ("DLC", "다롄", ["다롄", "대련"]),
        ("SHE", "선양", ["선양", "심양"]),
        ("YNJ", "옌지", ["옌지", "연길"]),
        ("HRB", "하얼빈", ["하얼빈"]),
        ("HKG", "홍콩", ["홍콩"]),
        ("MFM", "마카오", ["마카오"]),
        ("TPE", "타이베이 타오위안", ["타이베이", "타이페이", "대만", "타오위안"]),
        ("TSA", "타이베이 쑹산", ["쑹산", "송산"]),
        ("KHH", "가오슝", ["가오슝"]),
        ("ULN", "울란바토르", ["울란바토르", "몽골"]),
        // Southeast Asia
        ("BKK", "방콕 수완나품", ["방콕", "수완나품", "태국"]),
        ("DMK", "방콕 돈므앙", ["돈므앙"]),
        ("HKT", "푸껫", ["푸껫", "푸켓"]),
        ("CNX", "치앙마이", ["치앙마이"]),
        ("DAD", "다낭", ["다낭"]),
        ("HAN", "하노이", ["하노이"]),
        ("SGN", "호찌민", ["호찌민", "호치민"]),
        ("CXR", "나트랑 깜라인", ["나트랑", "냐짱", "깜라인"]),
        ("PQC", "푸꾸옥", ["푸꾸옥"]),
        ("CEB", "세부", ["세부", "막탄"]),
        ("MNL", "마닐라", ["마닐라", "필리핀"]),
        ("CRK", "클락", ["클락", "클라크"]),
        ("KLO", "칼리보", ["칼리보", "보라카이"]),
        ("SIN", "싱가포르", ["싱가포르", "싱가폴"]),
        ("KUL", "쿠알라룸푸르", ["쿠알라룸푸르", "말레이시아"]),
        ("BKI", "코타키나발루", ["코타키나발루", "코키"]),
        ("DPS", "발리 덴파사르", ["발리", "덴파사르"]),
        ("CGK", "자카르타", ["자카르타"]),
        ("VTE", "비엔티안", ["비엔티안", "라오스"]),
        ("PNH", "프놈펜", ["프놈펜"]),
        // Pacific and Oceania
        ("GUM", "괌", ["괌"]),
        ("SPN", "사이판", ["사이판"]),
        ("HNL", "하와이 호놀룰루", ["하와이", "호놀룰루"]),
        ("SYD", "시드니", ["시드니", "호주"]),
        ("MEL", "멜버른", ["멜버른", "멜번"]),
        ("BNE", "브리즈번", ["브리즈번"]),
        ("AKL", "오클랜드", ["오클랜드", "뉴질랜드"]),
        // Americas
        ("JFK", "뉴욕 JFK", ["뉴욕"]),
        ("EWR", "뉴욕 뉴어크", ["뉴어크"]),
        ("LAX", "로스앤젤레스", ["로스앤젤레스", "로스엔젤레스", "la", "엘에이"]),
        ("SFO", "샌프란시스코", ["샌프란시스코"]),
        ("SEA", "시애틀", ["시애틀"]),
        ("LAS", "라스베이거스", ["라스베이거스", "라스베가스"]),
        ("ORD", "시카고", ["시카고"]),
        ("ATL", "애틀랜타", ["애틀랜타"]),
        ("IAD", "워싱턴 덜레스", ["워싱턴"]),
        ("BOS", "보스턴", ["보스턴"]),
        ("DFW", "댈러스", ["댈러스", "달라스"]),
        ("YVR", "밴쿠버", ["밴쿠버"]),
        ("YYZ", "토론토", ["토론토"]),
        // Europe, Middle East, Central and South Asia
        ("CDG", "파리 샤를드골", ["파리", "프랑스"]),
        ("LHR", "런던 히스로", ["런던", "영국"]),
        ("FRA", "프랑크푸르트", ["프랑크푸르트"]),
        ("MUC", "뮌헨", ["뮌헨"]),
        ("FCO", "로마", ["로마"]),
        ("MXP", "밀라노", ["밀라노"]),
        ("BCN", "바르셀로나", ["바르셀로나"]),
        ("MAD", "마드리드", ["마드리드"]),
        ("AMS", "암스테르담", ["암스테르담"]),
        ("ZRH", "취리히", ["취리히", "스위스"]),
        ("VIE", "빈", ["빈", "비엔나"]),
        ("PRG", "프라하", ["프라하"]),
        ("BUD", "부다페스트", ["부다페스트"]),
        ("LIS", "리스본", ["리스본"]),
        ("HEL", "헬싱키", ["헬싱키"]),
        ("IST", "이스탄불", ["이스탄불", "튀르키예", "터키"]),
        ("DXB", "두바이", ["두바이"]),
        ("DOH", "도하", ["도하"]),
        ("AUH", "아부다비", ["아부다비"]),
        ("DEL", "델리", ["델리", "뉴델리"]),
        ("ALA", "알마티", ["알마티"]),
        ("TAS", "타슈켄트", ["타슈켄트"]),
    ]

    private static let names: [String: String] = Dictionary(uniqueKeysWithValues: (korea + abroad).map { ($0.0, $0.1) })
    private static let domesticCodes = Set(korea.map(\.0))
    /// normalized alias or Korean name → code. `uniquingKeysWith` keeps the first: the table order decides a tie, and a
    /// test checks there is none.
    private static let byAlias: [String: String] = Dictionary((korea + abroad).flatMap { row in
        ([row.1] + row.2).map { (normalize($0), row.0) }
    }, uniquingKeysWith: { first, _ in first })

    /// Every row, for the tests (each alias must lead back to its own code).
    static var table: [(code: String, name: String, aliases: [String])] { (korea + abroad).map { ($0.0, $0.1, $0.2) } }

    static func isKnown(_ code: String) -> Bool { names[code.uppercased()] != nil }
    static func isDomestic(_ code: String) -> Bool { domesticCodes.contains(code.uppercased()) }
    static func name(for code: String) -> String? { names[code.uppercased()] }

    /// "제주", "김포공항", "인천 국제공항", "LA", or a known code itself ("cju").
    static func code(for name: String) -> String? {
        let key = normalize(name)
        if key.count == 3, isKnown(key) { return key.uppercased() }
        if let hit = byAlias[key] { return hit }
        for suffix in ["국제공항", "공항"] where key.hasSuffix(suffix) {
            if let hit = byAlias[String(key.dropLast(suffix.count))] { return hit }
        }
        return nil
    }

    /// Both ends from the owner's words, with the two pairs that change the airport: 서울 to a Korean airport flies from
    /// 김포, and 김포 abroad goes to the city airport 김포 actually serves (하네다, 훙차오, 쑹산).
    static func route(_ from: String, _ to: String) -> (from: String, to: String)? {
        guard var a = code(for: from), var b = code(for: to) else { return nil }
        if normalize(from) == "서울", isDomestic(b), b != "GMP" { a = "GMP" }
        if a == "GMP", let paired = gimpoPairs[b] { b = paired }
        return (a, b)
    }

    private static let gimpoPairs = ["NRT": "HND", "PVG": "SHA", "TPE": "TSA"]

    /// Lowercased, without spaces, so "김포 공항" and "Jin Air" match their table rows.
    static func normalize(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace }
    }
}

// MARK: - Naver Shopping API (price watch)

/// One row of shop.json, cleaned: the title without Naver's <b> highlight tags, the lowest price in won.
struct NaverShopItem: Codable, Equatable {
    var title: String
    var price: Int
    var mall: String
    var link: URL?
    var productID: String
}

struct NaverShopCredentials: Equatable {
    var clientID: String
    var clientSecret: String
}

enum NaverShopError: Error, Equatable {
    case noKey       // the owner has not pasted a key: the card explains developers.naver.com
    case badKey      // 401: id or secret wrong
    case notEnabled  // 403: the application on developers.naver.com does not have 검색 turned on
    case limit       // 429: the key's daily search calls are used up (25,000 a day); a goal pauses until tomorrow
    case network
    case server(Int)

    var message: String {
        switch self {
        case .noKey: return L("네이버 쇼핑 가격을 보려면 developers.naver.com에서 검색 API 키를 받아 비서 설정에 넣어 주세요.")
        case .badKey: return L("네이버 검색 API 키가 맞지 않아요. Client ID와 Secret을 다시 확인해 주세요.")
        case .notEnabled: return L("네이버 개발자센터 애플리케이션에서 '검색' API 사용이 꺼져 있어요.")
        case .limit: return L("네이버 검색 API 하루 사용 한도를 다 썼어요. 내일 다시 확인할게요.")
        case .network: return L("네이버 쇼핑에 연결하지 못했어요. 인터넷 연결을 확인해 주세요.")
        case .server(let code): return L("네이버 쇼핑이 답하지 못했어요 (\(code)).")
        }
    }
}

/// openapi.naver.com shop search with the owner's own key (sent in headers only). The goal runner calls `lowest` with
/// no model and no AI usage.
struct NaverShopClient {
    /// Reads the Keychain: call `lowest` off main (an unsigned rebuild may show the allow dialog).
    var credentials: () -> NaverShopCredentials? = NaverShopKeychain.load
    var transport: BYOAPIClient.Transport = { try await BYOAPIClient.session.data(for: $0) }

    static let display = 5

    static func request(_ query: String, _ key: NaverShopCredentials) -> URLRequest {
        let url = URL(string: "https://openapi.naver.com/v1/search/shop.json?query=\(KoreanLinks.encode(query))&display=\(display)&sort=asc")!
        var r = URLRequest(url: url, timeoutInterval: BYOAPIClient.timeout)
        r.setValue(key.clientID, forHTTPHeaderField: "X-Naver-Client-Id")
        r.setValue(key.clientSecret, forHTTPHeaderField: "X-Naver-Client-Secret")
        return r
    }

    /// The 5 cheapest listings, cheapest first.
    /// ponytail: sort=asc is the API's price order, so a cheap case or cable can top a phone search; the owner words
    /// the query ("아이폰 16 128GB 자급제"). Filter by category or a price floor if watches keep catching accessories.
    func lowest(_ query: String) async throws -> [NaverShopItem] {
        guard let key = credentials() else { throw NaverShopError.noKey }
        let data: Data, response: URLResponse
        do { (data, response) = try await transport(Self.request(query, key)) } catch { throw NaverShopError.network }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status: status) }
        guard let items = Self.parse(data) else { throw NaverShopError.server(status) }
        return items
    }

    static func failure(status: Int) -> NaverShopError {
        switch status {
        case 401: return .badKey
        case 403: return .notEnabled
        case 429: return .limit
        default: return .server(status)
        }
    }

    /// nil when the body is not shop.json; rows without a positive price are dropped (nothing to watch).
    static func parse(_ data: Data) -> [NaverShopItem]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["items"] as? [[String: Any]] else { return nil }
        return rows.compactMap { r in
            guard let price = Int(r["lprice"] as? String ?? ""), price > 0 else { return nil }
            return NaverShopItem(title: plain(r["title"] as? String ?? ""), price: price,
                                 mall: plain(r["mallName"] as? String ?? ""),
                                 link: (r["link"] as? String).flatMap(URL.init(string:)),
                                 productID: r["productId"] as? String ?? "")
        }
    }

    /// Drops tags (<b>) and decodes the few entities shop.json uses. &amp; last, so "&amp;lt;" stays "&lt;".
    static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The owner's Naver developer Client ID and Secret, like AIKeychain: one Keychain item each under its own service,
/// this Mac only, never in UserDefaults or logs.
enum NaverShopKeychain {
    /// A var only so tests use their own items, never the owner's.
    static var service = "com.jelly.dogmonitor.naver.shop"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func save(_ key: NaverShopCredentials) throws {
        for (account, value) in [("client-id", key.clientID), ("client-secret", key.clientSecret)] {
            SecItemDelete(query(account) as CFDictionary)
            var item = query(account)
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly   // stays on this Mac
            item[kSecAttrLabel as String] = "캐릭모니터 네이버 검색 API \(account)"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
    }

    /// Reads data: may show the Keychain allow dialog on an unsigned rebuild, so call it off main.
    static func load() -> NaverShopCredentials? {
        func read(_ account: String) -> String? {
            var q = query(account)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
                  let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
            return value
        }
        guard let id = read("client-id"), let secret = read("client-secret") else { return nil }
        return NaverShopCredentials(clientID: id, clientSecret: secret)
    }

    /// From the attributes only (no data read, no allow dialog). Safe on main.
    static func exists() -> Bool {
        var q = query("client-secret")
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    static func delete() { ["client-id", "client-secret"].forEach { SecItemDelete(query($0) as CFDictionary) } }
}
