import Foundation
import CoreWLAN

enum WiFiScanner {
    static func scan() -> [WiFiReading] {
        guard let interface = CWWiFiClient.shared().interface() else {
            return []
        }

        guard let networks = try? interface.scanForNetworks(withName: nil) else {
            return []
        }

        return networks.compactMap { n in
            guard let bssid = n.bssid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !bssid.isEmpty else { return nil }
            let rssi = Int(n.rssiValue)
            return WiFiReading(bssid: bssid, ssid: n.ssid, rssi: rssi)
        }
    }
}
