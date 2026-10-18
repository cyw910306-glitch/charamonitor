import AppKit
import SwiftUI

/// "AI 비서" page: a chat with the menu bar character about this Mac.
/// The app puts the current numbers into every question and shows them as chips under the answer; buttons under
/// an answer open 클리너, 보안 점검 or 활성 상태 보기, whose own confirmations do any real work.
struct AssistantView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: AppSettings
    let onBack: () -> Void
    /// QA: open on 비서 설정.
    var startOnSettings = false

    @ObservedObject private var model = AssistantModel.shared
    @ObservedObject private var byo = BYOSettings.shared   // 내 AI 연결: the line under the chat follows it
    @ObservedObject private var agent = AgentCenter.shared
    @ObservedObject private var pendingStore = AgentCenter.shared.pending
    @ObservedObject private var executor = AgentCenter.shared.executor
    @StateObject private var sprites = SpriteHolder()
    @State private var sub: Sub?
    @State private var draft = ""
    @FocusState private var typing: Bool

    private enum Sub { case settings, cleaner, security }

    static let starters = [L("내 맥 왜 느려?"), L("저장 공간 괜찮아?"), L("배터리 얼마나 남았어?"), L("오늘 일정 알려줘"), L("응원해 줘")]

    var body: some View {
        Group {
            switch shown {
            case .settings: AssistantSettingsView(settings: settings) { sub = nil; skipStart = true }
            #if MAS   // no cleaner or security pages in the App Store build (suggest never offers them there)
            case .cleaner, .security: chat
            #else
            case .cleaner: CleanerView(monitor: monitor) { sub = nil }
            case .security: SecurityView(center: SecurityCenter.shared) { sub = nil }
            #endif
            case nil: chat
            }
        }
        .onChange(of: shown) { PopoverMemory.shared.assistantSettings = $0 == .settings }
    }

    private var shown: Sub? { sub ?? (startOnSettings && !skipStart ? .settings : nil) }

    /// Leaving 비서 설정 opened by `startOnSettings` lands on the chat, not back in the settings.
    @State private var skipStart = false

    private var chat: some View {
        VStack(spacing: 8) {
            ZStack {
                Text("AI 비서").font(.system(size: 13, weight: .semibold))
                HStack {
                    Button(action: onBack) { Label("뒤로", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button { sub = .settings } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("비서 설정")
                }
            }
            .padding(.horizontal, 14)
            header.padding(.horizontal, 12)
            if !pendingStore.pending().isEmpty && agent.active {
                Label(L("확인 기다리는 일 \(pendingStore.pending().count)개"), systemImage: "tray.full")
                    .font(.system(size: 11)).foregroundStyle(Color.accentColor).padding(.horizontal, 12)
            }
            messages
            if showsChips { quickChips }
            inputBar.padding(.horizontal, 12)
        }
        .padding(.vertical, 12)
        .onAppear { model.prewarm(); model.restorePending() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AnimatedDog(cache: sprites.cache(for: settings), pose: DogPose.forCPU(monitor.load), cpu: monitor.load)
                .frame(width: 104, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text(settings.characterName).font(.system(size: 14, weight: .semibold))
                Text(AssistantModel.persona(settings).style.label).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(engineLine).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                    brainMenu
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    /// 이 맥 or a connected AI and its model, right from the chat: the same values 비서 설정 sets (one global choice).
    /// Only providers that can answer now: a saved key (and, in the App Store build, the owner's consent) or a signed-in CLI.
    private var brainMenu: some View {
        Menu {
            Button { byo.provider = nil } label: { Text(byo.provider == nil ? "✓ " + L("이 맥") : L("이 맥")) }
            ForEach(readyProviders, id: \.self) { p in
                let models = byo.available[p] ?? []
                if models.isEmpty {
                    Button { byo.provider = p } label: { Text(verbatim: (byo.provider == p ? "✓ " : "") + p.label) }
                } else {
                    Menu(p.label) {
                        ForEach(models, id: \.self) { m in
                            Button { byo.setModel(m, for: p); byo.provider = p } label: {
                                Text(verbatim: (byo.provider == p && byo.model(p) == m ? "✓ " : "") + m)
                            }
                        }
                    }
                }
            }
        } label: { Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("답할 AI 고르기"))
            .accessibilityLabel(L("답할 AI 고르기"))
    }

    private var readyProviders: [BYOProvider] {
        BYOProvider.allCases.filter { p in
            #if MAS
            return byo.consented(p) && AIKeychain.exists(p)
            #else
            return byo.method == .cli || AIKeychain.exists(p)
            #endif
        }
    }

    private var engineLine: String {
        if let mine = BYOEngine.active(intent: nil) {
            return mine.label + (byo.lastFailure.map { " " + L("방금은 연결이 안 돼서 이 맥이 답했어요: \($0)") } ?? "")
        }
        let k = model.kind()
        if k == .template { return OnDeviceEngine.unavailableReason ?? TemplateEngine().label }
        return model.engine(k).label
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.messages.isEmpty { starters }
                    ForEach(model.messages) { bubble($0).id($0.id) }
                    if model.thinking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            // A tool run says what it is doing ("쿠팡 여는 중") and can be stopped.
                            Text("\(settings.characterName)\(Banmal.particle(settings.characterName, "이", "가")) " + (agent.progress ?? L("생각 중이에요")))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            if agent.progress != nil {
                                Spacer(minLength: 4)
                                if agent.browserOn { Button("브라우저 보기") { agent.revealBrowser() }.controlSize(.small) }
                                Button("멈추기") { agent.stopRun() }.controlSize(.small)
                            }
                        }
                        .id("thinking")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(height: QARender.fullHeight ? nil : 330)
            .onChange(of: model.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(model.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: model.thinking) { on in if on { proxy.scrollTo("thinking", anchor: .bottom) } }
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("무엇이든 물어보세요. 지금 맥의 숫자를 보고 답해요.").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(Self.starters, id: \.self) { q in
                Button(q) { ask(q) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        switch m.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(m.text).font(.system(size: 12)).foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor))
            }
        case .notice:
            Label(m.text, systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .character:
            VStack(alignment: .leading, spacing: 5) {
                Text(m.text).font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.08)))
                if let by = m.by { Text(verbatim: by).font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 4) }
                if !m.chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(m.chips, id: \.self) { chip in
                                Text(chip).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                            }
                        }
                    }
                    .accessibilityLabel(L("답에 쓴 숫자: ") + m.chips.joined(separator: ", "))
                }
                if !m.actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(m.actions, id: \.self) { a in
                            Button { run(a) } label: { Label(a.title, systemImage: a.symbol) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                if !m.suggestions.isEmpty {
                    FlowChips(items: m.suggestions) { ask($0) }
                }
                if !m.contactChoices.isEmpty {
                    FlowChips(items: m.contactChoices) { pick in
                        if let i = m.contactChoices.firstIndex(of: pick) { Task { await model.choose(i, of: m) } }
                    }
                }
                if let id = m.proposal, let card = pendingStore.get(id) {
                    AgentCardView(card: card, countingDown: executor.countingDown.contains(id),
                                  undoable: pendingStore.undoable().contains { $0.id == id },
                                  onApprove: { Task { await agent.approve(id) } },
                                  onCancel: { agent.cancel(id) },
                                  onUndo: { Task { await agent.undo(id) } },
                                  onRetype: { i, a in Task { await agent.retype(id, index: i, address: a) } })
                }
            }
            .padding(.trailing, 30)
        }
    }

    /// The starters again above the input once an answer is in, so a next question is one tap. Hidden while typing.
    private var showsChips: Bool {
        !model.messages.isEmpty && model.messages.last?.role != .user && !model.thinking && draft.isEmpty
    }

    /// Wrapped onto a second line rather than scrolled, so the last chip (응원해 줘) is never cut off at the edge.
    private var quickChips: some View {
        ChipFlow(spacing: 4) {
            ForEach(Self.starters, id: \.self) { q in
                Button(q) { ask(q) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("\(settings.characterName)에게 물어보기", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .onSubmit { ask(draft) }
            Button { ask(draft) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.thinking)
                .accessibilityLabel("보내기")
            Menu {
                Button("대화 지우기") { model.clear() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("더 보기")
        }
    }

    private func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !model.thinking else { return }
        draft = ""
        Task { await model.send(q, monitor: monitor) }
    }

    private func run(_ a: AssistantAction) {
        switch a {
        case .cleaner: sub = .cleaner
        case .security: sub = .security
        case .activityMonitor: External.openApp(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        }
    }
}

/// Short choices under a bubble (동명이인, two readings of a date); tapping one asks it.
struct FlowChips: View {
    let items: [String]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Button(item) { pick(item) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

/// Lays chips left to right and starts a new line when the next one would not fit.
struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.reduce(0) { $0 + $1.width } + spacing * CGFloat($0.count - 1) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY, i = 0
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for size in row {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                i += 1
            }
            y += (row.map(\.height).max() ?? 0) + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[CGSize]] {
        var rows: [[CGSize]] = [], x: CGFloat = 0
        for size in subviews.map({ $0.sizeThatFits(.unspecified) }) {
            if rows.isEmpty || x + size.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        return rows
    }
}
