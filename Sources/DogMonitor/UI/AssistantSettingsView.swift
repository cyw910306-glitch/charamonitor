import AppKit
import EventKit
import SwiftUI

/// "비서 설정": 말투, the engine, 먼저 말 걸기, voice and the opt-in integrations.
struct AssistantSettingsView: View {
    @ObservedObject var settings: AppSettings
    let onBack: () -> Void

    @ObservedObject private var a = AssistantSettings.shared
    @State private var calendarNote: String?
    @State private var remindersNote: String?
    @State private var mailNote: String?
    #if !MAS
    @ObservedObject private var inbox = InboxSettings.shared
    @ObservedObject private var inboxCenter = InboxCenter.shared
    @State private var contactsAsked = false
    #endif
    @State private var phoneNote: String?
    @ObservedObject private var byo = BYOSettings.shared
    @State private var byoKey = ""
    @State private var byoNote: String?
    @State private var byoChecking = false
    @State private var sending = false
    /// 대사 고치기: what is typed per line key, kept while it has an unknown {이름} (only valid text is saved).
    @State private var lineDrafts: [String: String] = [:]
    @State private var showLines = AssistantSettingsView.qaShowLines
    /// QA renders open 대사 고치기.
    static var qaShowLines = false
    /// Rebuilt after a permission prompt closed the popover: back to the 연동 panel. A plain read: this init runs
    /// again on every redraw (also during the next prompt), so it is cleared on appear instead.
    @State private var anchor = PopoverMemory.shared.anchor

    var body: some View {
        PageScaffold(title: L("비서 설정"), onBack: onBack, scrollTo: anchor) {
            VStack(spacing: 8) {
                byoPanel.id(PopoverMemory.byo)
                AgentSettingsPanel()
                integrationsPanel.id(PopoverMemory.integrations)
                mailPanel.id(PopoverMemory.mail)
                personaPanel
                enginePanel
                nudgePanel
                linesPanel
                voicePanel
                Panel {
                    Label("하지 않는 것", systemImage: "hand.raised").font(.system(size: 12, weight: .semibold))
                    #if MAS
                    Text("메시지 앱 내용과 다른 앱의 알림은 읽지 않아요. 앱 스토어 버전은 다른 앱의 기록을 열 수 없어요.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    #else
                    Text("문자·메일·알림 내용은 이 맥 안에서 말풍선과 대화에만 쓰고, 파일이나 기록에 남기지 않아요. 아이폰 알림으로도 보내지 않아요. 내 AI에는 위에서 직접 켠 경우에만 일정 질문을 보내요.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    #endif
                }
            }
        }
        .onAppear { PopoverMemory.shared.anchor = nil }
    }

    // MARK: Panels

    private var personaPanel: some View {
        Panel {
            HStack {
                title(L("말투"))
                Spacer()
                Picker("말투", selection: $a.persona) {
                    ForEach(PersonaStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
            }
            let c = settings.shownCharacter
            let preset = settings.shownVoice.style ?? Persona.preset(character: c, id: c == .original ? settings.originalID : c == .cat ? settings.catID : nil)
            note(a.persona == .auto ? L("\(settings.characterName)의 기본 말투는 '\(preset.label)'이에요. 캐릭터를 바꾸면 말투도 따라 바뀌어요.")
                                    : L("어떤 캐릭터든 이 말투로 말해요."))
        }
    }

    private var enginePanel: some View {
        Panel {
            title(L("대화 엔진"))
            note(OnDeviceEngine.unavailableReason ?? OnDeviceEngine.shared.label)
        }
    }

    // MARK: AI 엔진 (내 AI 연결, BYOEngine)

    private var byoPanel: some View {
        Panel {
            HStack(spacing: 5) {
                title(L("AI 엔진"))
                Spacer()
                Picker("AI 엔진", selection: byoProviderBinding) {
                    Text(L("기본 (이 맥)")).tag(BYOProvider?.none)
                    ForEach(BYOProvider.allCases, id: \.self) { Text($0.label).tag(BYOProvider?.some($0)) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
            }
            note(L("내가 쓰는 AI를 연결하면 답이 더 똑똑해져요. 연결이 안 될 때는 이 맥의 AI가 대신 답해요."))
            if let p = byo.provider {
                Divider()
                #if !MAS
                Picker("연결 방법", selection: $byo.method) {
                    Text(L("API 키")).tag(BYOMethod.apiKey)
                    Text(L("구독 계정 (이 맥의 \(p.cliName))")).tag(BYOMethod.cli)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                #endif
                #if MAS
                if !byo.consented(p) { byoConsent(p) } else { byoKeyRows(p) }
                #else
                if byoUsesCLI { byoCLIRows(p) } else { byoKeyRows(p) }
                #endif
                if let byoNote { note(byoNote) }
                if let why = byo.lastFailure { warn(L("최근 연결 실패: \(why)")) }
                Divider()
                HStack {
                    Text(L("받은 메시지·일정도 내 AI로 보내 더 똑똑하게")).font(.system(size: 12))
                    Spacer()
                    Toggle("받은 메시지·일정도 내 AI로", isOn: $byo.sharePersonal).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                if byo.sharePersonal && !BYOEngine.sendsPersonal(byo) {
                    note(L("\(p.label) 구독 계정 연결은 읽기 전용 도구가 켜진 채로 실행돼서, 일정 질문은 이 맥 안에서만 답해요. 일정도 보내려면 API 키로 연결해 주세요."))
                } else {
                    note(byo.sharePersonal ? L("일정 질문도 내 AI가 답해요. 받은 메시지 목록은 지금처럼 앱이 그대로 읽어 줘요.")
                                           : L("일정과 받은 메시지 질문은 지금처럼 이 맥 안에서만 답해요."))
                }
                note(L("내 AI로는 질문, 최근 대화, 질문에 필요한 맥 숫자 스냅샷(CPU·메모리 같은 상태 숫자)만 보내요. 파일이나 다른 기록은 보내지 않아요."))
            }
        }
    }

    private var byoUsesCLI: Bool {
        #if MAS
        return false
        #else
        return byo.method == .cli
        #endif
    }

    private var byoProviderBinding: Binding<BYOProvider?> {
        Binding(get: { byo.provider }, set: { p in
            byo.provider = p
            byo.lastFailure = nil
            byoNote = nil
            byoKey = ""
        })
    }

    #if MAS
    /// App Review 5.1.2(i): who gets what, agreed before a key goes in or anything is sent.
    private func byoConsent(_ p: BYOProvider) -> some View {
        let company = p == .claude ? "Anthropic" : p == .chatgpt ? "OpenAI" : "Google"
        return VStack(alignment: .leading, spacing: 5) {
            Text(L("연결하기 전에 확인해 주세요")).font(.system(size: 12, weight: .semibold))
            note(L("• 질문, 최근 대화, 답에 필요한 맥 상태 숫자(CPU·메모리 같은 것)를 \(company)의 \(p.label)로 보내요."))
            note(L("• 아래 '받은 메시지·일정도 내 AI로'를 켜면 일정 제목도 보내요. 기본은 꺼져 있어요."))
            note(L("• 내 API 키로 보내서 \(company)의 약관과 개인정보 처리방침을 따라요. 파일, 사진, 비밀번호는 보내지 않아요."))
            note(L("• 언제든 'AI 엔진'을 기본으로 바꾸면 더는 보내지 않아요."))
            Button(L("동의하고 연결하기")) { byo.consent(p) }.buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
    #endif

    private func byoKeyRows(_ p: BYOProvider) -> some View {
        let saved = AIKeychain.exists(p)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(saved ? L("저장된 키가 있어요. 바꾸려면 새 키를 붙여 넣어요") : L("\(p.label) API 키 붙여 넣기"), text: $byoKey)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                Button(byoChecking ? L("확인 중…") : L("연결 확인")) { verifyKey(p) }
                    .controlSize(.small).disabled(byoChecking || (byoKey.isEmpty && !saved))
            }
            HStack(spacing: 6) {
                Button(L("키 만들러 가기")) { PermissionFlow.openSettings(p.keyURL, anchor: PopoverMemory.byo) }.controlSize(.small)
                if saved {
                    Button(L("키 지우기")) {
                        AIKeychain.delete(p)
                        byo.available[p] = nil
                        byoNote = L("키를 지웠어요.")
                    }.controlSize(.small)
                }
            }
            HStack {
                Text(L("모델")).font(.system(size: 11))
                Spacer()
                if let list = byo.available[p], !list.isEmpty {
                    Picker("모델", selection: Binding(get: { byo.model(p) }, set: { byo.setModel($0, for: p) })) {
                        ForEach(list, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize().controlSize(.small)
                } else {
                    Text(byo.model(p)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            note(L("키는 이 맥의 키체인에만 저장해요. 쓴 만큼 내 \(p.label) 계정에 요금이 나가요. 연결 확인을 누르면 쓸 수 있는 모델 중 최신 대화용 모델을 골라요."))
        }
    }

    /// Checks the key with the provider's model list; saved to the Keychain only when it works (a busy provider counts).
    private func verifyKey(_ p: BYOProvider) {
        let typed = byoKey.trimmingCharacters(in: .whitespacesAndNewlines)
        byoChecking = true
        byoNote = nil
        Task { @MainActor in
            defer { byoChecking = false }
            let stored = typed.isEmpty ? await Task.detached { AIKeychain.load(p) }.value : nil
            guard let key = typed.isEmpty ? stored : typed else { byoNote = L("API 키를 붙여 넣어 주세요."); return }
            do {
                let (list, busy) = try await BYOAPIClient(provider: p, key: key).check()
                if !typed.isEmpty { try AIKeychain.save(typed, for: p); byoKey = "" }
                if !list.isEmpty { byo.use(list, for: p) }   // busy: the key works, the model stays as it was
                byo.lastFailure = nil
                byoNote = busy ?? L("연결됐어요. \(byo.model(p)) 모델로 답해요.")
            } catch let e as ChatError {
                byoNote = e.message
            } catch {
                byoNote = L("키를 저장하지 못했어요. 다시 해 주세요.")
            }
        }
    }

    @ViewBuilder
    private func byoCLIRows(_ p: BYOProvider) -> some View {
        #if !MAS
        if let path = BYOCLIClient(provider: p).path() {
            HStack {
                Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(byoChecking ? L("확인 중…") : L("연결 확인")) {
                    byoChecking = true
                    byoNote = nil
                    Task { @MainActor in
                        let why = await Task.detached { BYOCLIClient(provider: p).check() }.value
                        byoNote = why ?? L("준비됐어요. 이 맥에 로그인된 \(p.label) 구독으로 답해요.")
                        if why == nil { byo.lastFailure = nil }
                        byoChecking = false
                    }
                }
                .controlSize(.small).disabled(byoChecking)
            }
            note(p == .claude ? L("이 맥의 \(p.cliName)에 로그인된 내 구독 계정으로 답해요. 추가 요금 없이 구독 사용 한도를 써요. 도구와 파일 접근은 모두 끈 채로 실행해요.")
                              : L("이 맥의 \(p.cliName)에 로그인된 내 구독 계정으로 답해요. 추가 요금 없이 구독 사용 한도를 써요. 빈 폴더에서 실행하지만 읽기 전용 도구는 켜져 있어서, 일정은 보내지 않아요."))
        } else {
            warn(L("이 맥에서 \(p.cliName) 프로그램을 찾지 못했어요. 설치하고 로그인하면 쓸 수 있어요. 아니면 API 키로 연결해 주세요."))
        }
        #endif
    }

    private var nudgePanel: some View {
        Panel {
            HStack {
                title(L("먼저 말 걸기"))
                Spacer()
                Picker("먼저 말 걸기", selection: $a.nudges) {
                    ForEach(NudgeFrequency.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize().controlSize(.small)
            }
            note(L("배터리 10%, 맥이 뜨거울 때, 오래 걸린 작업이 끝났을 때, CPU를 오래 쓰는 프로그램이 있을 때 말풍선으로 알려 줘요. 영상 회의 앱이 앞에 있으면 조용히 있어요."))
            Divider()
            switchRow(L("AI가 그때그때 대사 만들기"), $a.aiNudges)
            Divider()
            workHoursRows
            Divider()
            HStack {
                if a.isMuted() {
                    Text("\(a.mutedUntil!.formatted(date: .omitted, time: .shortened))까지 조용히 있어요").font(.system(size: 12))
                    Spacer()
                    Button("다시 말하기") { a.mutedUntil = nil }.controlSize(.small)
                } else {
                    Text("말풍선 잠시 끄기").font(.system(size: 12))
                    Spacer()
                    Button("1시간 조용히") { a.mutedUntil = Date().addingTimeInterval(3600); SpeechBubbleCenter.shared.dismiss() }.controlSize(.small)
                }
            }
        }
    }

    /// 대사 고치기: the user's own words for the template lines, each with 기본값 to go back.
    private var linesPanel: some View {
        Panel {
            DisclosureGroup(isExpanded: $showLines) {
                VStack(alignment: .leading, spacing: 8) {
                    note(L("고친 대사는 말풍선에 그대로 나와요. AI에게는 보내지 않아요."))
                    ForEach(LineOverrides.slots) { lineRow($0) }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 5) {
                    title(L("대사 고치기"))
                    if !a.lines.isEmpty { note(L("고친 대사 \(a.lines.count)개")) }
                }
            }
        }
    }

    private func lineRow(_ slot: LineOverrides.Slot) -> some View {
        let text = lineDrafts[slot.id] ?? a.lines[slot.id] ?? ""
        let unknown = LineOverrides.unknown(text, allowed: slot.vars)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(slot.label).font(.system(size: 12))
                Spacer()
                if a.lines[slot.id] != nil || !text.isEmpty {
                    Button(L("기본값")) { lineDrafts[slot.id] = nil; a.lines[slot.id] = nil }.controlSize(.small)
                }
            }
            TextField(slot.sample, text: Binding(get: { text }, set: { typed in
                lineDrafts[slot.id] = typed
                let line = Persona.oneLine(typed, max: LineOverrides.maxLength)
                if LineOverrides.unknown(line, allowed: slot.vars).isEmpty { a.lines[slot.id] = line.isEmpty ? nil : line }
            }))
            .textFieldStyle(.roundedBorder).font(.system(size: 11))
            if let x = unknown.first {
                warn(L("모르는 자리표시예요: {\(x)}"))
            } else if !slot.vars.isEmpty {
                note(L("\(slot.vars.map { "{\($0)}" }.joined(separator: " ")) 쓸 수 있어요"))
            }
        }
    }

    /// 출근·점심·퇴근 인사: a switch each with its time, and the workdays. Free (template lines).
    private var workHoursRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(WorkHours.Kind.allCases, id: \.self) { k in
                HStack {
                    Text(k.label).font(.system(size: 12))
                    Spacer()
                    if a.workHours.greet.contains(k) {
                        DatePicker(k.label, selection: timeBinding(k), displayedComponents: .hourAndMinute)
                            .labelsHidden().controlSize(.small).fixedSize()
                    }
                    Toggle(k.label, isOn: Binding(get: { a.workHours.greet.contains(k) },
                                                  set: { on in if on { a.workHours.greet.insert(k) } else { a.workHours.greet.remove(k) } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
            if !a.workHours.greet.isEmpty {
                HStack(spacing: 4) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { d in
                        Toggle(Calendar.current.veryShortWeekdaySymbols[d - 1], isOn: Binding(
                            get: { a.workHours.days.contains(d) },
                            set: { on in if on { a.workHours.days.insert(d) } else { a.workHours.days.remove(d) } }))
                            .toggleStyle(.button).controlSize(.mini)
                    }
                }
            }
            note(L("하루에 한 번씩만 말해요. 점심엔 냠냠 모션을 보여 주고, 공휴일엔 쉬어요. 먼저 말 걸기를 끄면 함께 꺼져요."))
        }
    }

    /// The time of a greeting as today's date: 출근 is the start, 점심 the lunch, 퇴근 the end of the day.
    private func timeBinding(_ k: WorkHours.Kind) -> Binding<Date> {
        let key: WritableKeyPath<WorkHours, Int> = k == .morning ? \.start : k == .lunch ? \.lunch : \.end
        return Binding(get: {
            let m = a.workHours[keyPath: key]
            return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            a.workHours[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }

    private var voicePanel: some View {
        Panel {
            switchRow(L("목소리로 읽어 주기"), $a.voice, bold: true)
            if a.voice && AssistantVoice.koreanVoice == nil {
                note(AssistantVoice.missingVoiceHelp).foregroundStyle(Color.warn)
            } else {
                note(L("답과 말풍선을 소리 내 읽어 줘요. 회의 중엔 꺼 두세요."))
            }
        }
    }

    private var integrationsPanel: some View {
        Panel {
            title(L("연동"))
            note(L("처음엔 모두 꺼져 있어요. 켠 것만 이 맥에서 확인해요."))
            if let why = a.integrationNotice {
                HStack(alignment: .firstTextBaseline) {
                    warn(why)
                    Spacer(minLength: 0)
                    Button("확인") { a.integrationNotice = nil }.controlSize(.small)
                }
            }
            Divider()
            switchRow(L("캘린더 일정 알림"), permissionBinding(\.calendar, type: .event, note: $calendarNote))
            if let calendarNote { warn(calendarNote) }
            if a.calendar {
                Picker("알림 시점", selection: $a.calendarLeads) {
                    ForEach(AssistantSettings.leadPresets, id: \.self) { Text(AssistantSettings.leadLabel($0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                note(L("시작할 때까지 말풍선이 떠 있고 캐릭터가 특별 모션을 보여 줘요. 취소·불참·한가함 일정은 건너뛰어요."))
            }
            switchRow(L("미리알림 시간 알림"), permissionBinding(\.reminders, type: .reminder, note: $remindersNote))
            if let remindersNote { warn(remindersNote) }
            #if !MAS
            Divider()
            switchRow(L("Apple Mail 새 메일 알림"), mailBinding)
            if let mailNote { warn(mailNote) }
            if a.mail { check(L("메일 제목도 말하기"), $inbox.mailSubject) }
            note(L("Mail이 켜져 있을 때만 1분마다 안 읽은 메일의 보낸 사람과 제목을 봐요. 켜는 순간 macOS가 허락을 한 번 물어요."))
            Divider()
            inboxRows
            #endif
            Divider()
            switchRow(L("아이폰으로 알림 보내기"), $a.phone)
            if a.phone { phoneOptions }
            Divider()
            shortcutRow
        }
    }

    private var mailPanel: some View {
        Panel {
            title(L("메일 계정"))
            AssistantMailAccountsView()
        }
    }

    #if !MAS
    /// 문자·알림 알려주기: both read a database macOS guards with 전체 디스크 접근.
    private var inboxRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            switchRow(L("문자 메시지 알려주기"), inboxBinding(\.messages))
            if inbox.messages {
                check(L("내용 미리보기 (30자)"), $inbox.messagesPreview)
                if !ContactNames.authorized && ContactNames.canAsk && !contactsAsked {
                    HStack {
                        note(L("보낸 사람을 번호 대신 연락처 이름으로 말해요."))
                        Spacer()
                        Button("연락처 이름으로 보기") { contactsAsked = true; Task { _ = await PermissionFlow.run(asks: ContactNames.wouldAsk) { await ContactNames.request() } } }.controlSize(.small)
                    }
                }
                note(L("아이폰 문자도 받으려면 아이폰 설정 > 메시지 > 문자 메시지 전달에서 이 맥을 켜 주세요."))
            }
            switchRow(L("다른 앱 알림 알려주기 (카톡·슬랙 등)"), inboxBinding(\.notifications))
            if inbox.notifications {
                check(L("제목과 내용 미리보기 (30자)"), $inbox.notificationsPreview)
                if !inboxCenter.topApps.isEmpty {
                    note(L("알려 줄 앱 (자주 알림을 보내는 순)"))
                    ForEach(inboxCenter.topApps, id: \.self) { id in
                        check(inboxCenter.appName(id), Binding(get: { !inbox.offApps.contains(id) },
                                                               set: { on in if on { inbox.offApps.remove(id) } else { inbox.offApps.insert(id) } }))
                    }
                }
            }
            if inbox.messages || inbox.notifications, let help = accessHelp {
                warn(help)
                Button("시스템 설정 열기") { InboxCenter.openFullDiskAccess() }.controlSize(.small)
            } else {   // the warning already says it: the same words twice read as a bug in the QA render
                note(L("'전체 디스크 접근' 허용이 필요해요. 내용은 이 맥 안에서 말풍선으로만 보여주고, 저장하거나 어디에도 보내지 않아요. macOS가 공개하지 않은 기록을 읽는 거라 OS 업데이트 뒤엔 잠시 안 될 수 있어요."))
            }
        }
        .onAppear { if inbox.messages || inbox.notifications { inboxCenter.refresh() } }
    }

    /// The worst of the two checks, in words (messages first: denied covers both).
    private var accessHelp: String? {
        let checks: [(InboxAccess?, Bool)] = [(inbox.messages ? inboxCenter.messagesAccess : nil, false),
                                             (inbox.notifications ? inboxCenter.notificationsAccess : nil, true)]
        let sorted = checks.compactMap { c in c.0.map { ($0, c.1) } }.sorted { ($0.0 == .denied ? 0 : 1) < ($1.0 == .denied ? 0 : 1) }
        return sorted.lazy.compactMap { InboxLine.accessHelp($0.0, hadAccess: inbox.hadAccess, notifications: $0.1) }.first
    }

    /// Turning on checks access right away, so what to do shows next to the switch.
    private func inboxBinding(_ key: ReferenceWritableKeyPath<InboxSettings, Bool>) -> Binding<Bool> {
        Binding(get: { inbox[keyPath: key] }, set: { on in
            a.integrationNotice = nil
            inbox[keyPath: key] = on
            if on { inboxCenter.refresh() }
        })
    }

    private func check(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn).toggleStyle(.checkbox).font(.system(size: 11)).padding(.leading, 4)
    }
    #endif

    private var phoneOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("서비스", selection: $a.phoneService) {
                ForEach(PhoneService.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            if a.phoneService == .ntfy {
                HStack(alignment: .top, spacing: 10) {
                    if let url = Phone.subscribeURL(a.ntfyTopic), let qr = Phone.qr(url.absoluteString, size: 84) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 84, height: 84)
                            .background(Color.white).accessibilityLabel("구독 주소 QR 코드")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        note(L("1. 아이폰에 ntfy 앱을 받아요.\n2. QR을 찍거나 아래 주소를 구독해요."))
                        Text(a.ntfyTopic).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        HStack(spacing: 6) {
                            Button("주소 복사") { copy(Phone.subscribeURL(a.ntfyTopic)?.absoluteString ?? "") }.controlSize(.small)
                            Button("새 주소") { a.ntfyTopic = Phone.newTopic() }.controlSize(.small)
                        }
                    }
                }
                note(L("주소를 아는 사람은 누구나 알림을 볼 수 있어요. 남에게 보여 주지 마세요."))
            } else {
                TextField("사용자 키 (User Key)", text: $a.pushoverUser).textFieldStyle(.roundedBorder).controlSize(.small)
                SecureField("앱 토큰 (API Token)", text: $a.pushoverToken).textFieldStyle(.roundedBorder).controlSize(.small)
                note(L("pushover.net에서 내 계정의 사용자 키와 직접 만든 앱 토큰을 넣어요."))
            }
            ForEach(PhoneEvent.allCases, id: \.self) { e in
                Toggle(e.label, isOn: Binding(get: { a.phoneEvents.contains(e) },
                                              set: { on in if on { a.phoneEvents.insert(e) } else { a.phoneEvents.remove(e) } }))
                    .toggleStyle(.checkbox).font(.system(size: 11))
            }
            HStack {
                Button(sending ? "보내는 중…" : "테스트 알림 보내기") {
                    sending = true
                    Task {
                        phoneNote = await Phone.send(title: L("캐릭모니터"), body: L("\(settings.characterName)의 테스트 알림이에요.")) ?? L("보냈어요. 아이폰을 확인해 주세요.")
                        sending = false
                    }
                }
                .controlSize(.small).disabled(sending)
                if let phoneNote { Text(phoneNote).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        .padding(.leading, 4)
    }

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            switchRow(L("단축어로 말 시키기"), $a.urlSay)
            if a.urlSay {
                HStack {
                    Text(L("charamonitor://say?text=안녕")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("주소 복사") { copy(L("charamonitor://say?text=안녕")) }.controlSize(.small)
                }
            }
            note(L("단축어의 'URL 열기'로 부르면 캐릭터가 말풍선에 '단축어:'를 붙여 보여 줘요 (200자, 30초에 한 번, 소리 없이). 웹 페이지도 이 주소를 열 수 있어서 처음엔 꺼져 있어요."))
        }
    }

    // MARK: Pieces

    private func title(_ t: String) -> some View { Text(t).font(.system(size: 12, weight: .semibold)) }

    private func note(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func warn(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(Color.warn).fixedSize(horizontal: false, vertical: true)
    }

    private func switchRow(_ label: String, _ isOn: Binding<Bool>, bold: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: bold ? .semibold : .regular))
            Spacer()
            Toggle(label, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }

    /// Turning on asks macOS first; refused, it stays off with what to do.
    private func permissionBinding(_ key: ReferenceWritableKeyPath<AssistantSettings, Bool>, type: EKEntityType,
                                   note: Binding<String?>) -> Binding<Bool> {
        Binding(get: { a[keyPath: key] }, set: { on in
            a.integrationNotice = nil
            guard on else { a[keyPath: key] = false; note.wrappedValue = nil; return }
            Task { @MainActor in
                let asks = EKEventStore.authorizationStatus(for: type) == .notDetermined && CalendarLink.canAsk(type)
                let why = await PermissionFlow.run(asks: asks) { await CalendarLink.shared.request(type) }
                note.wrappedValue = why
                a[keyPath: key] = why == nil
            }
        })
    }

    #if !MAS
    /// Turning Mail on asks macOS right away (one osascript run), so the 자동화 prompt follows the click instead of
    /// popping up minutes later. Refused: stays off with what to do.
    private var mailBinding: Binding<Bool> {
        Binding(get: { a.mail }, set: { on in
            mailNote = nil
            a.integrationNotice = nil
            guard on else { a.mail = false; return }
            a.mail = true
            Task { @MainActor in
                let asks = await Task.detached { MailLink.wouldAsk() }.value
                switch await PermissionFlow.run(asks: asks, { await MailLink.poll() }) {
                case .denied:
                    a.mail = false
                    mailNote = L("macOS가 Mail 제어를 막았어요. 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 캐릭모니터의 Mail을 켜 주세요.")
                case .unavailable:
                    mailNote = L("Mail이 열려 있지 않아요. Mail을 열면 처음 한 번 macOS가 허락을 물어요.")
                case .unread:
                    break
                }
            }
        })
    }
    #endif

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
