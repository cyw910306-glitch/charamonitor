#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import SwiftUI

/// The 설정 page card: 자동 업데이트 switch, the new version's notes with 지금 업데이트, and progress or the last result.
struct UpdateCard: View {
    @ObservedObject var updater: Updater = .shared

    var body: some View {
        Panel {
            HStack {
                Text("자동 업데이트").font(.system(size: 12))
                Spacer()
                Toggle("자동 업데이트", isOn: $updater.autoUpdate).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            if let m = updater.available {
                Divider()
                Text("새 버전 \(m.version) 나왔어요").font(.system(size: 12, weight: .medium))
                Text(m.notes).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("지금 업데이트") { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.busy)
            }
            Divider()
            HStack(spacing: 6) {
                Text(updater.status ?? L("지금 버전 \(AppInfo.version)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if updater.busy { ProgressView().controlSize(.small).accessibilityLabel("업데이트 진행 중") }
                Button("업데이트 확인") { updater.check(manual: true) }.disabled(updater.busy)
            }
        }
        .controlSize(.small)
    }
}
#endif
