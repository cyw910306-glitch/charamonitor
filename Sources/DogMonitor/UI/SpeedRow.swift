import SwiftUI

/// "인터넷 속도" lines in the network section. Measures only when the button is pressed.
struct SpeedRow: View {
    @ObservedObject var speed = SpeedTest.shared

    var body: some View {
        if speed.isRunning {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("인터넷 속도 재는 중… (약 15초)")
            }
        } else if let r = speed.last {
            Text("인터넷 속도: ↓ \(Self.number(r.downMbps)) · ↑ \(Self.number(r.upMbps)) Mbps")
                .accessibilityLabel("인터넷 속도 다운로드 \(Self.mbps(r.downMbps)), 업로드 \(Self.mbps(r.upMbps))")
            HStack(spacing: 6) {
                Text(speed.failed ? "측정 실패, 연결을 확인해 주세요" : "\(Self.age(r.date)) 측정")
                    .foregroundStyle(speed.failed ? AnyShapeStyle(Color.warn) : AnyShapeStyle(.tertiary))
                measureButton(L("다시 재기"))
            }
            .font(.system(size: 11))
        } else {
            HStack(spacing: 6) {
                if speed.failed { Text("측정 실패").foregroundStyle(Color.warn) }
                measureButton(L("인터넷 속도 재기"), symbol: "speedometer")
            }
        }
    }

    private func measureButton(_ title: String, symbol: String? = nil) -> some View {
        Button { speed.run() } label: {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)   // the section text is grey; keep the button visibly clickable
            .help(SpeedTest.helpText)
    }

    static func number(_ v: Double) -> String { v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v) }
    static func mbps(_ v: Double) -> String { number(v) + " Mbps" }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = appLocale
        f.unitsStyle = .short
        return f
    }()

    static func age(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? L("방금") : relative.localizedString(for: date, relativeTo: Date())
    }
}
