import Combine
import Foundation

/// Samples the system on a main run loop timer and publishes the results.
/// Every tick updates cpuUsage, memory, load and the three histories; the full snapshot is refreshed
/// on ticks while `detailed` is true and on every sampleNow() call.
final class SystemMonitor: ObservableObject {
    static let historyLength = 60

    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var cpuUsage: Double = 0
    // Always exactly historyLength long (zero filled at start) so charts never see a short array.
    @Published private(set) var cpuHistory = [Double](repeating: 0, count: historyLength)
    @Published private(set) var downHistory = [Double](repeating: 0, count: historyLength)
    @Published private(set) var upHistory = [Double](repeating: 0, count: historyLength)
    /// Latest memory, sampled every tick (cheap) because it drives the dog.
    @Published private(set) var memory: MemoryStats?
    @Published private(set) var loadCause = LoadCause.cpu
    /// How busy the Mac is, 0...1: the busiest of CPU, memory pressure and heat. Drives the dog's pose and speed.
    /// Published last in each tick, so subscribers can read cpuUsage, memory and loadCause already updated.
    @Published private(set) var load: Double = 0

    /// True while the dashboard is visible. Turning it on refreshes the snapshot right away.
    var detailed = false {
        didSet { if detailed && !oldValue && timer != nil { sampleNow() } }
    }

    private let interval: TimeInterval
    private var timer: Timer?
    private let cpu = CPUSampler()
    private let network: NetworkSampler
    private let disk = DiskSampler()
    private let battery = BatterySampler()

    init(interval: TimeInterval = 1.0) {
        self.interval = max(0.25, interval)
        network = NetworkSampler(maxGap: max(10, interval * 5))
    }

    deinit { timer?.invalidate() }

    func start() {
        onMain {
            guard self.timer == nil else { return }
            // Reseed after a pause so the first tick covers about one interval, not the whole pause.
            // Both samplers ignore calls within 250 ms of their last read, so a fresh start is unaffected.
            self.cpu.sample()
            self.network.update()
            let t = Timer(timeInterval: self.interval, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = self.interval * 0.1
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    func stop() {
        onMain {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    /// Takes a full sample now and publishes it. Does not push history points (those stay one per tick).
    @discardableResult
    func sampleNow() -> SystemSnapshot {
        guard Thread.isMainThread else { return DispatchQueue.main.sync { sampleNow() } }
        let c = cpu.sample()
        network.update()
        let snap = fullSnapshot(cpu: c)
        snapshot = snap
        cpuUsage = c.usage
        return snap
    }

    private func tick() {
        let c = cpu.sample()
        network.update()
        let mem = MemorySampler.sample()
        if detailed { snapshot = fullSnapshot(cpu: c, memory: mem) }
        memory = mem
        cpuUsage = c.usage
        cpuHistory = Self.push(cpuHistory, c.usage)
        downHistory = Self.push(downHistory, network.downloadBytesPerSec)
        upHistory = Self.push(upHistory, network.uploadBytesPerSec)
        let busy = Busyness.score(cpu: c.usage, memory: mem, thermal: ProcessInfo.processInfo.thermalState)
        loadCause = busy.cause
        load = busy.load
    }

    private func fullSnapshot(cpu c: CPUStats, memory mem: MemoryStats = MemorySampler.sample()) -> SystemSnapshot {
        let now = Date()
        return SystemSnapshot(timestamp: now, cpu: c, memory: mem,
                              disk: disk.sample(now: now), battery: battery.sample(now: now),
                              network: network.stats(), uptime: Sysctl.uptime(),
                              thermalState: ProcessInfo.processInfo.thermalState)
    }

    private static func push(_ history: [Double], _ value: Double) -> [Double] {
        var h = history
        h.removeFirst()
        h.append(value)
        return h
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
