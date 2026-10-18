import Darwin
import Foundation

/// Activity Monitor style memory breakdown.
enum MemorySampler {
    static func sample() -> MemoryStats {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory   // hw.memsize

        let anon = UInt64(vm.internal_page_count), purgeable = UInt64(vm.purgeable_count)
        let level = Double(Sysctl.int32("kern.memorystatus_level") ?? 100)
        var swap = xsw_usage()
        _ = Sysctl.read("vm.swapusage", into: &swap)

        let pressureLevel: MemoryPressureLevel
        switch Sysctl.int32("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: pressureLevel = .critical
        case 2: pressureLevel = .warning
        default: pressureLevel = .normal
        }

        guard kr == KERN_SUCCESS else {
            return MemoryStats(total: total, app: 0, wired: 0, compressed: 0, cachedFiles: 0, free: 0,
                               swapUsed: swap.xsu_used, pressure: 0, pressureLevel: pressureLevel)
        }
        return MemoryStats(
            total: total,
            app: (anon > purgeable ? anon - purgeable : 0) * page,
            wired: UInt64(vm.wire_count) * page,
            compressed: UInt64(vm.compressor_page_count) * page,
            cachedFiles: (UInt64(vm.external_page_count) + purgeable) * page,
            // free_count includes speculative pages, which external_page_count already covers (vm_stat does the same split).
            free: UInt64(vm.free_count > vm.speculative_count ? vm.free_count - vm.speculative_count : 0) * page,
            swapUsed: swap.xsu_used,
            pressure: min(1, max(0, 1 - level / 100)),
            pressureLevel: pressureLevel)
    }
}

/// Tiny sysctlbyname helpers.
enum Sysctl {
    @discardableResult
    static func read<T>(_ name: String, into value: inout T) -> Bool {
        withUnsafeMutableBytes(of: &value) { buf in
            var size = buf.count
            return sysctlbyname(name, buf.baseAddress, &size, nil, 0) == 0
        }
    }

    static func int32(_ name: String) -> Int32? {
        var v: Int32 = 0
        return read(name, into: &v) ? v : nil
    }

    static func uptime() -> TimeInterval {
        var boot = timeval()
        guard read("kern.boottime", into: &boot) else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
    }
}
