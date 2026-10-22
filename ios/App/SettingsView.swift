import CharaCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SharedState.soundKey, store: Shared.defaults) private var sound = true
    @AppStorage(SharedState.hapticsKey, store: Shared.defaults) private var haptics = true
    @AppStorage(SharedState.widgetCharacterKey, store: Shared.defaults) private var widgetCharacter = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("누르면 소리", isOn: $sound)
                    Toggle("진동", isOn: $haptics)
                } header: {
                    Text("반응")
                } footer: {
                    Text("무음 모드일 때는 소리가 나지 않아요.")
                }
                .listRowBackground(Palette.card)
                Section {
                    Picker("위젯에 보일 친구", selection: $widgetCharacter) {
                        Text("앱과 같은 친구").tag("")
                        ForEach(model.characters) { Text(verbatim: $0.displayName).tag($0.id) }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("위젯")
                }
                .listRowBackground(Palette.card)
                Section {
                    LabeledContent("버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    VStack(alignment: .leading, spacing: 6) {
                        Label("개인정보", systemImage: "lock.fill").font(.headline)
                        Text("캐릭모니터는 어떤 정보도 아이폰 밖으로 보내지 않아요. 배터리와 저장 공간은 이 아이폰 안에서만 읽고, 가져온 설정 파일도 이 앱 안에만 보관해요. 설정 파일에서는 그림과 이름만 읽고, 그 안의 어떤 것도 실행하지 않아요.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("정보")
                }
                .listRowBackground(Palette.card)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg.ignoresSafeArea())
            .navigationTitle("설정")
            .onChange(of: widgetCharacter) { SharedState.changed() }
        }
    }
}
