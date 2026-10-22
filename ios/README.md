# 캐릭모니터 아이폰 앱 (CharaMonitor for iPhone)

맥 앱의 캐릭터가 아이폰에서도 살아요. 홈 화면 캐릭터(톡 누르면 반응, 꾹 누르면 쓰다듬기), 친구 고르기, 집중 타이머,
홈 화면·잠금 화면·스탠바이 위젯, 집중 타이머의 라이브 액티비티(잠금 화면, 다이내믹 아일랜드)가 있어요.

The menu bar character on iPhone: a home stage that reacts to taps, a friend picker, a focus timer, Home Screen,
Lock Screen and StandBy widgets, and a Live Activity for the focus timer.

- iOS 17 이상, 아이폰 전용, SwiftUI. 외부 라이브러리 없음.
- 그림, 팩, 말투, 설정 파일 검사는 저장소의 Swift 패키지 `CharaCore`(../Sources/CharaCore)를 맥 앱과 같이 써요.
- 앱에 들어 있는 캐릭터는 앱이 직접 그리는 기본 캐릭터(강아지, 고양이, 오리지널)뿐이에요. 다른 캐릭터 팩은 사용자가
  맥 앱에서 내보낸 자기 설정 파일(.charamonitor)을 열 때만 들어와요. 파일 안의 그림과 이름만 읽고, 아무것도 실행하지 않아요.

## 구성 (Layout)

| 폴더 | 내용 |
|---|---|
| `App/` | 앱 (`com.jelly.charamonitor.ios`) |
| `Widgets/` | 위젯 확장과 라이브 액티비티 (`com.jelly.charamonitor.ios.widgets`) |
| `Shared/` | 앱과 위젯이 같이 쓰는 코드: 앱 그룹 경로, `SharedState`(설정 키, 배터리, 집중 타이머), `CharaActivityAttributes` |
| `Tests/` | 단위 테스트 (`CharaMonitorIOSTests`) |
| `en.lproj/` | 영어 문구 (한국어가 기본 언어) |
| `project.yml` | xcodegen 설정. 맥 앱 설정은 저장소 맨 위 `project.yml`로 따로 있어요 |

앱과 위젯은 앱 그룹 `group.com.jelly.charamonitor`로 데이터를 나눠요.
앱 그룹 권한이 없으면(서명하지 않은 시뮬레이터 빌드, App Groups가 빠진 프로필) 앱과 위젯이 각자 자기 폴더를 써서, 위젯에 가져온 팩과 고른 친구가 보이지 않아요.
디버그 빌드는 이때 콘솔에 `no app group`을 남겨요.

## 빌드 (Build)

Xcode 26 이상과 xcodegen이 필요해요.

```sh
brew install xcodegen
cd ios
xcodegen generate          # CharaMonitorIOS.xcodeproj 생성 (git에는 올리지 않아요)
open CharaMonitorIOS.xcodeproj
```

명령줄로 시뮬레이터용 빌드 (서명 인증서 없이):

```sh
xcodebuild -project CharaMonitorIOS.xcodeproj -scheme CharaMonitorIOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

테스트:

```sh
xcodebuild -project CharaMonitorIOS.xcodeproj -scheme CharaMonitorIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## 시뮬레이터에서 실행 (Run on the simulator)

Xcode에서 `CharaMonitorIOS` 스킴과 아이폰 시뮬레이터를 고르고 실행(⌘R)하면 돼요. 명령줄로는:

```sh
xcrun simctl boot "iPhone 17"
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/CharaMonitor.app
xcrun simctl launch booted com.jelly.charamonitor.ios
```

- 시뮬레이터는 배터리 값을 주지 않아서 배터리 카드가 "알 수 없어요"로 보여요. 실제 아이폰에서는 제대로 나와요.
- 위젯은 시뮬레이터 홈 화면을 길게 눌러 추가해요. 라이브 액티비티는 집중 타이머를 시작하면 다이내믹 아일랜드에 떠요.
- 스크린샷용 실행 인자: `-qaTab home|friends|focus|settings`, `-qaFocus 25`(집중 25분 시작), `-qaPet YES`(쓰다듬는 모습), `-qaNoAsk YES`(알림 권한 창 생략).

## 내 아이폰에서 실행 (Run on your own iPhone)

무료 Apple ID로도 내 아이폰에 설치할 수 있어요 (7일마다 다시 설치해야 해요).

1. Xcode > Settings > Accounts에서 Apple ID로 로그인해요.
2. 아이폰을 연결하고, 아이폰에서 설정 > 개인정보 보호 및 보안 > 개발자 모드를 켜요.
3. `project.yml`의 `DEVELOPMENT_TEAM`에 내 팀 ID(10자리)를 넣고 `xcodegen generate`를 다시 해요. 또는 Xcode에서
   `CharaMonitorIOS`와 `CharaWidgets` 두 타깃 모두 Signing & Capabilities의 Team을 골라요.
4. 번들 ID `com.jelly.charamonitor.ios`와 앱 그룹 `group.com.jelly.charamonitor`는 이미 다른 사람이 쓰고 있을 수 있어요.
   그러면 두 타깃의 번들 ID를 내 것으로 바꾸고(예: `com.내이름.charamonitor.ios`, 위젯은 그 뒤에 `.widgets`),
   앱 그룹도 두 `.entitlements` 파일과 `Shared/Shared.swift`의 `Shared.appGroup`에서 같은 새 이름으로 바꿔요.
   Signing & Capabilities의 App Groups에서 그 그룹에 체크해요.
5. 아이폰을 실행 대상으로 고르고 실행해요. 처음엔 아이폰의 설정 > 일반 > VPN 및 기기 관리에서 개발자를 신뢰해야 해요.

## 앱스토어에 내기 (Ship to the App Store)

1. 유료 Apple Developer Program(연 129,000원 / US$99)에 가입해요.
2. developer.apple.com에서 앱 ID 두 개(앱, 위젯)와 앱 그룹을 등록하고, 두 앱 ID에 App Groups를 켜요.
3. App Store Connect에서 새 앱을 만들고(번들 ID는 앱의 것), 이름, 설명, 스크린샷, 개인정보 처리방침 URL, 연령 등급을 채워요.
   앱은 데이터를 수집하지 않아요("데이터를 수집하지 않음"). 앱과 위젯의 `PrivacyInfo.xcprivacy`에 쓰는 API의 이유가 적혀 있어요.
4. Xcode에서 실행 대상을 Any iOS Device로 두고 Product > Archive, 그다음 Distribute App > App Store Connect로 올려요.
5. TestFlight로 먼저 확인한 뒤 심사에 제출해요. 출시 빌드마다 `project.yml`의 `CURRENT_PROJECT_VERSION`을 올려요.

캐릭터 팩이나 설정 파일 같은 다른 사람의 그림은 앱에 넣어서 올리지 마세요. 앱에는 기본 캐릭터만 들어가요.
