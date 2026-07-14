//
//  SystemStats.swift
//  RebesCore
//
//  User-space system meters (no root): CPU load, memory pressure,
//  disk free space, network throughput. Used by the menu bar panel
//  and the dashboard.
//

import Foundation
import Darwin

public struct SystemSnapshot: Sendable {
    public var cpuUsagePercent: Double = 0
    public var memUsedBytes: UInt64 = 0
    public var memTotalBytes: UInt64 = 0
    public var diskFreeBytes: Int64 = 0
    public var diskTotalBytes: Int64 = 0
    public var netDownBytesPerSec: Double = 0
    public var netUpBytesPerSec: Double = 0

    public init() {}

    public var memUsedPercent: Double {
        memTotalBytes > 0 ? Double(memUsedBytes) / Double(memTotalBytes) * 100 : 0
    }
    public var diskUsedPercent: Double {
        diskTotalBytes > 0 ? Double(diskTotalBytes - diskFreeBytes) / Double(diskTotalBytes) * 100 : 0
    }
}

public final class SystemStats: @unchecked Sendable {
    public static let shared = SystemStats()
    private let lock = NSLock()

    private var prevCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var prevNetBytes: (rx: UInt64, tx: UInt64, at: Date)?

    private init() {}

    /// Take a fresh snapshot. CPU and network values are deltas since the
    /// previous call, so call this on a fixed interval for smooth readings.
    public func sample() -> SystemSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var snap = SystemSnapshot()
        snap.cpuUsagePercent = sampleCPU()
        sampleMemory(&snap)
        sampleDisk(&snap)
        sampleNetwork(&snap)
        return snap
    }

    private func sampleCPU() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)

        defer { prevCPUTicks = (user, system, idle, nice) }
        guard let prev = prevCPUTicks else { return 0 }

        // Ticks are 32-bit and can wrap; a negative delta means wrap/reset —
        // skip this sample rather than report a garbage spike.
        guard user >= prev.user, system >= prev.system, idle >= prev.idle, nice >= prev.nice else { return 0 }
        let dUser = user - prev.user
        let dSystem = system - prev.system
        let dIdle = idle - prev.idle
        let dNice = nice - prev.nice
        let total = dUser + dSystem + dIdle + dNice
        guard total > 0 else { return 0 }
        return Double(dUser + dSystem + dNice) / Double(total) * 100
    }

    private func sampleMemory(_ snap: inout SystemSnapshot) {
        snap.memTotalBytes = ProcessInfo.processInfo.physicalMemory

        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return }

        var pageSizeOut: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSizeOut)
        let pageSize = UInt64(pageSizeOut > 0 ? pageSizeOut : 16384)
        // "Used" the way Activity Monitor counts it: active + wired + compressed.
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        snap.memUsedBytes = used
    }

    private func sampleDisk(_ snap: inout SystemSnapshot) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            snap.diskFreeBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
            snap.diskTotalBytes = Int64(values.volumeTotalCapacity ?? 0)
        }
    }

    private func sampleNetwork(_ snap: inout SystemSnapshot) {
        var rx: UInt64 = 0
        var tx: UInt64 = 0

        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return }
        defer { freeifaddrs(addrs) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            // Skip loopback and virtual interfaces.
            if name.hasPrefix("lo") || name.hasPrefix("utun") || name.hasPrefix("awdl") { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            rx &+= UInt64(data.ifi_ibytes)
            tx &+= UInt64(data.ifi_obytes)
        }

        let now = Date()
        defer { prevNetBytes = (rx, tx, now) }
        guard let prev = prevNetBytes else { return }
        let dt = now.timeIntervalSince(prev.at)
        guard dt > 0.1 else { return }
        // 32-bit interface counters wrap, and interfaces can appear/disappear;
        // a smaller current total means wrap/reset — report 0 for that sample.
        if rx >= prev.rx { snap.netDownBytesPerSec = Double(rx - prev.rx) / dt }
        if tx >= prev.tx { snap.netUpBytesPerSec = Double(tx - prev.tx) / dt }
    }
}
