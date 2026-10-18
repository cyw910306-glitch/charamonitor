# 빌드·서명·업로드 절차

개발자 계정이 생기기 전까지는 1번(로컬 확인)만 할 수 있어요. 2번 이후는 계정과 인증서가 준비된 뒤에 해요.

## 1. 로컬 확인 (지금 가능)

```bash
scripts/build_mas.sh --debug          # arm64 디버그, ad-hoc 서명 + 샌드박스 권한
open build.noindex/mas/CharaMonitor.app
```

- 처음 실행하면 `~/Library/Containers/com.jelly.charamonitor.mas` 컨테이너가 생겨요. 설정과 내 캐릭터는 그 안에 저장돼서 직접판(`com.jelly.dogmonitor`)과 섞이지 않아요.
- 비대화 확인: `QA_ONLY=pages build.noindex/mas/CharaMonitor.app/Contents/MacOS/CharaMonitor --render-dashboard ~/Library/Containers/com.jelly.charamonitor.mas/Data/tmp/qa`. 샌드박스 안이라 출력 폴더는 컨테이너 안이어야 해요.
- 2026-10-03 실측(ad-hoc): 컨테이너 생성, 크래시 없음, 대시보드 수치(CPU·메모리·저장 공간·배터리·네트워크)와 번들 사진 정상.
- 바이너리 점검: `strings -a build.noindex/mas/CharaMonitor.app/Contents/MacOS/CharaMonitor | grep -i networkQuality` 처럼 빠져야 할 기능 이름이 없는지 봐요(review-notes.md 목록).

## 2. 경로 A: SwiftPM + productbuild (기본)

Xcode 프로젝트 없이 지금 스크립트로 올리는 방법이에요.

1. 인증서 2개(Apple Distribution, Mac Installer Distribution)를 키체인에 설치하고 이름을 확인해요.
   ```bash
   security find-identity -v -p codesigning
   security find-identity -v   # Installer 인증서 이름 확인
   ```
2. Mac App Store 프로비저닝 프로파일을 내려받아요(App ID `com.jelly.charamonitor.mas`).
3. 빌드·서명·패키지:
   ```bash
   MAS_SIGN_IDENTITY="Apple Distribution: 원창연 (TEAMID)" \
   MAS_TEAM_ID=TEAMID \
   MAS_PROVISION=~/Downloads/CharaMonitor_MAS.provisionprofile \
   MAS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: 원창연 (TEAMID)" \
   scripts/build_mas.sh --pkg
   ```
   결과: `build.noindex/mas/CharaMonitor.pkg` (universal arm64 + x86_64).
4. 올리기: **Transporter** 앱(맥 앱스토어에서 무료)에 pkg 를 끌어 넣고 '전송'. 명령줄은 앱 전용 암호를 만든 뒤 `xcrun altool --upload-app -f build.noindex/mas/CharaMonitor.pkg -t macos -u <Apple ID> -p <앱 전용 암호>`.
5. 버전을 올릴 때마다 `Resources/MAS/Info.plist` 의 `CFBundleVersion`(빌드 번호)을 1씩 올려요. 같은 번호는 다시 올릴 수 없어요. `CFBundleShortVersionString` 은 사용자에게 보이는 버전이에요.

빌드 스크립트가 하는 일: `-D MAS` 빌드, 실행 파일을 `CharaMonitor` 로 복사, `Info.plist`·`PrivacyInfo.xcprivacy`·사진·아이콘·한국어 앱 이름 넣기, Xcode 가 넣는 `DTXcode`·`DTSDKName` 등 빌드 정보 기록, `MAS_TEAM_ID` 가 있으면 `com.apple.application-identifier`·`com.apple.developer.team-identifier` 를 권한 파일에 더해 서명, 샌드박스 권한이 서명에 들어갔는지 확인.

주의: 업로드 검증에서 SwiftPM 번들이 거절되면(빌드 정보·아이콘 형식 관련 ITMS 오류) 경로 B 로 가요.

## 3. 경로 B: Xcode 아카이브 (xcodegen)

`project.yml` 로 Xcode 프로젝트를 만들어 Organizer 에서 올리는 방법이에요.

1. xcodegen 설치(이 맥에는 아직 없어요): `brew install xcodegen`
2. 프로젝트 생성: 저장소 루트에서 `xcodegen generate` → `CharaMonitor.xcodeproj` (생성물이라 .gitignore 에 있어요).
3. `project.yml` 의 `DEVELOPMENT_TEAM` 에 Team ID 를 넣거나 Xcode 의 Signing & Capabilities 에서 팀을 골라요. 자동 서명이 App ID 와 프로파일을 만들어 줘요.
4. Product > Archive → Organizer > Distribute App > App Store Connect > Upload.
5. 처음 생성 때 확인할 것: 빌드 설정에 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = MAS` 가 들어갔는지, 'Photo, app name and icon' 스크립트가 돌아 `AppIcon.icns`·`jelly.jpg` 가 번들에 들어갔는지, 실행 파일 이름이 `CharaMonitor` 인지. 이 스펙은 아직 한 번도 생성해 보지 않았어요.

## 4. TestFlight 에서 다시 볼 것
- 샌드박스 실측은 ad-hoc 서명 기준이라 배포 서명에서 배터리(IOKit)·메모리·가동 시간 수치가 그대로 나오는지.
- 커서 친구 오버레이와 타이머가 앱 종료와 함께 끝나는지.
- 로그인 시 자동 실행 토글(SMAppService)이 동작하는지.
- 캘린더 권한 팝업 문구(Info.plist `NSCalendarsFullAccessUsageDescription`).
