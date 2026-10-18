# 캐릭터 팩 만들기 (Character packs)

내 그림 파일로 메뉴바 캐릭터를 만드는 방법이에요. 팩은 폴더 하나(`pack.json` + `frames/` 의 PNG)이고, 앱을 켤 때 읽어서 **캐릭터 선택 > 캐릭터** 탭에 오리지널 캐릭터와 나란히 나와요. 사진 한 장으로 만드는 더 쉬운 길은 앱의 **새 캐릭터 만들기**예요. 팩은 프레임을 하나하나 직접 그리고 싶을 때 써요.

**English summary**: a pack is a folder `pack-<slug>/` with `pack.json` and `frames/<key>-<i>.png`. Each frame is a
transparent PNG of exactly 34N x 20N pixels (N = `density`), facing right, feet on the bottom row. Put the folder in
`~/Library/Application Support/DogMonitor/Packs/` and relaunch the app. Fields and limits are below.

직접 권리를 가진 그림만 쓰세요. 남의 캐릭터를 그린 팩을 나누거나 팔면 안 돼요.

## 어디에 넣나요

| 빌드 | 폴더 |
|---|---|
| 직접판(소스로 빌드, 사이트의 DMG) | `~/Library/Application Support/DogMonitor/Packs/` |
| 앱스토어판(샌드박스) | `~/Library/Containers/com.jelly.charamonitor.mas/Data/Library/Application Support/DogMonitor/Packs/` |

캐릭터 선택 화면 아래의 **팩 폴더 열기**를 누르면 그 빌드의 폴더가 열려요(없으면 만들어요). 팩을 넣거나 고친 뒤에는 앱을 다시 켜요. 폴더 이름이 `pack-` 으로 시작하는 것만 읽고, 최대 32개예요.

## 폴더 구조

```
Packs/
  pack-my-cat/
    pack.json
    frames/
      lying-0.png
      slowWalk-0.png  slowWalk-1.png
      walk-0.png  walk-1.png  walk-2.png  walk-3.png
      fastWalk-0.png  fastWalk-1.png
      run-0.png  run-1.png
      sprint-0.png  sprint-1.png
      exhausted-0.png  exhausted-1.png
      special-0.png ... special-5.png      (선택)
```

- 폴더 안 어떤 것도 심볼릭 링크면 안 돼요(링크는 읽지 않고 팩 전체를 건너뛰어요).
- 프레임 파일 이름은 `<키>-<번호>.png`, 번호는 0부터 `frames` 에 적은 개수 - 1 까지예요.

## pack.json

```json
{
  "version": 1,
  "id": "pack-my-cat",
  "name": "우리 고양이",
  "special": "꾹꾹이",
  "blurb": "창가에서 낮잠 자는 걸 좋아해요",
  "frames": { "lying": 1, "slowWalk": 2, "walk": 4, "fastWalk": 2, "run": 2, "sprint": 2, "exhausted": 2, "special": 6 },
  "seconds": { "walk": 0.2, "special": 0.08 },
  "density": 2,
  "smooth": false,
  "persona": "proud",
  "cries": ["냐앙", "먀?"],
  "say": { "special": ["꾹꾹 해 줄게"] }
}
```

| 필드 | 필수 | 뜻과 제한 |
|---|---|---|
| `version` | 예 | 항상 `1` |
| `id` | 예 | 폴더 이름과 똑같이. `pack-` + 소문자·숫자·`-` (첫 글자는 소문자나 숫자, 최대 40자) |
| `name` | 예 | 캐릭터 이름, 1~40자 |
| `special` | 아니요 | 특수 기술 이름(미리보기 화면), 최대 40자 |
| `blurb` | 아니요 | 미리보기 화면의 한 줄 소개, 최대 200자 |
| `frames` | 예 | 키마다 프레임 수. 아래 '키' 표 참고 |
| `seconds` | 아니요 | 키마다 프레임 한 장의 시간(초, 0.05~1.0). 자세 키와 모먼트 키만(`special.2` 같은 테이크는 안 됨). 없으면 앱 기본 속도(CPU를 따라 빨라짐) |
| `density` | 아니요 | 1포인트당 픽셀 수. 기본 `2`. 도트는 1~2, `smooth` 는 1~8 |
| `smooth` | 아니요 | `true` 면 일러스트: 부드러운 가장자리를 그대로 두고 매끄럽게 줄여 그려요. 기본 `false`(도트: 알파 128 미만은 투명, 이상은 불투명으로 딱 끊고 최근접 보간) |
| `persona` | 아니요 | AI 비서와 말풍선 말투: `friendly` `calm` `shy` `proud` `bright` `polite` `cry`. 모르는 값은 무시해요 |
| `cries` | 아니요 | `cry`(울음소리 말투)일 때 앞에 붙는 소리, 1~8자짜리 최대 6개 |
| `say` | 아니요 | 모먼트(테이크) 키마다 그 모션이 나올 때 말풍선에 띄울 말, 키당 최대 6줄, 줄당 60자. 말풍선에만 나오고 AI 에게는 보내지 않아요 |

## 키와 프레임 수

| 키 | 언제 | 프레임 |
|---|---|---|
| `lying` | CPU 0~5%, 자는 중 | 1~12 (필수) |
| `slowWalk` | 5~15% | 2~12 (필수) |
| `walk` | 15~30% | 2~12 (필수) |
| `fastWalk` | 30~45% | 2~12 (필수) |
| `run` | 45~65% | 2~12 (필수) |
| `sprint` | 65~85% | 2~12 (필수) |
| `exhausted` | 85% 이상, 헉헉 | 2~12 (필수) |
| `hungry` | 배터리가 적을 때, 먹을 것 찾기 | 2~16 (선택) |
| `eat` | 충전 중, 냠냠 | 2~16 (선택) |
| `special` | 아주 바쁠 때, 특수 기술 | 2~16 (선택) |
| `special.2` ~ `special.4` | 같은 모먼트의 다른 테이크(번갈아 나와요) | 2~16 (선택) |

테이크는 `hungry.2`, `eat.3` 처럼 세 모먼트 모두에 쓸 수 있어요. 기본 키(`special`)가 있어야 하고 `.2`, `.3`, `.4` 순서로 빠짐없이 이어져야 해요.

## 프레임 그림 규칙

- **크기**: 정확히 (34 × density) × (20 × density) 픽셀. density 2면 68 × 40, 4면 136 × 80. 메뉴바에서는 언제나 34 × 20포인트로 보여요.
- **방향과 자리**: 오른쪽을 보고, 발이 맨 아래 줄에 닿게. 모든 프레임에서 같은 크기·같은 바닥선을 지켜야 걸을 때 흔들리지 않아요.
- **배경**: 투명 PNG. 빈 프레임(전부 투명)은 거부해요.
- **파일 크기**: density 2 기준 장당 64KB 이하(픽셀 수에 비례해 커져요, density 4면 256KB). `pack.json` 은 16KB 이하.
- **외곽선**: 도트 팩은 `walk` 첫 프레임의 가장자리에 가장 많이 쓴 색을 외곽선으로 보고, 어두운 메뉴바에서는 그 선만 밝게 바꿔 보여 줘요. 1픽셀 어두운 외곽선을 두르면 두 메뉴바 모두에서 잘 보여요.

## 내 그림으로 만드는 순서

1. **그리기**: 아무 그림 앱(Aseprite, Pixelmator, Procreate 등)에서 68 × 40 캔버스(도트) 또는 136 × 80 같은 큰 캔버스(일러스트, `"smooth": true`, `"density": 4`)를 만들고, 자세마다 프레임을 그려요. 처음에는 `walk` 4장을 그려 다른 자세에 같은 그림을 복사해 써도 돼요(각 자세 최소 장수만 맞추면 돼요).
2. **내보내기**: 프레임마다 투명 PNG로 `frames/<키>-<번호>.png` 이름으로 저장해요. 큰 그림을 줄일 때 도트는 최근접 보간으로 줄여야 깨끗해요. 일러스트는 macOS 의 `sips` 로도 돼요:
   ```bash
   sips -z 80 136 big-walk-0.png --out frames/walk-0.png    # 높이 80, 너비 136
   ```
3. **pack.json**: 위 예시를 복사해 `id`(폴더 이름과 같게), `name`, `frames` 개수를 맞춰요.
4. **확인**(직접판, 소스로 빌드한 경우): 앱에 넣기 전에 모든 프레임을 밝은·어두운 메뉴바 위에 그려 봐요. 팩에 문제가 있으면 이유를 출력해요.
   ```bash
   swift build
   .build/debug/DogMonitor --render-pack ~/path/to/pack-my-cat /tmp/pack-my-cat.png
   open /tmp/pack-my-cat.png
   ```
5. **넣기**: 폴더를 위 '어디에 넣나요'의 `Packs/` 에 옮기고 앱을 다시 켜요. 캐릭터 선택 > 캐릭터 탭에서 고르면 메뉴바·커서 친구·대롱대롱 친구 등 모든 곳에 나와요.

팩이 안 보이면 설정 > **문제 보내기** 의 진단 내용에 `pack skipped: <이유>` 줄이 있어요(터미널에서 `.build/debug/DogMonitor` 로 띄우면 같은 이유가 바로 출력돼요). 꾸미기 색 바꾸기는 팩에는 없고, 그림 자체를 고쳐야 해요.
