# 심사 메모와 MAS판 기능 차이

## MAS판에서 빠지는 것과 이유

빌드 플래그 `MAS` 로 **코드째** 빠져요(바이너리에 남은 휴면 기능은 2.3.1 리젝트 사유라서요). 제출 빌드마다 아래 검사로 0줄인지 확인해요.

```bash
B=build.noindex/mas/CharaMonitor.app/Contents/MacOS/CharaMonitor
strings "$B" | grep -iE 'networkQuality|osascript|csrutil|update\.json|LaunchAgents|proc_pidinfo|System Events|WKWebView|agent-bridge|chat\.db|claude -p|codex exec'
```

| 기능 | 직접판 | MAS판 | 이유(가이드라인) | 코드 |
|---|---|---|---|---|
| 자체 업데이터 | 있음 | 없음(앱스토어가 업데이트) | 2.4.5(vii) | App/Updater.swift, UI/UpdateCard.swift |
| 클리너(앱 종료, 캐시 삭제, LaunchAgents 끄기, 재시동) | 있음 | 타일째 없음 | 2.4.5(i)(v) | Metrics/Cleaner*.swift, UI/CleanerView.swift |
| 보안 점검(시스템 명령, 관리자 권한) | 있음 | 타일째 없음 | 2.4.5(v), 2.5.2 | Metrics/Security*.swift, UI/SecurityView.swift |
| 폭주 프로세스 목록 | 있음 | 없음 | 샌드박스(proc_listpids 0) | Metrics/RunawayTracker.swift |
| 인터넷 속도(networkQuality 실행) | 있음 | URLSession 측정(Cloudflare) | 2.5.2 | Metrics/SpeedTest.swift |
| AI 캐릭터 그리기·자동 다듬기(ChatGPT/Claude CLI) | 있음 | 없음 | 2.5.2, 5.1.2(i) | AIDraw/*.swift |
| 내 AI 의 '구독 계정(CLI)' 연결(claude, codex, gemini 실행) | 있음 | 없음, API 키만 | 2.5.2(다른 프로그램 실행) | Assistant/BYOEngine.swift, Agent/AgentEngine.swift |
| 비서가 행동하기 v2 도구 루프, MCP 브리지 | 있음 | 없음, v1 한 번 제안만 | 2.5.2 | Agent/AgentRuns.swift, AgentBridge.swift, AgentCLI.swift |
| 에이전트 브라우저(쇼핑몰·항공사 사이트 자동 조작) | 있음 | 없음, 검색 링크는 기본 브라우저로 | 남의 사이트 자동화 심사 리스크 | Agent/AgentBrowser.swift |
| 메시지 자동 보내기(AppleScript) | 있음 | 없음, 메시지 작성 창만 열어 줌 | 2.4.5, 샌드박스 | Agent/AgentNativeV2.swift |
| iCloud 메일 보내기(Mail.app AppleScript) | 있음 | 없음, 메일 작성 창만 | 샌드박스 | Agent/AgentCenter.swift |
| Apple Mail 새 메일 알림 | 있음 | 없음, IMAP 메일 계정만 | 다른 앱 데이터 접근 | Assistant/AssistantIntegrations.swift |
| 문자 읽기(Messages DB), 다른 앱 알림 읽기(알림 센터 DB), 전체 디스크 접근 | 있음 | 없음 | 2.4.5(i), 다른 앱 데이터 접근 | Assistant/InboxMessages.swift, InboxNotifications.swift |
| 로그인 시 자동 실행 | 기본 꺼짐 | 기본 꺼짐, 설정에서 켬(SMAppService) | 2.4.5(iii) | App/LoginItem.swift |

남는 것: 메뉴바 캐릭터 애니메이션, 대시보드 수치, 속도 측정, 재시동 권장, 캐릭터 선택·꾸미기, 사진으로 내 캐릭터(맥 안 변환), 내 그림으로 만든 캐릭터 팩(앱 컨테이너 안 `Application Support/DogMonitor/Packs`, 캐릭터 선택의 '팩 폴더 열기'로 보이는 기능, [PACKS.md](../PACKS.md)), 상황별 모션, 데스크톱 친구, 펫 키우기, AI 비서(기기 안 AI·기본 답변, 내 AI API 키 연결, 먼저 말 걸기, 목소리, 캘린더·미리 알림, IMAP 메일 계정, 아이폰 알림, 단축어로 말 시키기), 비서가 행동하기 v1(카드 확인 후 실행), 활성 상태 보기 열기.

## App Review 메모 (App Store Connect > 앱 심사 정보 > 메모에 그대로 붙여넣기)

`<DEMO_...>` 세 곳은 제출 직전에 채워요. 데모용 Gemini API 키는 심사 전용으로 새로 만들고 심사가 끝나면 지워요. 메일 계정은 비워도 되지만, 그 경우 마지막 줄을 지워요. 현재 길이 3,800자(메모 칸 4,000자 안).

```
CharaMonitor is a menu bar utility. It has no Dock icon and no window: click the small pixel-art character in the menu bar (top right) to open the dashboard (CPU, memory, storage, battery, network). The character runs faster as the CPU gets busier. No account or sign-in is needed. The UI follows the system language (Korean or English).

PRICE
Free, non-commercial open source (PolyForm Noncommercial 1.0.0, https://github.com/cyw910306-glitch/charamonitor). No in-app purchases, no ads, no donations. Every feature is available to everyone. Pet Room coins are earned in the app only; no random items.

AI AND THIRD-PARTY DATA (5.1.1, 5.1.2(i))
1. Default: the assistant answers with Apple's on-device Foundation Models (macOS 26 with Apple Intelligence) or built-in templates. Nothing leaves the Mac.
2. Connect your own AI (off by default): AI Assistant > gear icon > AI engine. The user picks Claude, ChatGPT or Gemini and pastes their OWN API key (stored in the Keychain, billed to their account). Before the key field appears, a consent screen names the company and what is sent (the question, recent turns, a snapshot of Mac numbers); nothing is sent until the user taps 동의하고 연결하기 (Agree and connect). Calendar titles are sent only if the user also turns on "Also send messages and schedule to my AI" (off by default). Received mail never goes to the AI. We run no server and receive nothing.
3. Assistant Actions (비서가 행동하기, same settings page, off by default): needs a connected AI. Turning it on shows a consent sheet listing what goes to the AI; nothing runs until the user taps 동의하고 켜기 (Agree and turn on). Every action (send or reply to mail over the user's own SMTP account, add a calendar event or reminder, open a Messages draft, shopping or flight search links, price watch) is shown as a card and runs only after the user confirms. Outbound mail is also checked by a second call to the same AI, which sees recipient names and mail domains only. Contact addresses go only to the user's mail server. It never pays, transfers money or changes passwords, and it does not automate websites: links open in the default browser.

HOW TO TEST
- Demo API key (Gemini, made for this review): <DEMO_GEMINI_KEY>
  AI Assistant > gear > AI engine: Gemini > Agree and connect > paste key > Check connection.
- Same page > 비서가 행동하기 > switch on > 동의하고 켜기. Back in the chat, type: 내일 오후 3시에 치과 일정 넣어 줘 (Add a dentist appointment tomorrow at 3 pm). A card appears; confirm it and the event is added to a calendar named "AI 비서".
- Mail accounts (optional, IMAP): <DEMO_MAIL_ADDRESS> / app password <DEMO_APP_PASSWORD> in the same settings page > Mail Accounts.

SANDBOX AND PERMISSIONS
- App Sandbox with network client, user-selected files (read-write: photos picked, and the setup file the owner saves or opens), calendars and contacts. No temporary exceptions.
- Calendars, reminders and contacts are asked for only when the user turns on a feature or asks for an action that needs them.
- Network: optional speed test (Cloudflare's public endpoint, 10 MB down, 5 MB up, only on button press), the user's chosen AI provider, the user's own IMAP/SMTP mail server, ntfy or Pushover if the user turns on iPhone notifications, the Naver Shopping API with the user's own key (optional), MET Norway weather when the weather window is on.
- Custom characters are made on device from a photo picked in an open panel. Photos never leave the Mac. Character packs are PNG files the user puts in the app's own container folder (Settings has no hidden paths: the character picker has an "Open pack folder" button).
- Launch at login is off by default (SMAppService, Settings).
- The app does not read other apps' data, run other programs or scripts, download code, ask for administrator rights, quit apps or delete files. It has no self-updater and no purchases of any kind.
```

같은 데모 키와 메일 계정은 '로그인 정보' 칸이 아니라 메모에 적어요(앱 자체에 로그인이 없어서 '로그인 필요' 체크는 끔).

한국어 요약: 메뉴바 앱이라 창이 없고 캐릭터를 누르면 대시보드가 열려요. 무료 비영리 오픈 소스이고 인앱 구매·광고·후원이 없다고 적었어요. AI 는 기본이 기기 안이고, 내 AI 연결은 사용자 본인 API 키로 꺼진 채 시작하며 보내는 내용을 화면에 밝혀요. 비서가 행동하기는 동의 화면을 거쳐야 켜지고, 모든 행동은 카드 확인 뒤 실행, 결제·송금·사이트 자동 조작은 하지 않아요. 데모 순서(키 → 동의 → 일정 추가 카드)를 넣었어요.

## 예상 리젝트와 대응

| 사유 | 대응 |
|---|---|
| 2.1 앱 완성도(심사자가 기능을 못 써 봄) | 데모 API 키와 순서를 메모에 넣어요. 키가 없으면 비서가 행동하기를 심사자가 켤 수 없어요. |
| 2.3.1 숨겨진 기능 | 빠진 기능은 코드째 제외하고 strings 검사. 캐릭터 팩은 캐릭터 선택에 보이는 버튼과 문서가 있는 기능이에요. |
| 2.3 메타데이터 | '빨라져요', '정리', '최적화' 같은 표현 금지. 스크린샷은 MAS 빌드 렌더만. |
| 2.4.5 맥 앱 | 샌드박스, temporary exception 없음, 자동 실행 기본 꺼짐, 자체 업데이터 없음, 관리자 권한 없음, 다른 앱 데이터 안 읽음. |
| 2.5.2 코드 실행 | 다른 프로그램·스크립트 실행 없음(CLI 연결, AppleScript, MCP 브리지 모두 MAS 제외). AI 답은 글자로만 쓰고 코드로 실행하지 않아요. |
| 3.1.1 구매 | 구매 자체가 없어요. 잠긴 기능·외부 결제·후원 링크 없음. 내 AI 연결은 사용자 본인 계정 요금이라 앱 판매가 아니에요. |
| 4.2 최소 기능 | 시스템 모니터 + 캐릭터 + 펫 + 비서로 범위가 넓어요. |
| 5.1.1 데이터 최소화 | 캘린더·미리 알림·연락처는 기능을 켤 때만 요청, 연락처 주소는 AI 로 보내지 않음(검토 모델도 이름과 도메인만). |
| 5.1.2(i) 제3자 AI | 내 AI 연결 패널의 전송 안내 + 비서가 행동하기 동의 화면. 개인 데이터(일정·메일 제목)는 별도 스위치로 한 번 더 켜야 가요. 개인정보 처리방침에도 같은 내용. |
| 5.2 지식재산 | 앱에 든 캐릭터는 전부 오리지널. 팩은 사용자가 자기 그림으로 자기 맥에서 만들어요(앱이 받거나 나누지 않음). '다마고치' 표기 없음. 남의 상표는 키워드에 없음. |
| 2.5.1 비공개 API | IOKit(배터리), host_statistics(메모리), sysctl(가동 시간) 는 공개 API. |
