import AppKit
import SwiftUI

/// The 근처 친구 (.nearby), 무전기 (.walkieTalkie) or 원격 지원 (.remoteHelp) part of 설정 > 플러그인.
struct NearbySettings: View {
    let part: PluginID
    @ObservedObject private var bus = SocialBus.shared
    @AppStorage("social.on", store: AppDefaults.store) private var socialOn = false
    @AppStorage("social.voice", store: AppDefaults.store) private var voiceOn = false
    @AppStorage("social.remoteHelp", store: AppDefaults.store) private var remoteOn = false
    @AppStorage("social.nickname", store: AppDefaults.store) private var nickname = ""
    @State private var picked: NearbyMac?
    @State private var typed = ""
    @State private var removing: SocialFriend?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch part {
            case .walkieTalkie: walkie
            case .remoteHelp: remote
            default: nearby
            }
        }
        .font(.system(size: 12))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 근처 친구

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("근처 친구 켜기"), isOn: $socialOn).toggleStyle(.switch).controlSize(.small)
                .onChange(of: socialOn) { _ in SocialBus.shared.refresh() }
            note(L("같은 와이파이의 맥끼리 코드로 친구를 맺고 대화해요. 켠 동안만 이 맥이 보이고, 친구가 아닌 맥은 메시지도 목소리도 보낼 수 없어요. 로그인이나 인터넷 친구는 아직 없어요."))
            if bus.isOn {
                HStack {
                    Text(L("내 이름"))
                    TextField(bus.nickname, text: $nickname).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                }
                Divider()
                addFriend
                if !bus.friends.isEmpty {
                    Divider()
                    friendList
                }
            }
        }
        .confirmationDialog(L("친구를 삭제할까요?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L("삭제"), role: .destructive) { if let f = removing { bus.forget(f.id) }; removing = nil }
        } message: {
            Text(L("서로의 친구 목록에서 빠져요. 다시 친구가 되려면 코드를 새로 넣어야 해요."))
        }
    }

    private var addFriend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("친구 추가")).font(.system(size: 12, weight: .semibold))
            if let code = bus.code {
                HStack(spacing: 10) {
                    Text(verbatim: "\(code.prefix(3)) \(code.suffix(3))").font(.system(size: 22, weight: .bold, design: .monospaced))
                    Button(L("그만")) { bus.hideCode() }.controlSize(.small)
                }
                note(L("2분 동안 보여요. 친구 맥에서 '코드 넣기'로 이 맥을 골라 이 숫자를 넣어 주세요. 세 번 틀리면 새 코드로 바뀌고, 여섯 번이면 멈춰요. 두 맥에 뜨는 확인 숫자가 같은지 꼭 봐 주세요."))
            } else {
                Button(L("내 코드 보여주기")) { bus.showCode() }.controlSize(.small)
            }
            Text(L("코드 넣기")).font(.system(size: 11, weight: .semibold)).padding(.top, 4)
            if bus.nearby.isEmpty {
                note(L("코드를 보여주고 있는 맥이 근처에 없어요. 친구 맥에서 '내 코드 보여주기'를 눌러 주세요."))
            } else {
                Picker(L("친구 맥"), selection: $picked) {
                    Text(L("고르기")).tag(NearbyMac?.none)
                    ForEach(bus.nearby, id: \.self) { Text(verbatim: $0.nickname).tag(NearbyMac?.some($0)) }
                }
                .controlSize(.small)
                if Set(bus.nearby.map(\.nickname)).count < bus.nearby.count || Set(bus.nearby.map(\.id)).count < bus.nearby.count {
                    note(L("⚠️ 같은 이름의 맥이 둘 이상 보여요. 다른 맥이 흉내 낼 수 있으니 친구 맥과 확인 숫자를 꼭 비교해 주세요."))
                }
                HStack {
                    TextField(L("6자리 코드"), text: $typed).textFieldStyle(.roundedBorder).frame(maxWidth: 110)
                        .onChange(of: typed) { v in let d = String(v.filter(\.isNumber).prefix(6)); if d != v { typed = d } }
                    Button(L("연결")) {
                        if let picked { bus.join(picked, code: typed) }
                        typed = ""
                    }
                    .disabled(picked == nil || typed.count != 6)
                    .controlSize(.small)
                }
            }
        }
    }

    private var friendList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("친구")).font(.system(size: 12, weight: .semibold))
            ForEach(bus.friends) { f in
                HStack(spacing: 6) {
                    Circle().fill(bus.online.contains(f.id) ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                    Text(verbatim: f.nickname)
                    if bus.online.contains(f.id) {
                        Text(verbatim: "\(f.status.emoji) \(f.status.label)").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text(L("오프라인")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("대화하기")) { FriendWindow.open(f.id) }.controlSize(.small)
                    Button(L("삭제")) { removing = f }.controlSize(.small)
                }
            }
        }
    }

    // MARK: 무전기, 원격 지원

    private var walkie: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("무전기 켜기"), isOn: $voiceOn).toggleStyle(.switch).controlSize(.small)
                .onChange(of: voiceOn) { on in if !on { VoiceTalk.shared.end() } }
            note(L("친구 창의 무전기 버튼을 누르고 있는 동안만 마이크가 켜지고, 그 친구에게만 목소리가 가요. 처음 누를 때 마이크 권한을 물어요."))
            if !socialOn { note(L("근처 친구를 먼저 켜 주세요.")) }
        }
    }

    private var remote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("원격 지원 받기 허용"), isOn: $remoteOn).toggleStyle(.switch).controlSize(.small)
            note(L("친구가 요청하면 먼저 물어봐요. 수락해도 친구 맥에서 macOS 화면 공유가 열리고 이 맥이 한 번 더 허락을 받아요. 이 앱은 화면을 찍거나 조작하지 않아요. 맥끼리만 돼요."))
            note(L("도움을 줄 때는 친구 메뉴의 '원격 지원 요청'을 눌러요."))
            if !socialOn { note(L("근처 친구를 먼저 켜 주세요.")) }
        }
    }
}

/// 친구 ▸ 친구 추가…: the 근처 친구 settings in a small window of their own.
enum NearbyWindow {
    private static var window: NSWindow?

    static func open() {
        let w = window ?? {
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420), styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
            w.title = L("근처 친구")
            w.contentView = NSHostingView(rootView: ScrollView { NearbySettings(part: .nearby).padding(14) }.frame(width: 360, height: 420))
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            w.sharingType = .none   // the live code stays out of screen shares
            w.center()
            return w
        }()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
