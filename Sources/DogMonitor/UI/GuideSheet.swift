import SwiftUI

/// 설정 > 사용법: the whole app on one scrolling card, section by section, with the bubble tour one tap away.
struct GuideSheet: View {
    let onTour: () -> Void
    let onClose: () -> Void

    /// 맥과 같이 놀기: the App Store build has only 바쁜 맥.
    static var macLine: String {
        #if MAS
        L("맥과 같이 놀기: 맥이 오래 바쁘면 커서 친구가 땀을 흘리며 맨 앞 창을 영차영차 밀어요. 설정에서 켜요.")
        #else
        L("맥과 같이 놀기: 다운로드가 끝나면 커서 친구가 파일을 날라 주고, 휴지통을 비우면 봉투를 뻥 차고, 맥이 오래 바쁘면 땀을 흘리며 맨 앞 창을 밀어요. 설정에서 하나씩 켜요.")
        #endif
    }

    /// Symbol, title and lines of each section, in the order a new user meets them.
    static let sections: [(symbol: String, title: String, lines: [String])] = [
        ("menubar.rectangle", L("메뉴바 캐릭터"), [
            L("맥이 바쁠수록 빨리 달리고, 한가하면 걷거나 쉬고 잠들어요. 옆 숫자는 CPU 사용량이에요."),
            L("누르면 대시보드가 열려요. 말풍선이 뜨면 누를 때 닫히거나 다음 이야기로 넘어가요."),
        ]),
        ("square.grid.2x2", L("대시보드"), [
            L("CPU·메모리·저장 공간·배터리·네트워크를 한눈에 봐요."),
            L("오른쪽 버튼: 클리너(안 쓰는 앱·캐시 정리), 보안(맥 보호 상태 점검), 캐릭터 선택, 꾸미기, 펫 키우기, AI 비서, 활성 상태 보기, 설정, 더보기."),
        ]),
        ("person.crop.square", L("캐릭터 고르기와 꾸미기"), [
            L("캐릭터 선택에서 강아지·고양이·캐릭터를 고르거나, 사진이나 그림 한 장으로 나만의 캐릭터를 만들어요."),
            L("꾸미기에서 캐릭터 색을 바꿔요. 내가 만든 캐릭터 칸을 오른쪽 클릭하면 꾸미기와 삭제가 있어요."),
        ]),
        ("cursorarrow.motionlines", L("커서 친구"), [
            L("커서를 따라 걷고, 멀리 가면 뛰어와요. 멈추면 곁에서 놀다가 낮잠을 자요."),
            L("누르면 반응하고, 3번 연달아 누르면 어지러워하고, 5번이면 삐쳐요."),
            L("설정의 커서 친구 카드에서 누르면 소리를 켜면 누를 때마다 멍, 야옹, 뾱 하고 울어요. 내 캐릭터는 꾸미기에서 소리 파일을 넣을 수 있어요."),
            L("꾸욱 누르면 웅크렸다가, 잡고 휙 던지면 날아가 튕겨요. ⌥ 클릭하면 퀵물어보기가 열려요."),
            L("오른쪽 클릭 메뉴의 '복제해서 바탕화면에 두기'로 복제 친구를 만들어요(최대 8마리). 복제 친구는 혼자 돌아다니고 서로 인사해요."),
        ]),
        ("sparkles", L("데스크톱 친구들"), [
            L("설정의 친구 카드마다 스위치로 켜고 꺼요. 메뉴바 메뉴의 데스크톱 친구에서도 바로 켤 수 있어요."),
            L("대롱대롱 친구: 사진이나 캐릭터가 화면 위에서 매달려 흔들려요."),
            L("풀밭 친구들: 독 위에 모여 살아요. 누르면 포즈를 바꾸며 말을 걸고 옆 친구도 돌아봐요. 여러 번 누르면 어지러워하다 삐지고, 커서로 문지르면 쓰다듬어져요. ⌥ 클릭은 퀵물어보기예요."),
            L("폴더 친구: 열린 Finder 창 위쪽 끝에 올라앉아 놀고, 창을 옮기면 같이 가요. 창을 닫으면 폴짝 내려와요. 창마다 한 명씩 둘 수도 있어요. 폴더 아이콘 위에 캐릭터를 입혀 둘 수도 있어요."),
            L("바탕화면 러그: 가장자리를 끌면 접히고, 가운데를 문지르면 주름이 져요. 두 번 누르면 다시 펴요. 크기·무늬·색을 바꿀 수 있어요."),
            L("날씨 창문: 받침 위 수정구슬 속에서 캐릭터가 고른 도시의 지금 날씨를 지내요. 끌어서 옮기고, 누르면 캐릭터가 폴짝 뛰어요. 켜 두면 아침에 우산이나 겉옷 이야기를 해 줘요."),
            L("집중 타이머: 집중하는 동안 머리 위에 시간이 뜨고 캐릭터가 공부해요."),
            L("놀이 모드: 커서 친구나 복제 친구를 오른쪽 클릭해서 고르면 키보드로 움직여요. ← →로 걷고 Shift로 뛰고, 스페이스로 점프(공중에서 한 번 더 누르면 2단 점프), ↓로 웅크려요. 창 위쪽 끝에 올라서고 ↓+스페이스로 내려가요. Esc로 끝내요."),
            L("별 줍기·2인 대결: 놀이 메뉴에서 골라요. 60초 동안 별을 모으고, 2인 대결은 W·A·S·D로 한 명 더 같이 해요."),
            L("클릭 놀이: 메뉴 막대의 데스크톱 친구 > 놀이에서 숨바꼭질·공놀이·두더지잡기를 골라요. 마우스로만 놀아요."),
            L("장난감 상자: 설정에서 트램펄린·공·쿠션·미끄럼틀을 꺼내 두면 커서 친구와 복제 친구가 가끔 놀러 와요. 끌어서 옮기고 오른쪽 클릭으로 치워요. 놀이 모드에서는 트램펄린이 높이 튕겨 주고 미끄럼틀이 아래로 태워 줘요."),
            macLine,
            L("친구들끼리: 복제 친구 카드에서 술래잡기·기차놀이를, 풀밭 친구들 카드에서 줄넘기를 켜면 가끔 친구들끼리 놀아요. 단체 춤을 켜 두면 축하할 일이 생길 때 다 같이 10초 동안 춤춰요."),
            L("모든 친구는 오른쪽 클릭하면 그 친구의 메뉴가 나와요."),
        ]),
        ("bubble.left.and.text.bubble.right", L("AI 비서"), [
            L("대시보드의 AI 비서에서 말을 걸어요. 맥 상태, 일정, 날씨 같은 걸 물어보거나 일을 부탁할 수 있어요."),
            L("메일 보내기나 일정 넣기처럼 밖으로 나가는 일은 항상 카드로 보여 주고, 누를 때만 해요."),
            L("내 AI(Claude·ChatGPT·Gemini)를 연결하면 더 똑똑하게 답해요."),
        ]),
        ("arrow.left.arrow.right", L("다른 맥으로 옮기기"), [
            L("설정 > 내 설정 내보내기로 파일 하나를 만들고, 다른 맥에서 그 파일을 열면 지금 모습 그대로 옮겨져요."),
            L("AI 키와 권한은 담지 않아요. 가져오기 전 상태는 백업돼서 되돌릴 수 있어요."),
        ]),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 10) {
                Text("사용법").font(.system(size: 14, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.sections, id: \.title) { s in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(s.title, systemImage: s.symbol).font(.system(size: 12, weight: .semibold))
                                ForEach(s.lines, id: \.self) { line in
                                    Text("· " + line).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 360)
                HStack {
                    Button("말풍선으로 따라 하기", action: onTour)
                    Spacer()
                    Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(width: 330)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }
}
