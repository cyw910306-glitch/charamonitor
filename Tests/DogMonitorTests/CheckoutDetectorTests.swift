import XCTest
@testable import DogMonitor

/// Regression corpus for the pay/order stop (design section 3). Add a line whenever a real site slips through.
final class CheckoutDetectorTests: XCTestCase {
    private func button(_ label: String, action: String? = nil, type: String? = nil) -> PageElement {
        PageElement(ref: "e1", role: type == nil ? "button" : "input", label: label, formMethod: action == nil ? nil : "post",
                    formAction: action, inputType: type)
    }

    func testPayButtonsHit() {
        let labels = ["결제", "결제하기", "32,900원 결제하기", "구매하기", "바로 구매", "바로구매", "지금 구매", "주문하기",
                      "총 2건 주문하기", "예약 확정", "예약확정", "발권", "발권하기", "송금", "송금하기", "이체", "계좌 이체",
                      "쿠페이로 결제", "네이버페이 구매", "N pay 구매", "카카오페이", "Pay", "Pay now", "PAY NOW", "Buy now",
                      "Buy it now", "Buy", "Place order", "Place your order", "Book now", "Checkout", "Proceed to checkout",
                      "Check out", "Complete purchase", "Confirm and pay", "Apple Pay", "간편결제", "혜택 받고 결제하기", "자동이체 신청"]
        for l in labels { XCTAssertNotNil(CheckoutDetector.element(button(l)), l) }
        XCTAssertGreaterThanOrEqual(labels.count, 30)
    }

    func testIconOnlyButtonInCheckoutFormHits() {
        XCTAssertNotNil(CheckoutDetector.element(button("", action: "https://checkout.coupang.com/ssr/desktop/order")))
        XCTAssertNotNil(CheckoutDetector.element(button("", action: "https://shop.example.com/checkout")))
        XCTAssertNotNil(CheckoutDetector.element(button("다음", action: "https://order.pay.naver.com/orderSheet/1")))
        XCTAssertNotNil(CheckoutDetector.element(button("확인", action: "https://shop.example.com/payment/confirm", type: "submit")))
        XCTAssertNotNil(CheckoutDetector.element(button("", action: "https://stdpay.inicis.com/pay")))
        // A text field in that form is not a press.
        var field = button("", action: "https://shop.example.com/checkout", type: "text")
        field.role = "input"
        XCTAssertNil(CheckoutDetector.element(field))
    }

    func testOrdinaryButtonsMiss() {
        let labels = ["장바구니 담기", "장바구니", "쿠폰 받기", "쿠폰 받음", "검색", "Search", "찜하기", "상품 상세", "리뷰 보기",
                      "구매 후기", "다음", "로그인", "더보기", "필터", "낮은가격순", "예약하기", "주문 내역", "Order history",
                      "Border collie", "Paypal 안내", "Repay", "선택", "Add to cart", "Bookmarks", "",
                      // Seen on real pages in the spike (docs/AGENT-SPIKE.md):
                      "매일 진행되는 네이버페이 적립이벤트", "리콜 대상 보조배터리 항공기 운송 금지", "결제 내역", "결제수단 안내",
                      "카카오페이 혜택 모아보기 이벤트"]
        for l in labels { XCTAssertNil(CheckoutDetector.element(button(l)), l) }
        XCTAssertNil(CheckoutDetector.element(button("", action: "https://www.coupang.com/np/search")))
        XCTAssertNil(CheckoutDetector.element(button("검색", action: "https://example.com/border/search")))
        XCTAssertGreaterThanOrEqual(labels.count, 20)
    }

    func testCheckoutPages() {
        let hits: [(String, String)] = [
            ("https://checkout.coupang.com/ssr/desktop/order/123", ""),
            ("https://www.11st.co.kr/order/OrderInfo.tmall", ""),
            ("https://order.pay.naver.com/orderSheet/2026", ""),
            ("https://shop.example.com/checkout", ""),
            ("https://shop.example.com/cart/checkout/step2", ""),
            ("https://shop.example.com/payment", ""),
            ("https://shop.example.com/orderSheet?id=1", ""),
            ("https://shop.example.com/%EC%A3%BC%EB%AC%B8%EC%84%9C", ""),
            ("https://shop.example.com/p/1", "주문/결제 | 테스트몰"),
            ("https://shop.example.com/p/1", "주문서 작성"),
            ("https://shop.example.com/p/1", "Checkout - Shop"),
            ("https://shop.example.com/p/1", "Payment details"),
            ("https://stdpay.inicis.com/stdpay", ""),
            ("https://pay.kcp.co.kr/x", ""),
            ("https://js.tosspayments.com/v1", ""),
            ("https://web.nicepay.co.kr/v3", ""),
            ("https://online-pay.kakao.com/mockup", ""),
            ("https://pay.naver.com/", ""),
            ("https://id.payco.com/login", ""),
        ]
        for (u, t) in hits { XCTAssertNotNil(CheckoutDetector.page(url: u, title: t, frames: []), "\(u) \(t)") }
    }

    func testPGFramesHit() {
        let frames = ["https://stdpay.inicis.com/payMain", "https://pay.kcp.co.kr/plugin", "https://kakaopay.com/x",
                      "https://order.pay.naver.com/x", "https://payment.coupay.example/x"]
        for f in frames {
            XCTAssertNotNil(CheckoutDetector.page(url: "https://shop.example.com/product/1", title: "상품", frames: ["https://ads.example.com/a", f]), f)
        }
    }

    func testOrdinaryPagesMiss() {
        let misses: [(String, String, [String])] = [
            ("https://www.coupang.com/np/search?q=checkout", "쿠팡! 하기스", []),
            ("https://www.coupang.com/vp/products/1", "하기스 네이처메이드 4단계 - 쿠팡!", []),
            ("https://shop.example.com/border-collie", "Border Collie 사료", []),
            ("https://shop.example.com/borders/list", "Borders", []),
            ("https://shop.example.com/recorder", "Recorder", []),
            ("https://shop.example.com/preorder-info", "예약 판매 안내", []),
            ("https://search.shopping.naver.com/search/all?query=하기스", "하기스 : 네이버 쇼핑", ["https://ads.naver.com/frame"]),
            ("https://flight.naver.com/", "네이버 항공권", []),
            ("https://www.skyscanner.co.kr/", "스카이스캐너", ["https://www.google.com/recaptcha/api2/anchor"]),
            ("https://www.koreanair.com/", "대한항공", []),
            ("https://shop.example.com/cart", "장바구니", []),
        ]
        for (u, t, f) in misses { XCTAssertNil(CheckoutDetector.page(url: u, title: t, frames: f), "\(u) \(t)") }
    }
}
