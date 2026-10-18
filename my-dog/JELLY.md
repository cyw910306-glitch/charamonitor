# 젤리 (우리 강아지) 스펙

사진: `my-dog/jelly-avatar.jpg` (512px 앱 번들용). 원본 `my-dog/jelly.jpg` 는 스튜디오 촬영본(저작권 촬영자)이라 저장소에 올리지 않아요(.gitignore).

## 외형 (사진에서 추출)
- 견종 느낌: 말티푸/토이푸들 믹스, 테디베어 컷, 둥근 머리
- 귀: 복슬복슬한 늘어진 귀가 옆으로 둥글게 퍼짐 (floppy + fluffy)
- 주둥이: 짧음 (short), 코·눈: 거의 검은 진갈색, 눈 크고 동그람
- 체형: 소형 (small), 다리까지 털이 풍성함 (fluffy = true)
- 무늬: 가슴에 흰 패치 (whiteChest)
- 꼬리: 사진에 안 보임, 푸들 믹스라 복슬 꼬리로 가정 (fluffy)

## 색 (사진 중앙값 샘플, 도트용으로 약간 진하게)
- 몸 기본: 사진 #D6B89C, 도트 권장 #D8B290
- 그림자 털: 사진 #CCA98F
- 가슴 흰색: #F5EDE6
- 코: #3B2C26, 눈: #2A2628

## 적용 계획
- `DogProfile.defaultDog` = 젤리 (name "젤리", ears floppy, tail fluffy, snout short, build small, fluffy true, pattern whiteChest)
- 프리셋 목록 맨 앞에 "젤리 (우리 강아지)"
- `AppSettings.photoPath` 기본값 = 이 사진, 대시보드 머리에 원형 사진
- 앱 표시 이름 "젤리 모니터" 검토
- 도트가 사진과 닮았는지 사진과 나란히 놓고 적대 검증

## 상태
완성·설치(2026-09-28). ~/Applications/DogMonitor.app. 재빌드 `bash scripts/build_app.sh --install --open`.
