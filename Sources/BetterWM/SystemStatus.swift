import Cocoa
import CoreWLAN
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

    /// Signal strength 0...1, or nil when Wi-Fi is off or disconnected. RSSI needs no Location permission.
    static func wifiStrength() -> Double? {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn(), iface.ssid() != nil || iface.rssiValue() != 0 else { return nil }
        let rssi = iface.rssiValue()
        guard rssi != 0 else { return nil }
        // -50 dBm and above is full; -90 dBm is unusable.
        return min(1, max(0, (Double(rssi) + 90) / 40))
    }
}
