import Foundation

/// The current numbers as plain Korean lines, for the AI 비서 prompt and the number chips under an answer.
/// The app puts the facts in; the model only explains them (it is never asked to measure anything).
enum SystemSnapshotText {
    /// Processes under this share of one core are not "busy".
    static let busyFloor = 0.1

    /// The busiest apps right now, from RunawayTracker's 30 s CPU history (this user's processes). Helpers of an
    /// app count as the app ("Safari" for its web content), so one app is named once. nil when not measured (the App
    /// Store build, or before two samples exist), so "none is busy" is never said from no data.
    static func busyApps() -> [String]? {
        #if MAS   // no per-process CPU in the sandbox (RunawayTracker stays empty there)
        return nil
        #else
        let t = RunawayTracker.shared
        let entries = t.histories.compactMap { key, h -> (name: String, path: String?, cpu: Double)? in
            guard let avg = h.average, let row = t.rows[key.pid] else { return nil }
            return (row.name, Cleaner.path(of: key.pid), avg)
        }
        return entries.isEmpty ? nil : topNames(entries)
        #endif
    }

    /// Pure part of busyApps: app bundle name when the path is inside one, summed per name, busiest first, 3 at most.
    static func topNames(_ entries: [(name: String, path: String?, cpu: Double)]) -> [String] {
        var sum: [String: Double] = [:]
        for e in entries {
            var name = e.name
            if let path = e.path, let app = path.components(separatedBy: "/").first(where: { $0.hasSuffix(".app") }) {
                name = String(app.dropLast(4))
            }
            sum[name, default: 0] += e.cpu
        }
        return sum.filter { $0.value >= busyFloor }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key)
    }

    /// One "이름: 값" line per stat. `busyApps` = the busiest app names, most first (at most 3 are used); [] = measured
    /// and none is busy ("바쁜 앱: 없음"), nil = not measured (no line).
    static func lines(_ s: SystemSnapshot, busyApps: [String]? = nil) -> [String] {
        let usedMemory = s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : 0
        var out = ["CPU: \(Fmt.percent1(s.cpu.usage))",
                   "메모리: \(Fmt.percent1(min(1, usedMemory))) (\(Fmt.mem(s.memory.used)) / \(Fmt.mem(s.memory.total)), 압력 \(pressure(s.memory.pressureLevel)))"]
        if let d = s.disk { out.append("저장 공간: \(Fmt.disk(d.available)) 남음 (전체 \(Fmt.disk(d.total)))") }
        if let b = s.battery {
            out.append("배터리: \(b.percent)%" + (b.isCharging ? " (충전 중)" : b.isPluggedIn ? " (전원 연결)" : ""))
        }
        out.append("발열: \(heat(s.thermalState))")
        out.append("네트워크: 다운로드 \(Fmt.rate(s.network.downloadBytesPerSec)), 업로드 \(Fmt.rate(s.network.uploadBytesPerSec))")
        out.append("켜진 지: \(Fmt.uptime(s.uptime))")
        if let busyApps { out.append("바쁜 앱: " + (busyApps.isEmpty ? "없음" : busyApps.prefix(3).joined(separator: ", "))) }
        return out
    }

    /// The app's own reading of the numbers, so a small model explains instead of judging (measured: left alone,
    /// it called 19 % CPU and 66 % memory the reason the Mac is slow). Slow reasons come first.
    static func verdicts(_ s: SystemSnapshot) -> [String] {
        var slow: [String] = [], fine: [String] = []
        let cpu = s.cpu.usage
        if cpu >= 0.7 { slow.append("CPU가 많이 바쁨, 느린 이유일 수 있음") }
        else if cpu >= 0.3 { fine.append("CPU는 조금 바쁘지만 괜찮음") }
        else { fine.append("CPU 여유 있음") }
        switch s.memory.pressureLevel {
        case .critical: slow.append("메모리가 아주 부족함, 느린 가장 큰 이유")
        case .warning: slow.append("메모리가 부족해지는 중, 느린 이유일 수 있음")
        case .normal: fine.append("메모리 넉넉함")
        }
        if let d = s.disk, d.total > 0 {
            let free = Double(d.available) / Double(d.total)
            if free < 0.1 { slow.append("저장 공간이 거의 참, 정리 필요") } else { fine.append("저장 공간 넉넉함") }
        }
        if s.thermalState == .serious || s.thermalState == .critical { slow.append("맥이 뜨거워서 스스로 속도를 낮추는 중") }
        if let b = s.battery, b.percent <= 20, !b.isCharging { slow.append("배터리 부족, 충전 필요") }
        if s.uptime > 7 * 86_400 { fine.append("오래 켜 둠, 재시동하면 나아질 수 있음") }
        if slow.isEmpty { slow.append("지금 숫자로는 느릴 뚜렷한 이유 없음") }
        return slow + fine
    }

    static func describe(_ s: SystemSnapshot, busyApps: [String]? = nil) -> String {
        lines(s, busyApps: busyApps).joined(separator: "\n")
    }

    private static func pressure(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: return "보통"
        case .warning: return "높음"
        case .critical: return "매우 높음"
        }
    }

    private static func heat(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "보통"
        case .fair: return "조금 따뜻함"
        case .serious: return "뜨거움"
        case .critical: return "아주 뜨거움"
        @unknown default: return "알 수 없음"
        }
    }
}
