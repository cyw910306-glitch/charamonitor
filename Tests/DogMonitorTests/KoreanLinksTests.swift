import XCTest
@testable import DogMonitor

/// 쇼핑과 항공권 links: every builder's exact string, the airport table, the host allowlist (look-alikes must fail), and
/// the Naver shop API with a fake HTTP layer and a test-only Keychain service.
final class KoreanLinksTests: XCTestCase {
    /// A local midnight, as FlightQuery holds it.
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: y, month: m, day: d))!
    }

    private func flight(_ from: String, _ to: String, back: Bool = true, adults: Int = 1) -> FlightQuery {
        FlightQuery(from: from, to: to, depart: day(2026, 11, 10), returnDate: back ? day(2026, 11, 15) : nil, adults: adults)
    }

    // MARK: Shopping

    func testShopLinks() {
        XCTAssertEqual(KoreanLinks.naverShopping("에어팟 프로").absoluteString,
                       "https://search.shopping.naver.com/ns/search?query=%EC%97%90%EC%96%B4%ED%8C%9F%20%ED%94%84%EB%A1%9C")
        XCTAssertEqual(KoreanLinks.coupang("에어팟").absoluteString, "https://www.coupang.com/np/search?q=%EC%97%90%EC%96%B4%ED%8C%9F")
        // &, +, = and # stay inside the value.
        XCTAssertEqual(KoreanLinks.coupang(" A&B+C=D#1 ").absoluteString, "https://www.coupang.com/np/search?q=A%26B%2BC%3DD%231")
        XCTAssertEqual(KoreanLinks.shop("x", store: .coupang), KoreanLinks.coupang("x"))
        XCTAssertEqual(KoreanLinks.shop("x", store: .naver), KoreanLinks.naverShopping("x"))
    }

    // MARK: Flights

    func testNaverFlights() {
        XCTAssertEqual(KoreanLinks.naverFlights(flight("GMP", "CJU"))?.absoluteString,
                       "https://flight.naver.com/flights/domestic/GMP-CJU-20261110/CJU-GMP-20261115?adult=1&fareType=YC")
        XCTAssertEqual(KoreanLinks.naverFlights(flight("icn", "nrt", back: false, adults: 2))?.absoluteString,
                       "https://flight.naver.com/flights/international/ICN-NRT-20261110?adult=2&fareType=Y")
        XCTAssertEqual(KoreanLinks.naverFlights(flight("ICN", "CJU", back: false))?.absoluteString,
                       "https://flight.naver.com/flights/domestic/ICN-CJU-20261110?adult=1&fareType=YC")
        // Passengers stay within what the site takes.
        XCTAssertEqual(KoreanLinks.naverFlights(flight("GMP", "CJU", back: false, adults: 0))?.absoluteString,
                       "https://flight.naver.com/flights/domestic/GMP-CJU-20261110?adult=1&fareType=YC")
        XCTAssertNil(KoreanLinks.naverFlights(flight("GMP", "XXX")))
    }

    func testSkyscanner() {
        XCTAssertEqual(KoreanLinks.skyscanner(flight("ICN", "BKK"))?.absoluteString,
                       "https://www.skyscanner.co.kr/transport/flights/icn/bkk/261110/261115/?adultsv2=1&cabinclass=economy&rtn=1")
        XCTAssertEqual(KoreanLinks.skyscanner(flight("GMP", "CJU", back: false, adults: 3))?.absoluteString,
                       "https://www.skyscanner.co.kr/transport/flights/gmp/cju/261110/?adultsv2=3&cabinclass=economy&rtn=0")
        XCTAssertNil(KoreanLinks.skyscanner(flight("ZZZ", "CJU")))
    }

    func testGoogleFlights() {
        XCTAssertEqual(KoreanLinks.googleFlights(flight("GMP", "CJU"))?.absoluteString,
                       "https://www.google.com/travel/flights?q=Flights%20to%20CJU%20from%20GMP%20on%202026-11-10%20through%202026-11-15&hl=ko&curr=KRW")
        XCTAssertEqual(KoreanLinks.googleFlights(flight("icn", "cdg", back: false))?.absoluteString,
                       "https://www.google.com/travel/flights?q=Flights%20to%20CDG%20from%20ICN%20on%202026-11-10&hl=ko&curr=KRW")
        XCTAssertNil(KoreanLinks.googleFlights(flight("GMP", "QQQ")))
    }

    func testAirlineHomes() {
        let expected: [(String, String)] = [
            ("대한항공", "https://www.koreanair.com/"), ("아시아나", "https://flyasiana.com/"), ("진에어", "https://www.jinair.com/"),
            ("제주항공", "https://www.jejuair.net/"), ("티웨이", "https://www.trinityairways.com/"),
            ("트리니티항공", "https://www.trinityairways.com/"), ("에어부산", "https://www.airbusan.com/"),
            ("에어서울", "https://flyairseoul.com/"), ("Jin Air", "https://www.jinair.com/"), ("KE", "https://www.koreanair.com/"),
        ]
        for (name, url) in expected { XCTAssertEqual(KoreanLinks.airline(name)?.absoluteString, url, name) }
        XCTAssertNil(KoreanLinks.airline("루프트한자"))
        // Every home page is one the app may open.
        for a in Airline.allCases { XCTAssertTrue(KoreanLinks.isAllowed(a.home), a.rawValue) }
    }

    // MARK: Airports

    func testAirportLookups() {
        let cases: [(String, String)] = [
            ("제주", "CJU"), ("제주도", "CJU"), ("제주공항", "CJU"), ("김포", "GMP"), ("김포 공항", "GMP"), ("인천", "ICN"),
            ("인천국제공항", "ICN"), ("김해", "PUS"), ("부산", "PUS"), ("대구", "TAE"), ("청주", "CJJ"), ("광주", "KWJ"),
            ("여수", "RSU"), ("양양", "YNY"), ("도쿄", "NRT"), ("하네다", "HND"), ("오사카", "KIX"), ("후쿠오카", "FUK"),
            ("삿포로", "CTS"), ("오키나와", "OKA"), ("방콕", "BKK"), ("다낭", "DAD"), ("세부", "CEB"), ("괌", "GUM"),
            ("타이베이", "TPE"), ("타이페이", "TPE"), ("홍콩", "HKG"), ("싱가포르", "SIN"), ("파리", "CDG"), ("런던", "LHR"),
            ("뉴욕", "JFK"), ("LA", "LAX"), ("엘에이", "LAX"), ("하와이", "HNL"), ("cju", "CJU"), ("NRT", "NRT"),
        ]
        for (name, code) in cases { XCTAssertEqual(Airports.code(for: name), code, name) }
        XCTAssertNil(Airports.code(for: "아틀란티스"))
        XCTAssertNil(Airports.code(for: "XYZ"))
        XCTAssertNil(Airports.code(for: ""))

        XCTAssertTrue(Airports.isKnown("CJU"))
        XCTAssertTrue(Airports.isKnown("hnd"))
        XCTAssertFalse(Airports.isKnown("XYZ"))
        XCTAssertEqual(Airports.name(for: "CJU"), "제주")
        XCTAssertEqual(Airports.name(for: "hnd"), "도쿄 하네다")
        XCTAssertNil(Airports.name(for: "XYZ"))
        XCTAssertTrue(Airports.isDomestic("GMP"))
        XCTAssertFalse(Airports.isDomestic("NRT"))
    }

    func testTableIsWholeAndUnambiguous() {
        let t = Airports.table
        XCTAssertGreaterThanOrEqual(t.count, 80)
        XCTAssertEqual(Set(t.map(\.code)).count, t.count, "duplicate code")
        for row in t {
            XCTAssertTrue(row.code.count == 3 && row.code == row.code.uppercased(), row.code)
            // Each word leads back to its own row (a word shared by two rows would answer the first one).
            for word in [row.name] + row.aliases { XCTAssertEqual(Airports.code(for: word), row.code, "\(word) -> \(row.code)") }
        }
    }

    func testRouteUsesTheAirportsThatFly() {
        XCTAssertTrue(Airports.route("서울", "제주")! == ("GMP", "CJU"))
        XCTAssertTrue(Airports.route("서울", "도쿄")! == ("ICN", "NRT"))
        XCTAssertTrue(Airports.route("김포", "도쿄")! == ("GMP", "HND"))
        XCTAssertTrue(Airports.route("김포", "상하이")! == ("GMP", "SHA"))
        XCTAssertTrue(Airports.route("김포", "타이베이")! == ("GMP", "TSA"))
        XCTAssertTrue(Airports.route("인천", "도쿄")! == ("ICN", "NRT"))
        XCTAssertTrue(Airports.route("부산", "후쿠오카")! == ("PUS", "FUK"))
        XCTAssertNil(Airports.route("서울", "아틀란티스"))
    }

    // MARK: Allowlist

    func testAllowlist() {
        let yes = [
            "https://www.coupang.com/vp/products/123", "https://coupang.com/", "https://m.coupang.com/nm/search?q=a",
            "https://search.shopping.naver.com/catalog/1", "https://shopping.naver.com/ns/home",
            "https://smartstore.naver.com/main/products/1", "https://flight.naver.com/flights/domestic/GMP-CJU-20261110",
            "https://www.skyscanner.co.kr/transport/flights/icn/nrt/261110/", "https://www.google.com/travel/flights?q=x",
            "https://google.com/travel", "https://www.koreanair.com/", "https://flyasiana.com/", "https://www.jinair.com/",
            "https://www.jejuair.net/", "https://www.twayair.com/", "https://www.trinityairways.com/",
            "https://www.airbusan.com/", "https://flyairseoul.com/", "https://WWW.COUPANG.COM./x",
        ]
        let no = [
            "https://coupang.com.evil.io/", "https://evilcoupang.com/", "https://coupang.co/", "http://www.coupang.com/",
            "https://www.coupang.com@evil.io/", "https://user:pw@www.coupang.com/", "https://naver.com/",
            "https://www.naver.com/", "https://blog.naver.com/x", "https://pay.naver.com/", "https://shopping.naver.com.evil.io/",
            "https://flight-naver.com/", "https://skyscanner.co.kr.attacker.net/", "https://www.skyscanner.com/",
            "https://www.google.com/search?q=x", "https://www.google.com/travelx", "https://travel.google.com.evil.io/travel",
            "https://evil.io/travel", "https://www.google.co.kr/travel/flights", "https://koreanair.com.evil.io/",
            "javascript:alert(1)", "file:///etc/passwd", "https:///nohost",
        ]
        for s in yes { XCTAssertTrue(KoreanLinks.isAllowed(URL(string: s)!), s) }
        for s in no {
            guard let u = URL(string: s) else { continue }   // unparseable is never opened either
            XCTAssertFalse(KoreanLinks.isAllowed(u), s)
        }
        // Every builder's output is allowed.
        let q = flight("GMP", "CJU")
        for u in [KoreanLinks.naverShopping("a"), KoreanLinks.coupang("a"), KoreanLinks.naverFlights(q)!,
                  KoreanLinks.skyscanner(q)!, KoreanLinks.googleFlights(q)!] {
            XCTAssertTrue(KoreanLinks.isAllowed(u), u.absoluteString)
        }
    }

    // MARK: Naver shop API

    private static let fixture = #"""
    {"lastBuildDate":"Mon, 05 Oct 2026 23:00:00 +0900","total":1234,"start":1,"display":3,"items":[
     {"title":"Apple <b>에어팟</b> 프로 2세대 &amp; 케이스","link":"https:\/\/smartstore.naver.com\/main\/products\/111","image":"https:\/\/shopping-phinf.pstatic.net\/a.jpg","lprice":"259000","hprice":"","mallName":"애플스토어 &lt;공식&gt;","productId":"111","productType":"2","brand":"Apple","maker":"Apple","category1":"디지털\/가전","category2":"음향가전","category3":"이어폰","category4":""},
     {"title":"<b>에어팟</b> 정품","link":"https:\/\/search.shopping.naver.com\/catalog\/222","image":"","lprice":"265000","hprice":"300000","mallName":"네이버","productId":"222","productType":"1","brand":"","maker":"","category1":"","category2":"","category3":"","category4":""},
     {"title":"가격 없음","link":"https:\/\/x","image":"","lprice":"","hprice":"","mallName":"x","productId":"333"}
    ]}
    """#

    private func ok(_ json: String, sent: @escaping (URLRequest) -> Void = { _ in }) -> BYOAPIClient.Transport {
        { r in sent(r); return (Data(json.utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
    }

    private func status(_ code: Int) -> BYOAPIClient.Transport {
        { r in (Data(#"{"errorMessage":"x","errorCode":"024"}"#.utf8), HTTPURLResponse(url: r.url!, statusCode: code, httpVersion: nil, headerFields: nil)!) }
    }

    private let key = NaverShopCredentials(clientID: "ID-123", clientSecret: "SECRET-456")

    func testParsesShopJSON() throws {
        let items = try XCTUnwrap(NaverShopClient.parse(Data(Self.fixture.utf8)))
        XCTAssertEqual(items, [
            NaverShopItem(title: "Apple 에어팟 프로 2세대 & 케이스", price: 259000, mall: "애플스토어 <공식>",
                          link: URL(string: "https://smartstore.naver.com/main/products/111"), productID: "111"),
            NaverShopItem(title: "에어팟 정품", price: 265000, mall: "네이버",
                          link: URL(string: "https://search.shopping.naver.com/catalog/222"), productID: "222"),
        ])
        XCTAssertNil(NaverShopClient.parse(Data("<html>".utf8)))
        XCTAssertEqual(NaverShopClient.parse(Data(#"{"items":[]}"#.utf8)), [])
        XCTAssertEqual(NaverShopClient.plain("<b>a</b> &amp;lt; b"), "a &lt; b")
    }

    func testRequestSendsTheKeyInHeadersNeverTheURL() async throws {
        var seen: URLRequest?
        let client = NaverShopClient(credentials: { self.key }, transport: ok(Self.fixture) { seen = $0 })
        let items = try await client.lowest("에어팟 프로")
        XCTAssertEqual(items.map(\.price), [259000, 265000])
        let r = try XCTUnwrap(seen)
        XCTAssertEqual(r.url?.absoluteString,
                       "https://openapi.naver.com/v1/search/shop.json?query=%EC%97%90%EC%96%B4%ED%8C%9F%20%ED%94%84%EB%A1%9C&display=5&sort=asc")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Naver-Client-Id"), "ID-123")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Naver-Client-Secret"), "SECRET-456")
        XCTAssertFalse(r.url!.absoluteString.contains("SECRET"))
        XCTAssertEqual(r.httpMethod ?? "GET", "GET")
    }

    func testErrorsSayWhatToDo() async {
        for (code, expected) in [(401, NaverShopError.badKey), (403, .notEnabled), (429, .limit), (500, .server(500)), (400, .server(400))] {
            do {
                _ = try await NaverShopClient(credentials: { self.key }, transport: status(code)).lowest("a")
                XCTFail("\(code)")
            } catch { XCTAssertEqual(error as? NaverShopError, expected, "\(code)") }
        }
        XCTAssertTrue(NaverShopError.badKey.message.contains("키"))
        XCTAssertTrue(NaverShopError.limit.message.contains("한도"))
        XCTAssertTrue(NaverShopError.noKey.message.contains("developers.naver.com"))

        var called = false
        do {
            _ = try await NaverShopClient(credentials: { nil }, transport: { r in called = true; return try await self.ok("{}")(r) }).lowest("a")
            XCTFail("no key")
        } catch { XCTAssertEqual(error as? NaverShopError, .noKey) }
        XCTAssertFalse(called, "no request without a key")

        do {
            _ = try await NaverShopClient(credentials: { self.key }, transport: { _ in throw URLError(.notConnectedToInternet) }).lowest("a")
            XCTFail("offline")
        } catch { XCTAssertEqual(error as? NaverShopError, .network) }

        do {
            _ = try await NaverShopClient(credentials: { self.key }, transport: ok("<html>")).lowest("a")
            XCTFail("not json")
        } catch { XCTAssertEqual(error as? NaverShopError, .server(200)) }
    }

    func testKeychainRoundTripUnderATestService() throws {
        let saved = NaverShopKeychain.service
        NaverShopKeychain.service = "com.jelly.dogmonitor.test.naver-\(UUID().uuidString)"
        defer { NaverShopKeychain.delete(); NaverShopKeychain.service = saved }

        XCTAssertNil(NaverShopKeychain.load())
        XCTAssertFalse(NaverShopKeychain.exists())
        try NaverShopKeychain.save(key)
        XCTAssertTrue(NaverShopKeychain.exists())
        XCTAssertEqual(NaverShopKeychain.load(), key)
        try NaverShopKeychain.save(NaverShopCredentials(clientID: "new", clientSecret: "s2"))
        XCTAssertEqual(NaverShopKeychain.load(), NaverShopCredentials(clientID: "new", clientSecret: "s2"))
        NaverShopKeychain.delete()
        XCTAssertNil(NaverShopKeychain.load())
        XCTAssertFalse(NaverShopKeychain.exists())
    }
}
