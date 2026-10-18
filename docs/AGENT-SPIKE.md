# Agent browser spike (v2, direct build)

Date: 2026-10-06. Probe: `DogMonitor --agent-browse <url> --out <file>` (AgentBrowser offscreen, non-persistent store so no
cookies or logins, read only: no clicks, no typing). Each probe ran alone in the background with a 40 s watchdog; the probe
exits itself at 35 s. One network (home line in Korea), macOS 26, WebKit user agent with the Safari token.

| Site | Result | Elements | Time to usable | Notes |
|---|---|---|---|---|
| 쿠팡 search (`/np/search?q=하기스`) | loaded | 179 | ~9 s | Blank for the first ~2 s after load (Akamai sensor challenge, HTTP 200 with an empty body), then the full result list. curl gets `403 Access Denied`. Search box shows `값='하기스'`, cart link, product links. No checkout hit. |
| 네이버쇼핑 search (`search.shopping.naver.com/search/all`) | **blocked** | 2 | 1 s | HTTP 418 "쇼핑 서비스 접속이 일시적으로 제한되었습니다" (abnormal access). curl with a Safari agent gets the same 418, so this is the network or IP, not WebKit detection. Re-test from another network and with the owner's logged-in cookies. |
| 네이버 항공권 (`flight.naver.com`) | loaded | 64 | ~3 s | 왕복/편도/다구간, `'서울 ICN, GMP (모든 공항)'`, `'도착지 도시, 공항 검색'` are buttons that open pickers. Three icon-only buttons (label ''), which v2 puts at confirm. |
| 대한항공 (`koreanair.com`) | loaded (slow) | 22 to 29 | 14 to 19 s | Angular app: "진행중 잠시만 기다려 주세요" for many seconds. Once up: 항공권 예매, 왕복/편도 radios, notices. One frame (useinsider analytics worker). |
| 진에어 (`jinair.com`) | loaded | 102 | ~4 s | Cloudflare "Attention Required" (HTTP 403) with the plain WebKit agent string; passes once the agent has the Safari token. Booking widget: 왕복/편도/다구간, 출발지 선택 buttons. |
| 스카이스캐너 (`skyscanner.co.kr`) | loaded | 74 | ~3.5 s | Home page fine; a PerimeterX frame (`js.px-cloud.net`) is present, so search results may still meet a "press and hold" check. 출발지/도착지 are real inputs, dates and travellers are buttons. |

## What changed in the browser because of this

- **Blank-page wait in `open`.** The 1.5 s settle returned empty snapshots for 쿠팡 and 대한항공. `open` now re-reads every
  second while the page has under 50 characters of text, inside its 20 s budget.
- **Safari token in the user agent** (`applicationNameForUserAgent = "Version/<installed Safari> Safari/605.1.15"`). Without
  it Cloudflare refused 진에어 outright.
- **Hidden window is fine.** 쿠팡's challenge and 대한항공's app both completed in a web view whose window was never shown, so
  the agent window can stay hidden until `reveal()`.
- **CheckoutDetector false positives found and fixed** (now in the corpus):
  - `'매일 진행되는 네이버페이 적립이벤트'` (네이버 항공권 banner link) hit on 네이버페이. Pay brand names now count only as
    short labels.
  - `'리콜 대상 보조배터리 항공기 운송 금지'` (대한항공 notice) hit on 송금 because spaces were squashed ("운송금지").
    Korean keywords now match inside one word or at the start of two joined words, never across a word boundary.
  - Labels about paying rather than pay buttons (`결제 내역`, `결제수단 안내`) no longer hit unless they end in the pay
    word.

## Open points for the integrator

- 네이버쇼핑 needs a re-test elsewhere; if it stays blocked, keep the v1 link card or the Naver Shopping API as the shopping
  path and use the browser for 쿠팡.
- Expect bot checks (PerimeterX on 스카이스캐너, Akamai on 쿠팡) mid-run. They should be a handoff ("사람 확인이 필요해요"),
  never solved by the agent (design section 3, hard blocks).
- `CheckoutDetector.page` flags any URL with an `order` path segment, which includes order history pages
  (`/mypage/order/list`), and any host under `pay.naver.com` (also `help.pay.naver.com`). That errs toward handing off, as
  designed; narrow it only with a corpus case.
