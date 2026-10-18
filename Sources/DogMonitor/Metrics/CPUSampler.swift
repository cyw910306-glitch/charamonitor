import Darwin

/// Tick deltas from host_processor_info between two calls.
final class CPUSampler {
    private var prev: [UInt32] = []   // CPU_STATE_MAX ticks per core, flattened
    private var prevTime: UInt64 = 0
    private(set) var last = CPUStats(user: 0, system: 0, idle: 1, perCore: [])

    init() {   // seed the baseline so the first tick has a delta
        prev = read() ?? []
        prevTime = clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    /// Reads current ticks, returns stats for the span since the previous call.
    @discardableResult
    func sample() -> CPUStats {
        // A second call right after a tick would measure a few ms of noise: keep the last value.
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        guard now &- prevTime >= 250_000_000, let cur = read() else { return last }
        defer { prev = cur; prevTime = now }
        guard cur.count == prev.count else { return last }

        let stride = Int(CPU_STATE_MAX)
        let cores = cur.count / stride
        var perCore = [Double](repeating: 0, count: cores)
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0
        for c in 0..<cores {
            let b = c * stride
            // natural_t counters wrap; wrapping subtraction keeps deltas right.
            let u = UInt64(cur[b + Int(CPU_STATE_USER)] &- prev[b + Int(CPU_STATE_USER)])
                + UInt64(cur[b + Int(CPU_STATE_NICE)] &- prev[b + Int(CPU_STATE_NICE)])
            let s = UInt64(cur[b + Int(CPU_STATE_SYSTEM)] &- prev[b + Int(CPU_STATE_SYSTEM)])
            let i = UInt64(cur[b + Int(CPU_STATE_IDLE)] &- prev[b + Int(CPU_STATE_IDLE)])
            let t = u + s + i
            perCore[c] = t > 0 ? Double(u + s) / Double(t) : 0
            user += u; system += s; idle += i
        }
        let total = Double(user + system + idle)
        guard total > 0 else { return last }   // called twice within one tick
        last = CPUStats(user: Double(user) / total, system: Double(system) / total,
                        idle: Double(idle) / total, perCore: perCore)
        return last
    }

    private func read() -> [UInt32]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
    }
}
