import Foundation

enum SignalSource: String {
    case bleAdvert = "BLE ADVERT"
    case bleLink = "BLE LINK"
    case classic = "CLASSIC"
    case wifi = "WIFI"
    case anchor = "ANCHOR"

    var short: String {
        switch self {
        case .bleAdvert: return "AD"
        case .bleLink: return "LK"
        case .classic: return "CL"
        case .wifi: return "WF"
        case .anchor: return "AN"
        }
    }
}

struct AssetSignal {
    let source: SignalSource
    let identity: String
    let label: String
    let rssi: Int
    let at: Date
}

struct SourceReading {
    var rssi: Int
    var at: Date
}

struct TrackedAsset {
    let identity: String
    var label: String
    var peak: Int
    var last: Date
    var sources: [SignalSource: SourceReading]

    init(identity: String, label: String, rssi: Int, at: Date, source: SignalSource) {
        self.identity = identity
        self.label = label
        self.peak = rssi
        self.last = at
        self.sources = [source: SourceReading(rssi: rssi, at: at)]
    }

    mutating func record(_ signal: AssetSignal) {
        peak = max(peak, signal.rssi)
        last = max(last, signal.at)
        sources[signal.source] = SourceReading(rssi: signal.rssi, at: signal.at)
        if !signal.label.isEmpty {
            label = signal.label
        }
    }

    var mostRecentSource: SignalSource? {
        sources.max { $0.value.at < $1.value.at }?.key
    }

    var bestRSSI: Int {
        sources.values.map(\.rssi).max() ?? -127
    }

    var sourceCount: Int { sources.count }

    func isFresh(at now: Date, ttl: TimeInterval = 8) -> Bool {
        now.timeIntervalSince(last) < ttl
    }

    func confidence(now: Date) -> Double {
        let age = now.timeIntervalSince(last)
        let recency = max(0, 1 - age / 45)
        let strength = max(0, min(1, (Double(bestRSSI) + 110) / 60))
        let corroboration = min(1.0, Double(sourceCount - 1) * 0.15)
        let sourceBias = Double(min(sources.count, 4)) / 4.0
        return 0.55 * strength + 0.25 * recency + 0.2 * max(corroboration, sourceBias)
    }

    func topSources(limit: Int = 2) -> [SignalSource] {
        let sorted = sources.sorted { lhs, rhs in
            let lt = Proximity.band(lhs.value.rssi)
            let rt = Proximity.band(rhs.value.rssi)
            if lt == rt { return lhs.key.rawValue < rhs.key.rawValue }
            return lt < rt
        }
        return sorted.prefix(limit).map(\.key)
    }
}

struct LocationAnchor: Decodable {
    let id: String
    let label: String
    let bssid: String?
    let ssid: String?
    let x: Double?
    let y: Double?
}

struct AnchorCatalog {
    struct File: Decodable {
        let anchors: [LocationAnchor]
    }

    let anchors: [LocationAnchor]

    static let filename = "anchors.json"

    static func load(path: String?) -> AnchorCatalog {
        guard let path else { return AnchorCatalog(anchors: []) }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AnchorCatalog(anchors: [])
        }
        guard let data = try? Data(contentsOf: url) else { return AnchorCatalog(anchors: []) }
        guard let decoded = try? JSONDecoder().decode(File.self, from: data) else {
            return AnchorCatalog(anchors: [])
        }
        return AnchorCatalog(anchors: decoded.anchors)
    }

    func match(bssid: String?, ssid: String?) -> LocationAnchor? {
        let lowered = bssid?.lowercased()
        let normalizedSSID = ssid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return anchors.first {
            let sameBssid = ($0.bssid?.lowercased() == lowered) && bssid != nil
            let sameSsid = $0.ssid?.isEmpty == false
                && $0.ssid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedSSID
            return sameBssid || sameSsid
        }
    }
}

struct TriangulationEstimate {
    let x: Double
    let y: Double
    let confidence: Double
    let sources: Int
}

struct WiFiReading {
    let bssid: String
    let ssid: String?
    let rssi: Int
}
