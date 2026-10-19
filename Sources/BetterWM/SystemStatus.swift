import Cocoa
import CoreWLAN
import Darwin
import IOKit.ps

/// Battery and Wi-Fi readings for the status bar.
enum SystemStatus {
    struct Battery { let percent: Int; let charging: Bool; let symbol: String }

    static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let percent = cap * 100 / max
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let symbol: String
            if charging || plugged {
                symbol = "battery.100percent.bolt"
            } else {
                switch percent {
                case ..<10: symbol = "battery.0percent"
                case ..<35: symbol = "battery.25percent"
                case ..<65: symbol = "battery.50percent"
                case ..<90: symbol = "battery.75percent"
                default: symbol = "battery.100percent"
                }
            }
            return Battery(percent: percent, charging: charging || plugged, symbol: symbol)
        }
        return nil
    }

    private static var lastCPU: (busy: UInt64, total: UInt64)?
    private static var lastCPUValue: Double?

    /// CPU busy fraction 0...1 over the interval since the last distinct sample; refreshes that arrive
    /// before the counters move (focus changes) reuse the previous value instead of blanking the reading.
    static func cpuLoad() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        let busy = user + system + nice, total = busy + idle
        guard let last = lastCPU else { lastCPU = (busy, total); return nil }
        guard total >= last.total, busy >= last.busy else {
            lastCPU = (busy, total)
            return lastCPUValue
        }
        guard total - last.total >= 50 else { return lastCPUValue }
        lastCPU = (busy, total)
        lastCPUValue = Double(busy - last.busy) / Double(total - last.total)
        return lastCPUValue
    }

    /// Memory in use (active + wired + compressed, as Activity Monitor counts it) as a fraction of physical RAM.
    static func memoryUsed() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return Double(used) / Double(ProcessInfo.processInfo.physicalMemory)
    }

    /// Free bytes on the system volume as the Finder reports them.
    static func diskFree() -> Int64? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb >= 1000 ? String(format: "%.1fT", gb / 1000) : String(format: "%.0fG", gb)
    }

    /// Signal strength 0...1, or nil when Wi-Fi is off or disconnected. RSSI needs no Location permission.
    static func wifiStrength() -> Double? {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn(), iface.ssid() != nil || iface.rssiValue() != 0 else { return nil }
        let rssi = iface.rssiValue()
        guard rssi != 0 else { return nil }
        // -50 dBm and above is full; -90 dBm is unusable.
        return min(1, max(0, (Double(rssi) + 90) / 40))
    }
}
