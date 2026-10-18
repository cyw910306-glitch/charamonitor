# 개인정보 라벨 (App Store Connect > 앱 개인정보 보호)

MAS판 기준이에요. 캐릭모니터에는 개발자 서버가 없어요(무료 오픈 소스, 결제·계정 없음). 그래도 사용자가 고른 제3자 서비스(내 AI, 아이폰 알림)로 나가는 데이터가 있어서 **보수적으로 신고**해요. 사용자 본인 계정으로 쓰는 서비스는 엄밀히는 '개발자가 수집'이 아니라는 해석도 있지만, 5.1.2(i) 가 제3자 AI 전송을 따로 짚기 때문에 라벨에도 드러내는 쪽을 택했어요.

| 항목 | 값 |
|---|---|
| 개인정보 처리방침 URL | https://charamonitor.vercel.app/privacy.html |
| 지원 URL | https://charamonitor.vercel.app/support.html |
| 추적(ATT) | 하지 않음 |

## 1. 데이터를 수집하나요? → **예**

| 데이터 유형 | 언제 나가나 | 받는 곳 | 사용자와 연결 | 추적 | 목적 |
|---|---|---|---|---|---|
| 사용자 콘텐츠 > **기타 사용자 콘텐츠** | 내 AI 연결을 켠 뒤 질문할 때: 질문, 최근 대화, 맥 숫자 스냅샷(CPU·메모리 등). 비서가 행동하기: 부탁한 말, 오늘 날짜, 2차 검토용 받는 사람 이름과 메일 도메인. '받은 메시지·일정도 내 AI로'를 켰다면 일정 제목 | 사용자가 고른 Claude(Anthropic)·ChatGPT(OpenAI)·Gemini(Google) API | 아니요 | 아니요 | 앱 기능 |
| 사용자 콘텐츠 > **이메일 또는 문자 메시지** | (보수적 신고) MAS판 코드에서는 받은 메일이 AI로 가지 않아요(받은 메일 질문은 앱이 맥 안에서 답함, 2026-10-09 확인). 비서가 써 주는 메일 초안은 AI가 만든 글이에요. 빼고 싶으면 PrivacyInfo.xcprivacy 에서도 같이 빼요 | 위와 같음 | 아니요 | 아니요 | 앱 기능 |
| 기타 데이터 > **기타 데이터 유형** | '아이폰으로 알림 보내기'를 켠 경우: 배터리 10%, 맥이 뜨거움, 오래 걸린 작업 끝, 펫 상태 같은 짧은 상태 문구 | ntfy.sh 공개 토픽 또는 Pushover | 아니요 | 아니요 | 앱 기능 |

모두 **선택 사항**이에요(기본 꺼짐, 사용자가 설정에서 켜야 나가요). 개발자는 어느 것도 받지 않고 보관하지 않아요.

- 내 AI 연결: API 키는 이 맥의 키체인에만 저장. 요금과 데이터 처리는 사용자와 그 AI 회사 사이의 약관을 따라요.
- ntfy 공개 토픽은 주소를 아는 사람이면 누구나 읽을 수 있어요. 앱이 무작위 토픽을 만들고 설정 화면에서 그 점을 알려요. 알림 문구에 일정 제목·메일·사진은 들어가지 않아요.

## 2. 수집하지 않는 것 (라벨에 안 넣음, 처리방침에는 적음)

- **연락처**: 비서가 행동하기가 이름으로 메일 주소를 찾을 때만 이 맥 안에서 읽어요. 주소는 메일을 보낼 때 사용자 메일 서버로만 가고 AI 로는 가지 않아요(2차 검토도 이름과 도메인만).
- **메일 본문·메일 계정 비밀번호**: IMAP 은 보낸 사람·제목만 읽고, 앱 비밀번호는 키체인에만. 메일을 보낼 때는 사용자 본인 SMTP 서버로만.
- **사진**: 내 캐릭터 만들기는 이 맥 안에서만 변환.
- **캘린더·미리 알림**: 허락한 경우 이 맥 안에서 읽고 'AI 비서' 캘린더·목록에 추가. 밖으로는 위 1번 스위치를 켠 경우의 일정 제목만.
- **구매 내역**: 없음. 앱이 무료이고 인앱 구매가 없어요.
- **진단·사용 통계·광고·위치·검색 기록**: 없음. 쇼핑·항공권 검색은 기본 브라우저로 링크를 여는 것이고, 가격 지켜보기의 네이버 쇼핑 API 는 사용자 본인 키로 상품명만 보내요.
- **인터넷 속도 측정**: Cloudflare 속도 서버와 빈 데이터만 주고받아요(서버 쪽에 IP 는 남을 수 있음).
- MAS판은 메시지 앱 기록, 다른 앱 알림, Apple Mail 을 읽지 않아요(직접판 전용).

## 3. PrivacyInfo.xcprivacy (Resources/MAS/PrivacyInfo.xcprivacy)

앱 번들 `Contents/Resources/` 에 들어가요(build_mas.sh). `NSPrivacyCollectedDataTypes` 에 아래 세 항목이 들어 있어요(2026-10-09 반영):

| NSPrivacyCollectedDataType | Linked | Tracking | Purposes |
|---|---|---|---|
| `NSPrivacyCollectedDataTypeOtherUserContent` | false | false | `NSPrivacyCollectedDataTypePurposeAppFunctionality` |
| `NSPrivacyCollectedDataTypeEmailsOrTextMessages` | false | false | `NSPrivacyCollectedDataTypePurposeAppFunctionality` |
| `NSPrivacyCollectedDataTypeOtherDataTypes` (있음) | false | false | `NSPrivacyCollectedDataTypePurposeAppFunctionality` |

| 필수 사유 API | 사유 코드 | 쓰는 곳 |
|---|---|---|
| UserDefaults | CA92.1 | 설정, 캐릭터 선택 등 |
| 시스템 부팅 시간 | 35F9.1 | 샘플 간격·타이머(systemUptime), "켜진 지" 표시 |
| 디스크 공간 | 85F4.1 | 대시보드 저장 공간 |

- "켜진 지 N일" 표시는 사유 목록에 딱 맞는 항목이 없어요. 물으면 "기기 밖으로 보내지 않고 화면에만 표시" 라고 답해요.
- 파일 시각(File timestamp) API 를 쓰게 되면 C617.1 을 추가해요.

## 4. 개인정보 처리방침에 꼭 들어갈 내용 (사이트 담당 참고)

- 위 1번 표 그대로: 무엇이, 언제(켠 경우에만), 어디로(Anthropic·OpenAI·Google, ntfy·Pushover) 가는지, 개발자는 받지도 보관하지도 않는다는 것.
- 비서가 행동하기 동의 화면에서 보여 주는 내용과 끄는 방법.
- 2번의 '수집하지 않는 것', 기기 안에서만 처리하는 것(사진·연락처·캘린더).
- 문의 메일, 시행일.
