import AppKit
import SwiftUI

/// 비서 설정 > "비서가 행동하기" (design sections 9 and 11): the switch with its consent sheet, the per-action rules
/// (dots' four tiers, floors greyed), 맡긴 일, 기억한 것, the optional Naver Shopping key and the action log.
struct AgentSettingsPanel: View {
    @ObservedObject private var agent = AgentCenter.shared
    @ObservedObject private var goals = AgentCenter.shared.goals
    @ObservedObject private var memory = AgentCenter.shared.memory
    @ObservedObject private var byo = BYOSettings.shared

    @State private var askingConsent = false
    @State private var naverID = ""
    @State private var naverSecret = ""
    @State private var naverNote: String?
    @State private var showLog = false

    var body: some View {
        Panel {
            HStack {
                Label("비서가 행동하기", systemImage: "wand.and.stars").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("비서가 행동하기", isOn: Binding(get: { agent.enabled && agent.consented }, set: { on in
                    if on && !agent.consented { askingConsent = true } else { agent.enabled = on }
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            note(L("메일 보내기, 일정·미리알림 추가, 쇼핑·항공권 찾기, 가격 지켜보기를 대신 준비해요. 하기 전에 카드로 보여 주고, 확인해야 실행해요. 결제와 송금은 언제나 직접 해요."))
            if byo.provider == nil {
                note(L("먼저 위의 '내 AI 연결'에서 Claude, ChatGPT 또는 Gemini를 연결해 주세요. 계획은 연결한 AI가 세워요."))
            }
            if askingConsent { consent }
            if agent.enabled && agent.consented { rules; goalList; memoryList; naverKey; log }
        }
    }

    // MARK: Consent (App Review 5.1.2(i))

    private var consent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("켜기 전에 확인해 주세요").font(.system(size: 12, weight: .semibold))
            bullet(L("부탁한 말과 오늘 날짜는 연결한 AI(\(byo.provider?.label ?? L("내 AI")))로 보내져요."))
            bullet(L("비서 설정에서 '일정도 내 AI로'를 켰다면 일정 제목도 보내져요."))
            bullet(L("비밀번호와 카드 번호는 AI로 보내지 않아요. 연락처 주소는 메일을 보낼 때 메일 서버로만 가요."))
            #if !MAS
            bullet(L("'받은 메시지·일정도 내 AI로'를 켜면 비서가 일을 하려고 일정, 메일 본문, 연락처의 메일·전화번호, 기억한 것을 연결한 AI로 읽을 수 있어요. 끄면 읽지 않아요."))
            #endif
            bullet(L("보내기·만들기는 카드에서 확인한 뒤에만 하고, 결제·송금·비밀번호 변경·본인인증은 하지 않아요."))
            bullet(L("자리를 비운 사이 맡긴 일은 찾아보기만 하고, 할 일은 카드로 남겨요."))
            #if !MAS
            bullet(L("에이전트 브라우저는 쇼핑·항공권 사이트를 열어 찾아보고, 장바구니 담기처럼 상태를 바꾸는 버튼은 확인받아 눌러요. 결제·로그인 화면이 나오면 멈추고 넘겨요."))
            #endif
            HStack {
                Button("동의하고 켜기") { agent.consented = true; agent.enabled = true; askingConsent = false }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("취소") { askingConsent = false }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    // MARK: Rules

    private var rules: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text("행동 규칙").font(.system(size: 12, weight: .semibold))
            ForEach(AgentPlanner.plannable.filter { $0 != .undo }, id: \.self) { type in
                HStack {
                    Text(AgentCardView.title(type)).font(.system(size: 11))
                    Spacer()
                    if AgentPolicy.isFixed(type) {
                        Text(AgentPolicy.defaultTier(type).label).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Picker(AgentCardView.title(type), selection: Binding(get: { agent.policy.tier(for: type) }, set: { agent.policy.tiers[type] = $0 })) {
                            // ponytail: '규칙에 맞으면 바로' hidden until a rule editor exists (no rule = always confirm).
                            ForEach(Tier.allCases.filter { $0 >= AgentPolicy.floor(type, selfOnly: true) && $0 != .prepareOnly && $0 != .preapproved }, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        .labelsHidden().fixedSize().controlSize(.small)
                    }
                }
            }
            note(L("메일은 언제나 확인해요(나에게 보내는 메일만 규칙으로 바로 보낼 수 있어요). 결제·송금·비밀번호는 설정과 상관없이 하지 않아요."))
            #if !MAS
            Toggle(isOn: $agent.browserOn) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("에이전트 브라우저").font(.system(size: 11))
                    Text("사이트를 직접 열어 찾고 비교해요. 로그인은 이 창에서 한 번 해 두면 기억해요.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            #endif
        }
    }

    // MARK: 맡긴 일

    private var goalList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text("맡긴 일").font(.system(size: 12, weight: .semibold))
            let list = goals.list()
            if list.isEmpty { note(L("\"3만 원 아래로 내려가면 알려줘\"처럼 부탁하면 여기에 생겨요. 맥이 켜져 있을 때 확인해요.")) }
            ForEach(list) { g in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.title).font(.system(size: 11))
                        Text(Self.kind(g.kind)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        Text(Self.state(g)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if case .paused = g.state {
                        Button("다시") { goals.resume(g.id) }.controlSize(.small)
                    } else if case .active = g.state {
                        Button("멈춤") { goals.pause(g.id, reason: L("직접 멈춤")) }.controlSize(.small)
                    }
                    Button("지우기", role: .destructive) { goals.delete(g.id) }.controlSize(.small)
                }
            }
        }
    }

    static func kind(_ k: GoalKind) -> String {
        switch k {
        case .priceWatch(let q, let target, let drop):
            return q + " · " + (target.map { L("\(Fmt.won($0)) 이하") } ?? drop.map { L("\($0)% 하락") } ?? L("새 최저가"))
        case .agent(let prompt): return prompt
        }
    }

    static func state(_ g: Goal) -> String {
        switch g.state {
        case .active: return L("다음 확인 \(ActionCopy.when(g.nextRun))")
        case .waiting: return L("확인 기다리는 카드가 있어요")
        case .paused(let why, let until): return L("멈춤: \(why)") + (until.map { L(" (\(ActionCopy.when($0))까지)") } ?? "")
        case .done: return L("끝났어요")
        }
    }

    // MARK: 기억한 것

    private var memoryList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text("기억한 것").font(.system(size: 12, weight: .semibold))
            if memory.entries.isEmpty { note(L("\"내 배송지는 회사로 기억해\"처럼 말하면 기억해요. AI에 보여 줄지 고를 수 있어요.")) }
            ForEach(memory.entries) { e in
                HStack {
                    Text("\(e.key): \(e.value)").font(.system(size: 11)).lineLimit(2)
                    Spacer()
                    Toggle("AI에 보여주기", isOn: Binding(get: { e.showToAI }, set: { memory.edit(e.id, showToAI: $0) }))
                        .toggleStyle(.checkbox).font(.system(size: 10))
                    Button("지우기", role: .destructive) { memory.delete(e.id) }.controlSize(.small)
                }
            }
        }
    }

    // MARK: 네이버 쇼핑 키 (optional: prices without the AI)

    private var naverKey: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text("가격 확인 (선택)").font(.system(size: 12, weight: .semibold))
            note(NaverShopKeychain.exists() ? L("네이버 쇼핑 키가 있어요. 상품 찾기와 가격 지켜보기에 최저가를 보여 줘요.")
                                            : L("네이버 개발자센터(developers.naver.com)에서 검색 API 애플리케이션을 만들면 받는 Client ID와 Secret을 넣으면, AI를 쓰지 않고 최저가를 보여 주고 가격을 지켜봐요."))
            HStack(spacing: 6) {
                TextField("Client ID", text: $naverID).textFieldStyle(.roundedBorder).font(.system(size: 11))
                SecureField("Client Secret", text: $naverSecret).textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button("저장") {
                    do {
                        try NaverShopKeychain.save(NaverShopCredentials(clientID: naverID.trimmingCharacters(in: .whitespaces),
                                                                        clientSecret: naverSecret.trimmingCharacters(in: .whitespaces)))
                        naverID = ""; naverSecret = ""; naverNote = L("저장했어요.")
                    } catch {
                        naverNote = L("저장하지 못했어요.")
                    }
                }
                .controlSize(.small).disabled(naverID.isEmpty || naverSecret.isEmpty)
            }
            if let n = naverNote { note(n) }
        }
    }

    // MARK: 행동 기록

    private var log: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            DisclosureGroup("행동 기록", isExpanded: $showLog) {
                ForEach(Array(Self.logLines(agent.pending.audit.url).prefix(20).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12))
        }
    }

    /// Newest first: "10/6 15:02 메일 보내기 · done · to: example.com".
    static func logLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [L("아직 기록이 없어요.")] }
        let iso = ISO8601DateFormatter(), f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return text.split(separator: "\n").reversed().compactMap { line in
            guard let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String] else { return nil }
            let when = j["time"].flatMap(iso.date).map(f.string) ?? ""
            let what = j["type"].flatMap(AgentActionType.init).map(AgentCardView.title) ?? ""
            return "\(when) \(what) · \(j["state"] ?? "") · \(j["summary"] ?? "")"
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("·").font(.system(size: 11))
            Text(s).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
