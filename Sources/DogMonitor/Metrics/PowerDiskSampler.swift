import Foundation
import IOKit
import IOKit.ps

/// Startup volume capacity, refreshed at most every 30 s.
/// The "important usage" figure takes 7 to 25 ms to compute, so it is read on a background queue
/// and the caller always gets the cached value (nil only until the first read lands).
final class DiskSampler {
    private let lock = NSLock()
    private var cached: DiskStats?
    private var readAt = Date.distantPast
    private var reading = false

    init() { sample() }   // kick off the first read early

    @discardableResult
    func sample(now: Date = Date()) -> DiskStats? {
        lock.lock(); defer { lock.unlock() }
        let age = now.timeIntervalSince(readAt)
        if !reading, age < 0 || age >= 30 {   // negative: the clock was set back
            reading = true
            DispatchQueue.global(qos: .utility).async { self.read() }
        }
        return cached
    }

    private func read() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey, .volumeNameKey]
        var stats: DiskStats?
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys), let total = v.volumeTotalCapacity {
            let important = v.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
            let available = important.flatMap { $0 > 0 ? $0 : nil } ?? UInt64(max(0, v.volumeAvailableCapacity ?? 0))
            stats = DiskStats(volumeName: v.volumeName ?? "Macintosh HD", total: UInt64(total), available: available)
        }
        lock.lock(); defer { lock.unlock() }
        if let stats { cached = stats }
        readAt = Date()
        reading = false
    }
}

/// Internal battery via IOPowerSources, cycle count and health via AppleSmartBattery. Cached for 10 s.
final class BatterySampler {
    private var cached: BatteryStats?
    private var readAt = Date.distantPast

    func sample(now: Date = Date()) -> BatteryStats? {
        let age = now.timeIntervalSince(readAt)
        if age >= 0 && age < 10 { return cached }   // negative: the clock was set back
        readAt = now
        cached = Self.read()
        return cached
    }

    private static func read() -> BatteryStats? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  d[kIOPSIsPresentKey] as? Bool ?? true else { continue }

            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCap = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int ?? -1
            let smart = smartBattery()
            return BatteryStats(
                percent: maxCap > 0 ? min(100, max(0, Int((Double(current) * 100 / Double(maxCap)).rounded()))) : 0,
                isCharging: charging,
                isPluggedIn: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isCharged: d[kIOPSIsChargedKey] as? Bool ?? false,
                minutesRemaining: minutes > 0 ? minutes : nil,   // -1 and 0 mean still calculating
                cycleCount: smart.cycles,
                healthPercent: smart.health.map { Int($0.rounded()) },
                levelPrecise: smart.level ?? (maxCap > 0 ? min(100, Double(current) * 100 / Double(maxCap)) : nil),
                healthPrecise: smart.health,
                temperatureCelsius: smart.celsius)
        }
        return nil
    }

    /// Precise level, health and temperature from the gauge. Level uses raw mAh (like RunCat), so it can differ
    /// from the smoothed menu bar percent. Health matches System Information "Maximum Capacity".
    private static func smartBattery() -> (cycles: Int?, health: Double?, level: Double?, celsius: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil, nil, nil) }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        func ratio(_ a: Int?, _ b: Int?) -> Double? {
            guard let a, let b, b > 0 else { return nil }
            return min(100, Double(a) * 100 / Double(b))
        }
        // Apple Silicon: NominalChargeCapacity is mAh. Intel: AppleRawMaxCapacity is mAh (MaxCapacity may be %).
        let rawMax = int("AppleRawMaxCapacity")
        let health = ratio(int("NominalChargeCapacity") ?? rawMax, int("DesignCapacity"))
        let level = ratio(int("AppleRawCurrentCapacity"), rawMax)
        let celsius = int("Temperature").map { Double($0) / 100 }   // centi-degrees
        return (int("CycleCount"), health, level, celsius)
    }
}
