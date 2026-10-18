# 스토어 메타데이터 (한국어·영어)

캐릭모니터는 무료 비영리 오픈 소스 앱이에요. 앱스토어판도 무료이고 인앱 구매가 없어요. MAS판에 실제로 들어 있는 기능만 적었어요(직접판 전용 기능은 [review-notes.md](review-notes.md) 표 참고). 글자 수는 `python3` 로 실제로 센 값이에요(공백·줄바꿈 포함, 바이트는 UTF-8).

## 글자 수 표 (붙여 넣기 전 확인용)

| 필드 | 제한 | 한국어 | 영어 |
|---|---|---|---|
| 이름 | 30자 | 14자 / 36바이트 | 26자 / 26바이트 |
| 부제 | 30자 | 23자 / 47바이트 | 29자 / 29바이트 |
| 키워드 | 100바이트(안전 기준) | 39자 / 99바이트 | 94자 / 94바이트 |
| 프로모션 문구 | 170자 | 112자 / 268바이트 | 164자 / 164바이트 |
| 설명 | 4,000자 | 1300자 / 2866바이트 | 2405자 / 2467바이트 |

키워드는 Apple 이 '100자'라고 안내하지만 한글이 바이트로 잘린다는 보고가 있어 UTF-8 100바이트 안으로 맞췄어요. 이름·부제에 이미 있는 단어(캐릭터, 메뉴바, CPU, AI, 비서, menu bar, pet, monitor)는 키워드에서 뺐어요(중복은 검색에 도움이 안 돼요).

## 앱 정보 (App Store Connect > 앱 정보)

| 항목 | 값 |
|---|---|
| 번들 ID | `com.jelly.charamonitor.mas` |
| SKU | `charamonitor-mas` |
| 기본 언어 | 한국어 (영어 현지화 추가) |
| 기본 카테고리 | 유틸리티 (Utilities) |
| 보조 카테고리 | 생산성 (Productivity) |
| 저작권 | `2026 원창연` |
| 개인정보 처리방침 URL | https://charamonitor.vercel.app/privacy.html |
| 지원 URL | https://charamonitor.vercel.app/support.html |
| 마케팅 URL(선택) | https://charamonitor.vercel.app (결제·후원 링크 없음) |
| 가격 | 무료, 인앱 구매 없음 |

## 이름

| 후보 | 한국어 스토어 | 영어 스토어 | 메모 |
|---|---|---|---|
| **A (추천)** | `캐릭모니터: 메뉴바 캐릭터` | `CharaMonitor: Menu Bar Pet` | 앱 안 이름과 같음. 검색어 '메뉴바', 'menu bar' 포함 |
| B | 캐릭모니터 - 시스템 모니터 | CharaMonitor - System Monitor | 기능 중심. 경쟁 앱이 많은 키워드 |
| C | 젤리 모니터 | Jelly Monitor | 예전 이름. 'Jelly' 는 흔한 단어라 상표 등록이 약해요 |

상표 메모:
- 'CharaMonitor' 와 같은 이름의 앱은 조사 때 없었어요. **KIPRIS·USPTO 검색은 아직 안 했어요**(사용자 할 일).
- **'다마고치(Tamagotchi)' 는 반다이의 등록상표**라 이름·부제·키워드·스크린샷 어디에도 쓰지 않고 '펫 키우기 / Pet Room' 으로 써요(앱 안 이름도 2.1부터 같음).
- 다른 앱 이름(RunCat 등)과 Claude·ChatGPT·Gemini·카카오톡 같은 남의 상표는 **키워드에 넣지 않아요**(2.3.7). 설명에서 '연결할 수 있는 서비스'로 이름만 밝히는 건 괜찮아요.
- 앱에 들어 있는 캐릭터는 모두 오리지널이에요. 사용자가 자기 그림으로 만든 캐릭터·팩은 그 맥에만 있어요.

## 부제 (30자 이내)

- 한국어: `CPU 따라 뛰는 메뉴바 친구와 AI 비서`
- 영어: `System monitor with an AI pet`

## 키워드 (쉼표만, 띄어쓰기 없이)

- 한국어: `시스템모니터,메모리,배터리,도트,강아지,고양이,펫,위젯,상태표시줄,일정`
- 영어: `cpu,memory,battery,system,pixel,dog,cat,cute,desktop,widget,assistant,calendar,mail,status bar`

## 프로모션 문구 (170자 이내, 심사 없이 바꿀 수 있어요)

- 한국어: `맥이 바빠지면 메뉴바의 캐릭터가 뛰기 시작해요. CPU·메모리·배터리를 한눈에 보고, 펫 방을 꾸미고, 다가오는 일정과 새 메일을 말풍선으로 들어 보세요. 부탁한 메일과 일정은 카드로 먼저 보여 줘요.`
- 영어: `When your Mac gets busy, your menu bar pet starts to run. See CPU, memory and battery at a glance, decorate its room, and hear about your next meeting and new mail.`

## 설명

### 한국어

```
메뉴바에 사는 작은 도트 캐릭터가 맥의 상태를 몸으로 보여 줘요.
한가할 땐 쿨쿨 자고, CPU가 바빠질수록 걷다가 뛰다가 전속력으로 달려요.

■ 한눈에 보는 맥 상태
• CPU, 메모리 압력, 저장 공간, 배터리(성능 최대치·사이클·온도), 네트워크 속도
• 버튼 한 번으로 인터넷 속도 측정
• 오래 켜 둔 맥에는 재시동 권장 표시

■ 캐릭터
• 강아지 여러 품종, 고양이, 오리지널 캐릭터
• 귀·꼬리·털 색까지 직접 꾸미기
• 사진 한 장으로 내 반려동물 캐릭터 만들기(사진은 이 맥 안에서만 변환해요)
• 배터리 부족·충전 중·아주 바쁠 때 나오는 상황별 모션

■ 데스크톱 친구
• 커서 친구: 캐릭터가 마우스 커서를 따라 걸어 다녀요
• 대롱대롱 친구, 풀밭 친구들, 바탕화면 러그, 날씨 창문, 집중 타이머

■ 펫 키우기
• 배고픔·기분·에너지·청결을 돌보고, 앱 안 코인으로 가구를 사서 방을 꾸며요
• 일일 미션, 성장 단계, 집중 타이머 펫

■ AI 비서
• 캐릭터에게 "지금 왜 느려?" 하고 물어보세요. 앱이 잰 실제 숫자를 바탕으로 캐릭터 말투로 답해요
• Apple Intelligence가 켜진 macOS 26 맥에서는 기기 안 AI가 답하고, 그 밖의 맥에서는 기본 답변으로 답해요
• 내 AI 연결(선택): 내 Claude·ChatGPT·Gemini API 키를 넣으면 더 똑똑하게 답해요. 요금은 내 계정으로 나가고, 키는 이 맥의 키체인에만 저장해요
• 먼저 말 걸기: 배터리가 부족할 때, 맥이 뜨거울 때, 일정 10분 전, 미리 알림 시간에 말풍선으로 알려 줘요
• 메일 계정(IMAP): 새 메일의 보낸 사람과 제목을 말풍선으로 알려 줘요. 메일을 읽음으로 바꾸지 않아요
• 목소리로 읽어 주기, 아이폰으로 알림 보내기(ntfy 또는 Pushover 앱)

■ 비서가 행동하기 (내 AI 연결)
• "내일 3시 치과 일정 넣어 줘", "팀장님께 늦는다고 메일 보내 줘"처럼 부탁하면 메일 보내기·답장, 일정·미리 알림 추가, 메시지 작성 창 준비, 쇼핑·항공권 검색, 가격 지켜보기를 준비해요
• 모든 행동은 카드로 먼저 보여 주고, 확인을 눌러야 실행해요. 결제·송금·비밀번호 변경은 하지 않아요
• 켜기 전에 연결한 AI로 무엇이 가는지 보여 주고 동의를 받아요

■ 안심하고 쓰세요
• 무료, 결제 없음, 계정 가입 없음, 광고 없음
• 다른 앱을 끄거나 파일을 지우지 않아요
• 캘린더·미리 알림·연락처는 허락한 경우에만 써요
• 로그인 시 자동 실행은 설정에서 직접 켤 때만

소스 코드는 GitHub에 있어요(PolyForm Noncommercial 1.0.0).
```

### English

```
A tiny pixel-art pet lives in your menu bar and shows how your Mac is doing.
It naps while your Mac is idle, then walks, runs and sprints as the CPU gets busier.

■ Your Mac at a glance
• CPU, memory pressure, storage, battery (maximum capacity, cycles, temperature), network throughput
• One-click internet speed test
• A gentle restart hint for Macs that have been on for weeks

■ Characters
• Several dog breeds, cats and original characters
• Customize ears, tail and coat colors
• Turn a photo of your own pet into a character (the photo is processed on your Mac only)
• Situation motions for low battery, charging and heavy load

■ Desktop friends
• Cursor Buddy: your character follows the mouse cursor around
• Hanging friends, meadow friends, a desktop rug, a weather window and a focus timer

■ Pet Room
• Care for hunger, mood, energy and cleanliness, and buy furniture with in-app coins
• Daily missions, growth stages and a focus timer pet

■ AI Assistant
• Ask your character "why is my Mac slow?" and it answers in its own voice, based on the real numbers the app measured
• On macOS 26 with Apple Intelligence it answers with the on-device model; on other Macs it uses built-in answers
• Connect your own AI (optional): paste your own Claude, ChatGPT or Gemini API key for smarter answers. Usage is billed to your account, and the key stays in this Mac's keychain
• Speaks up first: low battery, a hot Mac, a meeting in 10 minutes, a reminder that is due
• Mail accounts (IMAP): hear the sender and subject of new mail. Messages are never marked as read
• Read-aloud voice and iPhone notifications (through the ntfy or Pushover app)

■ Assistant Actions (with your own AI)
• Ask "add a dentist appointment tomorrow at 3" or "email my manager that I'm running late", and it prepares the mail or reply, calendar event, reminder, a message draft, shopping and flight searches, or a price watch
• Every action appears as a card first and runs only after you confirm it. It never pays, transfers money or changes passwords
• Before you turn it on, it shows what goes to your AI and asks for your consent

■ Peace of mind
• Free, no purchases, no account, no ads
• Never quits your apps or deletes your files
• Calendar, reminders and contacts are used only with your permission
• Launches at login only if you turn it on in Settings

The source code is on GitHub (PolyForm Noncommercial 1.0.0).
```

## 연령 등급 설문 답안 (App Store Connect > 앱 정보 > 연령 등급)

2025년에 바뀐 설문(4+, 9+, 13+, 16+, 18+) 기준이에요. 항목 이름은 화면과 조금 다를 수 있어요.

| 구분 | 질문 | 답 |
|---|---|---|
| 앱 내 제어 | 자녀 보호 기능 / 연령 확인 | 아니요 / 아니요 |
| 기능 | 제한 없는 웹 접근 | 아니요 (앱 안 브라우저 없음, 링크는 기본 브라우저로 열림) |
| 기능 | 사용자 생성 콘텐츠 | 아니요 (사용자끼리 공유하는 기능 없음) |
| 기능 | 메시지 및 채팅 | 아니요 (사람끼리 대화 기능 없음, 캐릭터와의 대화만) |
| 기능 | 광고 | 아니요 |
| 성숙한 주제 | 비속어·저속한 유머 / 공포 / 술·담배·약물 | 없음 / 없음 / 없음 |
| 의료·건강 | 의료·치료 정보 / 건강·웰니스 주제 | 아니요 / 아니요 |
| 성적 내용·노출 | 전부 | 없음 |
| 폭력 | 만화·판타지 폭력 / 사실적 폭력 / 총기·무기 | 없음 |
| 확률형 활동 | 시뮬레이션 도박 / 콘테스트 / 도박 / 랜덤 아이템(루트 박스) | 없음 / 아니요 / 아니요 / 아니요 (가구는 정해진 가격, 뽑기 없음) |

예상 등급: **4+**. AI 대화는 기기 안 모델이나 사용자가 연결한 AI 가 캐릭터 말투로 맥 상태·일정을 답하는 용도예요. 심사에서 AI 자유 대화를 이유로 등급을 올리라고 하면 그때 13+ 로 다시 답해요.

## 스크린샷 계획

규격: 16:10, 1280×800 / 1440×900 / 2560×1600 / 2880×1800 중 하나(1~10장), 언어별로 따로.
원본은 `--render-dashboard` QA 렌더(UI/DashboardSnapshot.swift, 비서가 행동하기는 `QA_ONLY=agent` 의 UI/AgentQA.swift)를 **MAS 빌드로** 돌려 만들어요. 그래야 클리너·보안 타일, 에이전트 브라우저가 안 보여요. `tools/appstore/shots.py` 가 아래 1·3·5·6 을 만들어요.

| 순서 | 화면 | 한 줄 문구(한국어 / 영어) | 원본 렌더 |
|---|---|---|---|
| 1 | 메뉴바의 캐릭터가 뛰는 모습 + 대시보드 | 맥이 바쁘면 캐릭터가 뛰어요 / Your Mac's mood, in your menu bar | dashboard-light + 메뉴바 합성 |
| 2 | 대시보드(다크) | CPU·메모리·배터리를 한눈에 / Everything at a glance | dashboard-dark |
| 3 | 캐릭터 선택 | 강아지, 고양이, 오리지널 캐릭터 / Dogs, cats and originals | picker-dog |
| 4 | 사진으로 만든 내 캐릭터 | 우리 아이를 캐릭터로 / Your own pet, as a character | dog-custom-* |
| 5 | 펫 방 | 방을 꾸미고 함께 성장해요 / Decorate its room and grow together | pet-missions-light |
| 6 | AI 비서 대화 | "지금 왜 느려?" 물어보세요 / Ask why your Mac is slow | assistant-chat-light |
| 7 | 비서가 행동하기 카드 | 부탁하면 카드로 먼저 보여 줘요 / Every action waits for your OK | agent 카드(일정 추가·메일 보내기) |
| 8 | 커서 친구 | 커서를 따라다녀요 / It follows your cursor | 실제 화면 캡처 |

주의: 실제 앱에 없는 화면을 만들지 않아요(2.3.3). 카드·대화 예시에 실존 인물 이름, 실제 메일 주소를 쓰지 않아요.
