# 기여하기 (Contributing)

이슈와 풀 리퀘스트를 환영해요. Issues and pull requests are welcome.

- **라이선스**: 기여한 코드와 그림은 이 저장소와 같은 [PolyForm Noncommercial 1.0.0](LICENSE) 으로 공개되는 데 동의하는 것으로 봐요. By contributing you agree your work is released under the same license.
- **그림**: 직접 그린 오리지널만 받아요. 다른 작품의 캐릭터를 닮은 그림, 출처를 모르는 이미지는 받지 않아요. Original art only, nothing derived from someone else's characters.
- **빌드와 테스트**: 두 빌드가 모두 컴파일되고 테스트가 통과해야 해요.
  ```bash
  swift build
  swift build -Xswiftc -DMAS --build-path .build-mas
  swift test
  ```
- **앱스토어판**: 샌드박스에서 못 하는 기능만 `#if !MAS` 로 감싸요([docs/appstore/review-notes.md](docs/appstore/review-notes.md)).
- **문구**: 화면 문구는 한국어로 쓰고 `L("...")`(또는 SwiftUI 문자열)로 감싸요. 영어는 `tools/i18n` (`extract.py`, `chunk-N.en.json`, `merge.py`)으로 넣어요. 문구에 em dash 는 쓰지 않아요.
- **외부 의존성**: Apple 프레임워크만 써요. 새 패키지는 추가하지 않아요.
- **개인정보**: 새로 밖으로 나가는 데이터가 생기면 기본 꺼짐으로 두고, `web/privacy.html` 과 [docs/appstore/privacy-label.md](docs/appstore/privacy-label.md) 를 같이 고쳐요.
- **보안 문제**는 공개 이슈 대신 메일(cyw910306@gmail.com)로 알려 주세요.
