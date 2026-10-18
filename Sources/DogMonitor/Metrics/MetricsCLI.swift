import Foundation

/// `--metrics-dump`: one full sample taken 1 s after a baseline, printed in human units.
enum MetricsCLI {
    static func run() {
        let monitor = SystemMonitor()           // samplers seed their baselines here
        Thread.sleep(forTimeInterval: 1)
        let start = DispatchTime.now().uptimeNanoseconds
        let s = monitor.sampleNow()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        Thread.sleep(forTimeInterval: 0.3)
        let warmStart = DispatchTime.now().uptimeNanoseconds
        monitor.sampleNow()
        let warmMs = Double(DispatchTime.now().uptimeNanoseconds - warmStart) / 1e6

        print("캐릭모니터 · metrics dump  \(s.timestamp)")
        print("")
        print("CPU      사용 \(pct(s.cpu.usage))  user \(pct(s.cpu.user))  system \(pct(s.cpu.system))  idle \(pct(s.cpu.idle))")
        print("         코어 \(s.cpu.perCore.count)개: " + s.cpu.perCore.map { String(format: "%.0f", $0 * 100) }.joined(separator: " "))
        print("         자세 \(DogPose.forCPU(s.cpu.usage)) (\(DogPose.forCPU(s.cpu.usage).label))")

        let m = s.memory
        print("메모리   전체 \(bytes(m.total))  사용 \(bytes(m.used))  압력 \(pct(m.pressure)) (\(m.pressureLevel.rawValue))")
        print("         앱 \(bytes(m.app))  wired \(bytes(m.wired))  압축 \(bytes(m.compressed))  캐시 \(bytes(m.cachedFiles))  여유 \(bytes(m.free))  스왑 \(bytes(m.swapUsed))")

        if let d = s.disk {
            print("저장공간 \(d.volumeName): 전체 \(Fmt.disk(d.total))  사용 \(Fmt.disk(d.used))  남음 \(Fmt.disk(d.available))")
        } else {
            print("저장공간 읽기 실패")
        }

        if let b = s.battery {
            let state = b.isCharged ? "충전 완료" : b.isCharging ? "충전 중" : b.isPluggedIn ? "전원 연결" : "배터리 사용"
            let remain = b.minutesRemaining.map { "\($0 / 60):" + String(format: "%02d", $0 % 60) } ?? "계산 중"
            print("배터리   \(b.percent)%  \(state)  남은 시간 \(remain)  사이클 \(b.cycleCount.map(String.init) ?? "-")  성능 \(b.healthPercent.map { "\($0)%" } ?? "-")")
            print("         정밀 잔량 \(num(b.levelPrecise, "%.1f%%"))  성능 최대치 \(num(b.healthPrecise, "%.1f%%"))  온도 \(num(b.temperatureCelsius, "%.1f°C"))")
        } else {
            print("배터리   없음")
        }

        let n = s.network
        print("네트워크 합계 ↓ \(rate(n.downloadBytesPerSec))  ↑ \(rate(n.uploadBytesPerSec))")
        for i in n.interfaces {
            print("         \(i.bsdName) (\(i.displayName)) \(i.ipv4 ?? "IPv4 없음")  ↓ \(rate(i.downloadBytesPerSec))  ↑ \(rate(i.uploadBytesPerSec))  누적 ↓ \(i.totalReceived) B  ↑ \(i.totalSent) B")
        }

        let up = Int(s.uptime)
        print("가동     \(up / 86400)일 \(up % 86400 / 3600)시간 \(up % 3600 / 60)분  열 상태 \(thermal(s.thermalState))")
        print(String(format: "샘플 비용 %.3f ms (첫 샘플), %.3f ms (다음 샘플)", ms, warmMs))
    }

    private static func num(_ v: Double?, _ format: String) -> String { v.map { String(format: format, $0) } ?? "-" }

    private static func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

    private static func bytes(_ v: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: v), countStyle: .memory)
    }

    private static func rate(_ v: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) + "/s"
    }

    private static func thermal(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "정상"
        case .fair: return "따뜻함"
        case .serious: return "뜨거움"
        case .critical: return "위험"
        @unknown default: return "알 수 없음"
        }
    }
}
