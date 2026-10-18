# 맥 앱스토어 출시 준비 (MAS판)

캐릭모니터는 무료 비영리 오픈 소스예요. 앱스토어판도 **무료, 인앱 구매 없음**이에요. 직접판(GitHub에서 빌드하거나 사이트의 DMG)과 별도로 **번들 ID `com.jelly.charamonitor.mas`** 인 샌드박스판을 하나 더 낼 수 있어요. 빌드 스크립트, 권한, 문서는 준비돼 있고 계정 쪽 일만 남았어요.

## 순서 (요약)

| # | 할 일 | 어디서 | 끝나면 |
|---|---|---|---|
| 1 | **Apple Developer Program 가입**(개인). 승인까지 하루~이틀 | developer.apple.com/programs/enroll, Apple 계정 2단계 인증 필요 | 승인 메일 |
| 2 | **Team ID 확인**(10자리 영문·숫자) | developer.apple.com/account > 멤버십 세부 사항 | `MAS_TEAM_ID` 로 빌드에 넣어요 |
| 3 | **인증서 2개 만들기**: Apple Distribution, Mac Installer Distribution | Xcode > 설정 > 계정 > Apple 계정 로그인 > 인증서 관리 > + | 키체인에 두 인증서 |
| 4 | **App ID 등록 + 프로비저닝 프로파일** | Certificates, IDs & Profiles > Identifiers > + > App IDs > macOS, 번들 ID `com.jelly.charamonitor.mas`. 그다음 Profiles > + > **Mac App Store Connect** > 이 App ID > 3번 인증서 > 내려받기 | `.provisionprofile` 파일(`MAS_PROVISION`) |
| 5 | **App Store Connect 앱 등록** | appstoreconnect.apple.com > 앱 > + 새로운 앱(macOS, 이름·SKU·번들 ID), 가격 '무료' | 값은 아래 표와 [metadata.md](metadata.md) |

무료 앱이라 유료 앱 계약, 세금 양식, 은행 계좌는 필요 없어요.

### 붙여 넣을 값 (요약)

| 필드 | 값 |
|---|---|
| 번들 ID / SKU | `com.jelly.charamonitor.mas` / `charamonitor-mas` |
| 이름(한/영) | `캐릭모니터: 메뉴바 캐릭터` / `CharaMonitor: Menu Bar Pet` |
| 부제(한/영) | `CPU 따라 뛰는 메뉴바 친구와 AI 비서` / `System monitor with an AI pet` |
| 카테고리 | 유틸리티, 보조 생산성 |
| 가격 | 무료, 인앱 구매 없음 |
| 개인정보 처리방침 / 지원 URL | https://charamonitor.vercel.app/privacy.html / https://charamonitor.vercel.app/support.html |
| 연령 등급 | 설문 전부 '없음/아니요' → 4+ 예상 ([metadata.md](metadata.md)) |
| 심사 메모 | [review-notes.md](review-notes.md) 의 영어 원문, `<DEMO_...>` 채워서 |

| 문서 | 내용 |
|---|---|
| [metadata.md](metadata.md) | 이름·부제·키워드·프로모션·설명(한/영)과 글자 수 표, 앱 정보 필드, 연령 등급 답안, 스크린샷 계획 |
| [review-notes.md](review-notes.md) | 심사 메모(영어 원문), MAS판에서 빠진 기능과 이유, 데모 순서 |
| [privacy-label.md](privacy-label.md) | 개인정보 라벨 답안, PrivacyInfo.xcprivacy 맞출 항목, 처리방침에 들어갈 내용 |
| [xcode-archive.md](xcode-archive.md) | 빌드·서명·업로드 절차 |
| [support-contact.md](support-contact.md) | 지원·개인정보 URL과 연락처 |

## 코드에서 달라지는 점 (요약)

- 빌드 플래그 `MAS`: `scripts/build_mas.sh` 가 `swift build -Xswiftc -DMAS` 로 빌드하고 `build.noindex/mas/CharaMonitor.app` 을 만들어요. 일반 `swift build` 는 그대로 직접판이에요.
- 권한: `Resources/MAS/CharaMonitor.entitlements` (app-sandbox, network.client, files.user-selected.read-only, personal-information.calendars, personal-information.addressbook). 그 밖의 권한과 temporary exception 은 쓰지 않아요.
- AI: 기본은 기기 안(Foundation Models) 또는 기본 답변. 내 AI 연결은 API 키만(CLI 연결 없음). 비서가 행동하기는 v1 한 번 제안 + 카드 확인, 에이전트 브라우저와 메시지 자동 보내기는 없어요.
- 빠지는 기능 목록과 이유는 [review-notes.md](review-notes.md) 에 있어요.

## 체크리스트

### 식별자·인증서
- [ ] App ID 등록: 번들 ID `com.jelly.charamonitor.mas`.
- [ ] 인증서 2개: Apple Distribution(또는 3rd Party Mac Developer Application), Mac Installer Distribution(3rd Party Mac Developer Installer).
- [ ] Mac App Store 프로비저닝 프로파일(위 App ID, Distribution 인증서) 내려받기.

### App Store Connect
- [ ] 새 앱: 플랫폼 macOS, 이름(→ [metadata.md](metadata.md)), 기본 언어 한국어, 번들 ID 위와 같음, SKU `charamonitor-mas`, 가격 무료.
- [ ] 개인정보 처리방침 URL, 지원 URL 입력(사이트에 올라간 뒤 열리는지 확인).
- [ ] 개인정보 라벨 입력 → [privacy-label.md](privacy-label.md).
- [ ] 연령 등급 설문: [metadata.md](metadata.md) 의 답안대로(→ 4+ 예상).

### 상표와 이름
- [ ] KIPRIS(한국)와 USPTO(미국)에서 '캐릭모니터', 'CharaMonitor' 검색.
- [x] '다마고치'(반다이 등록상표)는 앱·사이트 어디에도 쓰지 않아요('펫 키우기', metadata.md 참고).

### 빌드와 제출
- [ ] [xcode-archive.md](xcode-archive.md) 대로 서명 빌드 → 업로드 → TestFlight 로 샌드박스 동작 재확인.
- [ ] 심사 전용 Gemini API 키 만들기(심사 끝나면 삭제), 심사 메모의 `<DEMO_...>` 채우기.
- [ ] 스크린샷(한국어·영어, `tools/appstore/shots.py`) 업로드, 심사 메모 붙여넣기, 제출.
