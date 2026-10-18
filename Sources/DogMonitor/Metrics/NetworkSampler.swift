import Darwin
import Foundation
import SystemConfiguration

/// Per-interface byte rates from 64-bit counters (link MIB if_data64).
final class NetworkSampler {
    private struct Iface { var name: String; var rx: UInt64; var tx: UInt64; var down: Double; var up: Double }

    /// Virtual interfaces whose traffic is either tunneled over a physical one (would double count) or noise.
    private static let skipped = ["lo", "gif", "stf", "utun", "awdl", "llw", "anpi", "ap", "bridge", "vmenet", "ipsec", "ppp"]

    private var ifaces: [Iface] = []
    private var prevTime: UInt64 = 0
    private var data = ifmibdata()
    private var displayNames: [String: String] = [:]
    private var displayNamesAt: UInt64 = 0
    private let maxGap: Double

    private(set) var downloadBytesPerSec = 0.0
    private(set) var uploadBytesPerSec = 0.0

    /// maxGap: a longer span between samples (sleep, stalled timer) reports 0 instead of a burst.
    init(maxGap: TimeInterval = 10) {
        self.maxGap = maxGap
        update()
        refreshDisplayNamesIfNeeded(for: ifaces)   // pay the SystemConfiguration cost once, up front
    }

    /// Reads counters and recomputes rates. Cheap enough for every tick.
    func update() {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)   // includes sleep time
        let elapsed = Double(now &- prevTime) / 1e9
        if prevTime != 0, elapsed < 0.25 { return }       // too short to be meaningful, keep last rates
        guard let fresh = readCounters() else { return }

        let valid = prevTime != 0 && elapsed <= maxGap
        var down = 0.0, up = 0.0
        var next: [Iface] = []
        next.reserveCapacity(fresh.count)
        for var f in fresh {
            if valid, let old = ifaces.first(where: { $0.name == f.name }) {
                // Counter went backwards (reset, interface re-created): treat as no traffic.
                f.down = f.rx >= old.rx ? Double(f.rx - old.rx) / elapsed : 0
                f.up = f.tx >= old.tx ? Double(f.tx - old.tx) / elapsed : 0
            }
            down += f.down; up += f.up
            next.append(f)
        }
        ifaces = next
        prevTime = now
        downloadBytesPerSec = down
        uploadBytesPerSec = up
    }

    /// Full interface list from the last update, with IPv4 and user facing names. Primary interface first.
    func stats() -> NetworkStats {
        let ipv4 = Self.ipv4Addresses()
        let primary = primaryInterface()
        let shown = ifaces.filter { ipv4[$0.name] != nil || $0.rx > 0 || $0.tx > 0 }
        refreshDisplayNamesIfNeeded(for: shown)
        let list = shown
            .map { f in
                NetworkInterfaceStats(bsdName: f.name, displayName: displayNames[f.name] ?? f.name, ipv4: ipv4[f.name],
                                      uploadBytesPerSec: f.up, downloadBytesPerSec: f.down,
                                      totalSent: f.tx, totalReceived: f.rx)
            }
            .sorted { a, b in
                if a.bsdName == primary || b.bsdName == primary { return a.bsdName == primary }
                let ta = a.uploadBytesPerSec + a.downloadBytesPerSec, tb = b.uploadBytesPerSec + b.downloadBytesPerSec
                return ta != tb ? ta > tb : a.bsdName < b.bsdName
            }
        return NetworkStats(interfaces: list, uploadBytesPerSec: uploadBytesPerSec, downloadBytesPerSec: downloadBytesPerSec)
    }

    private lazy var store = SCDynamicStoreCreate(nil, "DogMonitor" as CFString, nil, nil)

    /// BSD name of the interface carrying the default route ("en0"), listed first in stats().
    private func primaryInterface() -> String? {
        guard let store,
              let v = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return v["PrimaryInterface"] as? String
    }

    /// 64-bit counters per interface from the link MIB (net.link.generic.ifdata.<index>.general).
    /// NET_RT_IFLIST2 would be the classic source, but on macOS 26 it reports byte counters
    /// truncated to 32 bits (wraps every 4 GB), so netstat -ib and this sampler use the MIB instead.
    private func readCounters() -> [Iface]? {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var countMib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        guard sysctl(&countMib, 5, &count, &size, nil, 0) == 0, count > 0 else { return nil }

        var out: [Iface] = []
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, 0, IFDATA_GENERAL]
        for index in 1...count {   // indexes can have gaps: missing ones fail and are skipped
            mib[4] = index
            size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, 6, &data, &size, nil, 0) == 0,
                  data.ifmd_flags & UInt32(IFF_UP) != 0, data.ifmd_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = withUnsafeBytes(of: data.ifmd_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if Self.skipped.contains(where: { name.hasPrefix($0) }) { continue }
            out.append(Iface(name: name, rx: data.ifmd_data.ifi_ibytes, tx: data.ifmd_data.ifi_obytes, down: 0, up: 0))
        }
        return out
    }

    /// SCNetworkInterfaceCopyAll costs about 2 ms, so it runs once and then only for new names, at most every 30 s.
    private func refreshDisplayNamesIfNeeded(for shown: [Iface]) {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        let missing = shown.contains { displayNames[$0.name] == nil }
        guard displayNamesAt == 0 || (missing && now &- displayNamesAt > 30_000_000_000) else { return }
        displayNamesAt = now
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        for i in all {
            if let bsd = SCNetworkInterfaceGetBSDName(i) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? {
                displayNames[bsd] = name
            }
        }
    }

    private static func ipv4Addresses() -> [String: String] {
        var result: [String: String] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return result }
        defer { freeifaddrs(head) }
        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: a.pointee.ifa_name)
            guard result[name] == nil else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if inet_ntop(AF_INET, &addr, &host, socklen_t(INET_ADDRSTRLEN)) != nil {
                result[name] = String(cString: host)
            }
        }
        return result
    }
}
