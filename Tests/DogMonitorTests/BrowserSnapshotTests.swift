#if !MAS
import AppKit
import XCTest
@testable import DogMonitor

/// The agent browser on fixture pages (qa/agent-fixtures), offscreen: no window, no cookies, no real network (the
/// .invalid hosts never resolve).
@MainActor
final class BrowserSnapshotTests: XCTestCase {
    private func open(_ name: String, at path: String) async throws -> (AgentBrowser, PageSnapshot) {
        _ = NSApplication.shared
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("qa/agent-fixtures/\(name).html")
        let b = AgentBrowser(offscreen: true)
        let s = try await b.load(html: String(contentsOf: file, encoding: .utf8), baseURL: URL(string: "https://shop.example.invalid\(path)")!)
        return (b, s)
    }

    private func ref(_ s: PageSnapshot, _ label: String) throws -> String {
        try XCTUnwrap(s.elements.first { $0.label == label }?.ref, "no '\(label)' in \(s.elements.map(\.label))")
    }

    func testCartElements() async throws {
        let (_, s) = try await open("cart", at: "/cart")
        let labels = s.elements.map(\.label)
        for l in ["장바구니 담기", "쿠폰 받기", "구매하기", "다른 상품 보기", "주문 내역", "선택", "홈"] { XCTAssertTrue(labels.contains(l), l) }
        for l in ["숨은 버튼", "크기 없는 버튼", "가린 버튼"] { XCTAssertFalse(labels.contains(l), l) }
        XCTAssertEqual(Set(s.elements.map(\.ref)).count, s.elements.count)
        XCTAssertTrue(s.elements.allSatisfy { $0.ref.range(of: #"^e\d+$"#, options: .regularExpression) != nil })
        XCTAssertEqual(s.elements.first { $0.label == "주문 내역" }?.href, "https://shop.example.invalid/mypage/order/list")
        XCTAssertEqual(s.elements.first { $0.label == "선택" }?.role, "checkbox")   // the hidden input, reached through its label
        let qty = try XCTUnwrap(s.elements.first { $0.role == "select" })
        XCTAssertEqual(qty.options, ["1개", "2개", "3개"])
        XCTAssertEqual(qty.value, "1개")
        // The pay stop: 구매하기 and the icon-only submit into /checkout hit, 장바구니 담기 does not; the cart page itself is fine.
        let icon = try XCTUnwrap(s.elements.first { $0.label.isEmpty && $0.formAction != nil })
        XCTAssertEqual(icon.formAction, "https://shop.example.invalid/checkout")
        XCTAssertNotNil(CheckoutDetector.element(icon))
        XCTAssertNotNil(CheckoutDetector.element(try XCTUnwrap(s.elements.first { $0.label == "구매하기" })))
        XCTAssertNil(CheckoutDetector.element(try XCTUnwrap(s.elements.first { $0.label == "장바구니 담기" })))
        XCTAssertNil(CheckoutDetector.page(url: s.url, title: s.title, frames: s.frames))
        XCTAssertTrue(s.forModel().contains("장바구니 담기"))
    }

    func testSignatureStableThenChangesWithText() async throws {
        let (b, s1) = try await open("cart", at: "/cart")
        let coupon = try ref(s1, "쿠폰 받기")
        let s2 = try await b.snapshot()
        XCTAssertEqual(s1.elements, s2.elements)   // refs stable while the page lives
        let before = try await b.signature(ref: coupon)
        let again = try await b.signature(ref: coupon)
        XCTAssertNotNil(before)
        XCTAssertEqual(before, again)
        let s3 = try await b.click(ref: coupon)   // offscreen: the DOM click fallback
        XCTAssertEqual(s3.element(coupon)?.label, "쿠폰 받음")
        let after = try await b.signature(ref: coupon)
        XCTAssertNotEqual(before, after)
        let gone = try await b.signature(ref: "e999")
        XCTAssertNil(gone)
    }

    func testCheckboxThroughLabelAndTargetBlankStaysHere() async throws {
        let (b, s) = try await open("cart", at: "/cart")
        let checked = try await b.click(ref: try ref(s, "선택"))
        XCTAssertEqual(checked.elements.first { $0.label == "선택" }?.value, "checked")
        do {
            _ = try await b.click(ref: try ref(s, "다른 상품 보기"))   // target=_blank: same view, and .invalid fails to load
            XCTFail("expected a load error")
        } catch let e as BrowserError {
            if case .load = e {} else { XCTFail("\(e)") }
        }
    }

    func testSensitiveFieldsAreAbsent() async throws {
        let (b, s) = try await open("card-form", at: "/member")
        XCTAssertEqual(s.elements.map(\.label).sorted(), ["Search cardigans", "받는 분", "배송 메모", "저장"].sorted())
        XCTAssertEqual(s.elements.first { $0.label == "받는 분" }?.value, "홍길동")
        let model = s.forModel(limit: 20000)
        for secret in ["hunter2secret", "4111111111111111", "5555444433331111", "4000123412341234", "987", "482913", "900101", "2468", "135790", "246810"] {
            XCTAssertFalse(model.contains(secret), secret)
        }
        // A field that turns into a password after the snapshot is refused, not typed into.
        let q = try ref(s, "Search cardigans")
        _ = try await b.webView.evaluateJavaScript("document.querySelector('[name=q]').type = 'password'; 'ok'")
        do {
            _ = try await b.type(ref: q, text: "1234", submit: false)
            XCTFail("typed into a password field")
        } catch let e as BrowserError {
            XCTAssertEqual(e, .sensitive)
        }
        do {
            _ = try await b.click(ref: "e999")
            XCTFail("clicked a missing ref")
        } catch let e as BrowserError {
            XCTAssertEqual(e, .noElement("e999"))
        }
    }

    func testPGFramePage() async throws {
        let (_, s) = try await open("pg-iframe", at: "/product/1")
        XCTAssertEqual(s.frames, ["https://stdpay.inicis.invalid/pay"])
        XCTAssertNotNil(CheckoutDetector.page(url: s.url, title: s.title, frames: s.frames))
        XCTAssertNotNil(CheckoutDetector.element(try XCTUnwrap(s.elements.first { $0.label == "바로 구매" })))
    }

    func testSearchTypeSubmitSelectFind() async throws {
        let (b, s) = try await open("search", at: "/")
        let box = try ref(s, "검색어")
        let typed = try await b.type(ref: box, text: "하기스 4단계", submit: true)
        XCTAssertEqual(typed.element(box)?.value, "하기스 4단계")
        XCTAssertTrue(typed.text.contains("검색 결과: 하기스 4단계"), typed.text)
        let sort = try XCTUnwrap(s.elements.first { $0.role == "select" })
        XCTAssertEqual(sort.options, ["랭킹순", "낮은가격순"])
        let sorted = try await b.select(ref: sort.ref, value: "낮은가격순")
        XCTAssertEqual(sorted.element(sort.ref)?.value, "낮은가격순")
        XCTAssertEqual(sorted.title, "정렬 low")
        do {
            _ = try await b.select(ref: try ref(s, "검색어"), value: "x")
            XCTFail("selected in a text field")
        } catch let e as BrowserError {
            if case .blocked = e {} else { XCTFail("\(e)") }
        }
        let found = try await b.find("맥스드라이")
        XCTAssertTrue(found.contains("하기스 맥스드라이 3단계"), found)
        XCTAssertTrue(found.contains(try ref(s, "상품 보기")), found)
        let none = try await b.find("없는 글자")
        XCTAssertTrue(none.contains("찾지 못했어요"))
    }

    func testOnlyWebAddressesOpen() async throws {
        _ = NSApplication.shared
        let b = AgentBrowser(offscreen: true)
        for u in ["file:///etc/hosts", "data:text/html,hi", "javascript:alert(1)"] {
            do {
                _ = try await b.open(URL(string: u)!)
                XCTFail(u)
            } catch let e as BrowserError {
                if case .blocked = e {} else { XCTFail("\(u) \(e)") }
            }
        }
        do {
            _ = try await b.snapshot()
            XCTFail("snapshot with no page")
        } catch let e as BrowserError {
            XCTAssertEqual(e, .noPage)
        }
    }

    func testHandOffStopsTheAgentUntilNextRun() async throws {
        let (b, _) = try await open("search", at: "/")
        b.handOff(reason: "결제는 직접 해 주세요", highlight: "e1")
        XCTAssertTrue(b.ownerHasIt)
        do {
            _ = try await b.snapshot()
            XCTFail("agent kept going")
        } catch let e as BrowserError {
            XCTAssertEqual(e, .ownerHasIt)
        }
        b.beginRun()
        let s = try await b.snapshot()
        XCTAssertFalse(s.elements.isEmpty)
    }
}
#endif
