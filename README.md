# 캐릭모니터 (CharaMonitor)

메뉴바에 사는 도트 캐릭터가 맥의 CPU 사용량에 맞춰 자고, 걷고, 뛰고, 헉헉대는 macOS 메뉴바 앱이에요.
기본 캐릭터는 실제 반려견 "젤리"(살구색 말티푸)를 본뜬 강아지예요. **결제 없는 무료 오픈 소스**예요. 계정도 없고, 끌 수 있는 후원 친구(제작자 서비스 소개)가 있어요. 꾸미기 선물 8가지는 후원 친구를 끝까지 보면 하나씩 열려요 (앱스토어판은 처음부터 다 열려 있어요).

A macOS menu bar app: a pixel-art pet that naps, walks, runs and pants with your Mac's CPU load, plus a dashboard,
desktop friends, a pet room and an optional AI assistant. **Free, open source.** No payments or account; an optional
Sponsor Friend (the author's own services) you can turn off. A few decorations open as you watch it (all open in the
App Store version).

- 사이트: https://charamonitor.vercel.app
- 소스: https://github.com/cyw910306-glitch/charamonitor
- 라이선스: [PolyForm Noncommercial 1.0.0](LICENSE)

## 기능

- **메뉴바 캐릭터**: CPU에 따라 7가지 자세(자는 중 0~5% · 어슬렁 · 산책 · 총총 · 달리기 · 전속력 · 헉헉 85% 이상). 배터리가 적거나 충전 중이거나 아주 바쁠 때는 상황별 모션(먹을 것 찾기 · 냠냠 · 특수 기술)을 보여 줘요.
- **대시보드**(클릭): CPU, 메모리 압력, 저장 공간, 배터리(성능 최대치·사이클·온도), 네트워크, 인터넷 속도 측정, 재시동 권장.
- **캐릭터**: 강아지 23종(젤리 + 22견종), 고양이 12종, 오리지널 캐릭터. 귀·꼬리·털 색까지 꾸미기.
- **나만의 캐릭터**: 사진 한 장으로 만들기(최대 5개, 변환은 이 맥 안에서). 실사 또는 도트 스타일.
- **캐릭터 팩**: 내 그림 파일로 프레임을 직접 그려 넣는 캐릭터. 형식은 [docs/PACKS.md](docs/PACKS.md).
- **데스크톱 친구**: 커서를 따라 걷는 커서 친구, 메뉴바 아래 줄에 매달린 대롱대롱 친구, 화면 아래 풀밭 친구들, 바탕화면 러그, 날씨 창문, 집중 타이머, 친구를 눌러 여는 퀵물어보기.
- **펫 키우기**: 배고픔·기분·에너지·청결 돌보기, 앱 안 코인으로 가구 사서 방 꾸미기, 일일 미션, 성장 단계, 성장 일기.
- **AI 비서**(선택): 캐릭터에게 "내 맥 왜 느려?" 하고 물으면 앱이 잰 실제 숫자로 답해요. 기본은 이 맥 안의 Apple Intelligence(macOS 26) 또는 기본 답변. 원하면 **내 AI**(Claude · ChatGPT · Gemini, 내 API 키 또는 이 맥에 로그인된 CLI)를 연결해요. 먼저 말 걸기, 캘린더·미리 알림, IMAP 메일 계정, 아이폰 알림(ntfy·Pushover), 목소리.
- **비서가 행동하기**(선택, 내 AI 필요): 메일·일정·미리 알림·쇼핑 검색 같은 부탁을 카드로 먼저 보여 주고, 확인해야 실행해요. 결제·송금·비밀번호 변경은 하지 않아요.
- **클리너·보안 점검**(직접판): 안 쓰는 앱 종료, 캐시·로그·개발자 캐시 정리, 로그인 항목 관리, macOS 기본 보호와 수상한 자동 실행 항목 점검. 누르기 전에는 아무것도 바꾸지 않고, 되돌릴 수 있는 조치만 해요.

평소 CPU 약 0.3%, 메모리 약 46 MB. macOS 13 이상, Apple Silicon과 Intel. 외부 라이브러리 없이 Apple 프레임워크만 써요.

## 소스로 빌드하기 (Build from source)

필요한 것: macOS 13 이상, Xcode 또는 Xcode Command Line Tools(Swift 5.9 이상).

```bash
git clone https://github.com/cyw910306-glitch/charamonitor.git
cd charamonitor
swift build                     # 디버그 빌드
.build/debug/DogMonitor         # 바로 실행 (메뉴바에 캐릭터가 나와요)
swift test                      # 테스트

bash scripts/build_app.sh                 # build.noindex/DogMonitor.app (release, universal, 아이콘 포함)
bash scripts/build_app.sh --install       # /Applications 에 복사 (쓸 수 없으면 ~/Applications)
```

- 앱스토어용 샌드박스 빌드: `swift build -Xswiftc -DMAS` 또는 `scripts/build_mas.sh`([docs/appstore](docs/appstore/README.md)).
- 직접 빌드한 앱은 ad-hoc 서명이에요. 처음 열 때 경고가 뜨면 시스템 설정 > 개인정보 보호 및 보안 > **그래도 열기**.
- 영어 UI 문자열: `python3 tools/i18n/extract.py` 로 뽑고, `chunk-N.en.json` 에 영어를 넣은 뒤 `python3 tools/i18n/merge.py` 로 `Resources/en.lproj/Localizable.strings` 를 만들어요.

### 자체 업데이트와 포크

직접판은 하루에 한 번 서명된 `update.json` 을 확인해요. 서명은 관리자의 Ed25519 키로만 통과하고(`App/Updater.swift` 의 `UpdateCheck.publicKey`), 포크가 자기 업데이트를 내려면 자기 키 쌍을 만들어 공개키와 `UpdateCheck.checkHost` 를 바꾸고 `tools/update/sign_manifest.swift` 로 서명해요.

## 개발용 CLI

```bash
.build/debug/DogMonitor --metrics-dump                   # CPU·메모리·디스크·배터리·네트워크 보고서
.build/debug/DogMonitor --render-sprites qa/sprites      # 견종 시트, 메뉴바 모형, 꾸미기 조합표, 아이콘, style-ref.png
.build/debug/DogMonitor --render-dashboard <폴더>         # 팝오버 화면 QA 렌더(라이트·다크). QA_ONLY=picker|pages|agent|extras|desktop|weather
.build/debug/DogMonitor --render-pack <팩 폴더> <출력.png>  # 캐릭터 팩 점검 시트
.build/debug/DogMonitor --make-character <폴더> <그림>     # 그림 1~3장으로 나만의 캐릭터 결과물
.build/debug/DogMonitor --cleaner-dry-run                # 클리너가 무엇을 할지 출력만
.build/debug/DogMonitor --security-scan                  # 보안 점검 결과 출력만
.build/debug/DogMonitor --check-update [web]             # 업데이트 서명 검증만
```

`--render-dashboard` 는 버리는 전용 설정 공간(`qa.dogmonitor.snapshot`)에만 쓰고 끝나면 지워서 이 맥의 설정은 건드리지 않아요.

## 구조

```
Sources/DogMonitor/
  main.swift        CLI 옵션 분기, 없으면 메뉴바 앱
  Models.swift      측정값, DogPose, AppSettings
  App/              AppDelegate, 메뉴바·팝오버, 데스크톱 친구, 말풍선, 업데이터
  Metrics/          시스템 샘플러, 클리너, 보안 점검, 날씨
  Sprite/           도트 렌더러, 견종·고양이·오리지널, 나만의 캐릭터, 캐릭터 팩
  AIDraw/           자동 다듬기(이 맥의 ChatGPT·Claude CLI로 빈 모습 그리기)
  Assistant/        AI 비서 엔진(기기 안·내 AI·기본 답변), 캘린더·메일·알림
  Agent/            비서가 행동하기(카드 확인 후 실행)
  Pet/              펫 키우기
  UI/               SwiftUI 대시보드와 설정, QA 렌더
Tests/              XCTest
tools/              i18n, 업데이트 서명, 오리지널 캐릭터 도구, 앱스토어 스크린샷
web/                사이트(정적 페이지)
```

## 개인정보 (Privacy)

- 계정, 결제, 추적, 사용 통계가 없어요. 개발자는 여러분의 데이터를 받지 않아요. 다만 후원 친구 카드의 버튼을 누르면 제작자의 그 서비스가 IP와 utm 표시를 받아요.
- 맥 상태, 설정, 캐릭터, 펫, 대화 기록은 이 맥에만 저장돼요(`~/Library/Application Support/DogMonitor`, `com.jelly.dogmonitor` 설정).
- 직접 켠 기능만 밖으로 나가요: 내 AI(고른 회사로 질문과 맥 숫자), 아이폰 알림(짧은 상태 문구), 메일 계정(내 메일 서버), 날씨 창문(도시 좌표, MET Norway), 자동 다듬기(이 맥에 로그인된 ChatGPT·Claude로 사진), 속도 측정, 업데이트 확인(서명된 버전 파일), 후원 친구(직접판, 켤 때와 하루 한 번 서명된 소개 목록, 끌 수 있어요).
- 자세한 내용: [web/privacy.html](web/privacy.html) (https://charamonitor.vercel.app/privacy.html)

No account, payments, tracking or analytics. The developer receives none of your data, except that a Sponsor Friend button
opens the author's own service, which sees your IP and a utm tag. Everything stays on your Mac unless you
turn on a feature that needs the network (your own AI, iPhone notifications, your mail server, weather, AI touch-up
through your own ChatGPT/Claude CLI, speed test, signed update check, and in the direct version the signed Sponsor
Friend list at launch and once a day, which you can turn off).

## 기여

이슈와 풀 리퀘스트를 환영해요. [CONTRIBUTING.md](CONTRIBUTING.md) 를 먼저 읽어 주세요.

## 라이선스 (License)

**한국어 요약**: 이 소프트웨어는 [PolyForm Noncommercial License 1.0.0](LICENSE) 으로 공개돼요. 개인적 사용, 공부, 연구, 취미, 비영리 단체·교육 기관의 사용처럼 **비상업적 목적**이면 누구나 쓰고, 고치고, 나눌 수 있어요. 나눌 때는 라이선스 전문(또는 주소)과 `Required Notice:` 줄을 함께 전해야 해요. **돈을 받고 팔거나, 유료 서비스·제품에 넣거나, 회사의 상업적 목적으로 쓰는 것은 허용되지 않아요.** 보증은 없어요. 이 요약은 이해를 돕는 설명이고, 법적 효력은 [LICENSE](LICENSE) 원문에만 있어요.

**English summary**: This software is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE). You may use,
modify and share it for any **noncommercial purpose**: personal use, study, research, hobby projects, and use by
charitable, educational, public research, public safety or government organizations. When you share it, pass on the
license (or its URL) and the `Required Notice:` line. **Selling it, building it into a paid product or service, or any
other commercial use is not permitted.** It comes with no warranty. This summary is for convenience; only the
[LICENSE](LICENSE) text is binding.

Required Notice: Copyright 2026 원창연 (https://github.com/cyw910306-glitch)

앱에 들어 있는 캐릭터와 그림은 모두 이 프로젝트의 오리지널이에요. 직접 만든 캐릭터·팩에는 권리를 가진 이미지만 써 주세요.
All bundled characters and art are original to this project. Use only images you have the rights to in your own characters and packs.
