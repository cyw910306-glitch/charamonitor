import AppKit
import SwiftUI

/// 비서 설정 > 메일 계정: Gmail·네이버 and other IMAP accounts for new-mail lines, without Apple Mail (both builds).
struct AssistantMailAccountsView: View {
    @ObservedObject private var mail = MailAccounts.shared
    @ObservedObject private var inbox = InboxSettings.shared
    @ObservedObject private var a = AssistantSettings.shared
    /// Kept in PopoverMemory: the popover closes while an app password is made in the browser.
    @State private var draft = PopoverMemory.shared.mailDraft
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var retry: [String: String] = [:]
    /// 삭제 asks first: it takes the app password out of the keychain too.
    @State private var removing: MailAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("새 메일 알림").font(.system(size: 12))
                Spacer()
                Button(draft.adding ? "닫기" : "계정 추가") { draft.adding.toggle(); error = nil }.controlSize(.small)
            }
            ForEach(mail.accounts) { row($0) }
            if draft.adding { form }
            #if MAS
            if !mail.accounts.isEmpty { check(L("메일 제목도 말하기"), $inbox.mailSubject) }
            #else
            if !mail.accounts.isEmpty && !a.mail { check(L("메일 제목도 말하기"), $inbox.mailSubject) }   // else under Apple Mail
            #endif
            note(L("Gmail·네이버·다음·iCloud 메일을 Apple Mail 없이 2분마다 확인해서 보낸 사람과 제목만 말해 줘요. 메일을 읽음으로 바꾸지 않고, 앱 비밀번호는 이 맥의 키체인에만 저장해요."))
        }
        .onChange(of: draft) { PopoverMemory.shared.mailDraft = $0 }
        .confirmationDialog(removing.map { L("\($0.user) 계정을 뺄까요?") } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { acc in
            Button("빼기", role: .destructive) { mail.remove(acc.id); retry[acc.id] = nil }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("이 맥 키체인에 저장한 앱 비밀번호도 함께 지워요.")
        }
    }

    private func row(_ acc: MailAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(mail.label(acc)).font(.system(size: 12))
                    Text(acc.user).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("삭제") { removing = acc }.controlSize(.small)
                Toggle(mail.label(acc), isOn: Binding(get: { acc.on }, set: { mail.setOn(acc.id, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if acc.on {
                switch mail.status[acc.id] {
                case .ok(let d): note(L("확인함 \(d.formatted(date: .omitted, time: .shortened))"))
                case .checking: note(L("확인하는 중…"))
                case .network(let why): warn(why)
                case .login(let why):
                    warn(why)
                    HStack(spacing: 6) {
                        SecureField("새 앱 비밀번호", text: Binding(get: { retry[acc.id] ?? "" }, set: { retry[acc.id] = $0 }))
                            .textFieldStyle(.roundedBorder).controlSize(.small)
                        Button("다시 연결") {
                            let pw = retry[acc.id] ?? ""
                            Task { if await mail.retry(acc.id, password: pw) == nil { retry[acc.id] = nil } }
                        }
                        .controlSize(.small).disabled((retry[acc.id] ?? "").isEmpty)
                        openButton(acc.preset)
                    }
                case nil: note(L("곧 처음 확인해요. 이미 와 있던 메일은 말하지 않아요."))
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("메일", selection: $draft.preset) {
                ForEach(MailPreset.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().controlSize(.small)
            .onChange(of: draft.preset) { _ in error = nil }
            note(draft.preset.help)
            HStack { openButton(draft.preset); Spacer() }
            TextField(draft.preset == .naver ? "네이버 ID 또는 주소" : "메일 주소", text: $draft.user)
                .textFieldStyle(.roundedBorder).controlSize(.small)
            SecureField("앱 비밀번호", text: $password).textFieldStyle(.roundedBorder).controlSize(.small)
            if draft.preset == .custom {
                HStack(spacing: 6) {
                    TextField("IMAP 서버 (imap.example.com)", text: $draft.host).textFieldStyle(.roundedBorder).controlSize(.small)
                    TextField("포트", text: $draft.port).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 56)
                }
            }
            if let error { warn(error) }
            HStack {
                Spacer()
                Button(busy ? "연결하는 중…" : "연결하고 추가") {
                    busy = true
                    error = nil
                    Task {
                        let d = draft
                        error = await mail.add(preset: d.preset, user: d.user, password: password,
                                               host: d.preset == .custom ? d.host : nil, port: Int(d.port) ?? 0)
                        busy = false
                        if error == nil { draft = PopoverMemory.MailDraft(); password = "" }
                    }
                }
                .controlSize(.small).disabled(busy || draft.user.isEmpty || password.isEmpty)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private func openButton(_ p: MailPreset) -> some View {
        if let url = p.passwordURL { Button("발급 페이지 열기") { PermissionFlow.openSettings(url, anchor: PopoverMemory.mail) }.controlSize(.small) }
    }

    private func check(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn).toggleStyle(.checkbox).font(.system(size: 11)).padding(.leading, 4)
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func warn(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(Color.warn).fixedSize(horizontal: false, vertical: true)
    }
}
