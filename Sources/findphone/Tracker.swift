import Foundation
import CoreBluetooth
import CoreWLAN

private let audioRSSIWindow: TimeInterval = 0.8
private let audioRSSIMaxAge: TimeInterval = 1.5

enum LinkState: String {
    case down = "LINK DOWN"
    case classic = "link up"
    case live = "LIVE LINK"
}

let continuityNames: [UInt8: String] = [
    0x0C: "Handoff", 0x0D: "Hotspot-tgt", 0x0E: "Hotspot-src",
    0x0F: "NearbyAction", 0x10: "NearbyInfo",
]

/// Continuity message types that phones, tablets and watches emit.
let handheldTypes = Set(continuityNames.keys)

struct Snapshot {
    let targetName: String?
    let address: String?
    let at: Date
    let elapsed: Int
    let readings: [Reading]
    let link: LinkState
    let radioIssue: String?
    let assets: [TrackedAsset]
    let potentialAssets: [TrackedAsset]
    let sourceDistribution: [SignalSource: Int]
    let deviceCount: Int
    let selectedIdentity: String?
    let isManualTracking: Bool
    let estimate: TriangulationEstimate?
    let focusAsset: TrackedAsset?
    let focusReadings: [Reading]

    /// The reading everything reports: a short median, so one reflected spike
    /// cannot move the number, the arrow and the clicks apart from each other.
    var live: Int? {
        readings.since(liveWindow, now: at).medianRSSI ?? readings.last?.rssi
    }

    /// Whether the last reading is recent enough to steer by.
    var isFresh: Bool {
        readings.last.map { at.timeIntervalSince($0.at) < 10 } ?? false
    }

    var focusLive: Int? {
        focusReadings.since(liveWindow, now: at).medianRSSI ?? focusReadings.last?.rssi
    }

    /// Short-window, target-only RSSI sample for tracker audio.
    ///
    /// The full bestRSSI value may retain an older reading that is no longer
    /// representative of the selected target. This uses only readings from the
    /// currently focused identity and a very short window.
    var focusAudioRSSI: Int? {
        guard let newest = focusReadings.last else {
            return nil
        }

        guard at.timeIntervalSince(newest.at) <= audioRSSIMaxAge else {
            return nil
        }

        let recent = focusReadings.since(audioRSSIWindow, now: at)
        return recent.medianRSSI ?? newest.rssi
    }

    var focusFresh: Bool {
        focusReadings.last.map { at.timeIntervalSince($0.at) < 10 } ?? false
    }
}

private let appleCompanyID: UInt16 = 0x004C
private let historyWindow: TimeInterval = 600
private let assetHistoryWindow: TimeInterval = 45

final class Tracker: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let targetName: String?
    private let startedAt = Date()
    private let enableWiFi: Bool
    private let anchorCatalog: AnchorCatalog

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var linkTimer: Timer?
    private var wifiTimer: Timer?

    private var readings: [Reading] = []
    private var perAssetReadings: [String: [Reading]] = [:]
    private var address: String?
    private var radioIssue: String?
    private var cachedID: UUID?

    private var liveLink = false
    private var linkUp = false
    private var assets: [String: TrackedAsset] = [:]
    private var selectedIdentity: String?

    private let lock = NSLock()
    private var isLive: Bool { lock.withLock { liveLink } }

    init(targetName: String?, enableWiFi: Bool, anchorPath: String? = nil) {
        self.targetName = targetName
        self.enableWiFi = enableWiFi
        self.anchorCatalog = AnchorCatalog.load(path: anchorPath)
        super.init()
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
        if let name = targetName {
            cachedID = DeviceCache.peripheralID(for: name)
            pollClassic(name: name)
        }
        if enableWiFi {
            startWiFiScan()
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.prune()
        }
    }

    func snapshot() -> Snapshot {
        let now = Date()
        let selectedIdentity = lock.withLock { self.selectedIdentity }
        let snapshotAssets = lock.withLock {
            assets.values.sorted {
                let a = $0.confidence(now: now)
                let b = $1.confidence(now: now)
                if a == b {
                    return $0.bestRSSI > $1.bestRSSI
                }
                return a > b
            }
        }
        let potential = snapshotAssets.filter { $0.confidence(now: now) >= 0.28 && $0.isFresh(at: now) }

        let (focus, focusReadings): (TrackedAsset?, [Reading]) = lock.withLock {
            var selected = primaryAsset(from: potential.isEmpty ? snapshotAssets : potential)
            if let selectedIdentity {
                selected = snapshotAssets.first { $0.identity == selectedIdentity }
                    ?? potential.first { $0.identity == selectedIdentity }
                    ?? selected
            }
            let readingHistory = selected.flatMap { perAssetReadings[$0.identity] } ?? []
            return (selected, readingHistory)
        }
        let manualTracking = selectedIdentity != nil && snapshotAssets.contains(where: { $0.identity == selectedIdentity })

        var sourceCounts: [SignalSource: Int] = [:]
        for asset in snapshotAssets {
            for source in asset.sources.keys {
                sourceCounts[source, default: 0] += 1
            }
        }
        let readingSnapshot = lock.withLock { readings }

        return Snapshot(
            targetName: targetName,
            address: address,
            at: now,
            elapsed: Int(now.timeIntervalSince(startedAt)),
            readings: readingSnapshot,
            link: isLive ? .live : (linkUp ? .classic : .down),
            radioIssue: radioIssue,
            assets: snapshotAssets,
            potentialAssets: potential,
            sourceDistribution: sourceCounts,
            deviceCount: snapshotAssets.count,
            selectedIdentity: selectedIdentity,
            isManualTracking: manualTracking,
            estimate: estimate(now: now),
            focusAsset: focus,
            focusReadings: focusReadings
        )
    }

    func setManualFocus(identity: String?) {
        lock.withLock {
            selectedIdentity = identity
        }
    }

    private func startWiFiScan() {
        // Best effort: Wi‑Fi scanning can be unavailable on some systems.
        guard CWWiFiClient.shared().interface() != nil else { return }
        let queue = DispatchQueue(label: "findphone.wifi")
        wifiTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: true) { _ in
            queue.async { [weak self] in
                self?.scanWiFi()
            }
        }
        queue.async { [weak self] in
            self?.scanWiFi()
        }
    }

    private func scanWiFi() {
        guard enableWiFi else { return }
        let now = Date()
        let wifiReadings = WiFiScanner.scan()
        for reading in wifiReadings {
            guard reading.rssi < 0, reading.rssi > -127 else { continue }
            let bssid = reading.bssid.lowercased()
            let identity = "wifi:\(bssid)"
            let label = (reading.ssid?.isEmpty == false ? reading.ssid! : bssid)
            let signal = AssetSignal(source: .wifi, identity: identity,
                                    label: label,
                                    rssi: reading.rssi,
                                    at: now)
            recordAsset(signal)

            if let anchor = anchorCatalog.match(bssid: bssid, ssid: reading.ssid) {
                recordAsset(AssetSignal(
                    source: .anchor,
                    identity: "anchor:\(anchor.id.lowercased())",
                    label: anchor.label,
                    rssi: reading.rssi,
                    at: now
                ))
            }
        }
    }

    private func prune() {
        let now = Date()
        lock.withLock {
            while let oldest = readings.first,
                  now.timeIntervalSince(oldest.at) >= historyWindow {
                readings.removeFirst()
            }

            for identity in Array(perAssetReadings.keys) {
                perAssetReadings[identity] = perAssetReadings[identity]?.filter {
                    now.timeIntervalSince($0.at) < historyWindow
                }
                if perAssetReadings[identity]?.isEmpty == true {
                    perAssetReadings[identity] = nil
                }
            }

            assets = assets.filter { now.timeIntervalSince($0.value.last) < assetHistoryWindow }
            for identity in Array(perAssetReadings.keys) where assets[identity] == nil {
                perAssetReadings.removeValue(forKey: identity)
            }
        }
    }

    private func recordReading(_ signal: AssetSignal) {
        let rssi = signal.rssi
        guard rssi < 0, rssi > -127 else { return }
        let source = signal.source.rawValue
        let entry = Reading(rssi: rssi, at: signal.at, source: source)
        lock.withLock {
            readings.append(entry)
            perAssetReadings[signal.identity, default: []].append(entry)
        }
    }

    private func recordAsset(_ signal: AssetSignal) {
        lock.withLock {
            let existing = assets[signal.identity]
            if var current = existing {
                current.record(signal)
                assets[signal.identity] = current
            } else {
                assets[signal.identity] = TrackedAsset(
                    identity: signal.identity,
                    label: signal.label,
                    rssi: signal.rssi,
                    at: signal.at,
                    source: signal.source)
            }
        }
        recordReading(signal)
    }

    private func primaryAsset(from candidates: [TrackedAsset]) -> TrackedAsset? {
        guard !candidates.isEmpty else { return nil }
        if targetName == nil { return candidates.first }

        let targetOnly = candidates.filter { isTargetCandidate($0) }
        if let best = (targetOnly.isEmpty ? candidates : targetOnly).first { return best }
        return candidates.first
    }

    private func isTargetCandidate(_ candidate: TrackedAsset) -> Bool {
        guard targetName != nil else { return true }
        if candidate.identity.hasPrefix("ble:") || candidate.identity.hasPrefix("classic:") {
            return true
        }
        let sources = Set(candidate.sources.keys)
        return sources.contains(.bleLink) || sources.contains(.classic)
    }

    private func estimate(now: Date) -> TriangulationEstimate? {
        let anchored = lock.withLock { assets.values.filter { $0.sources.keys.contains(.anchor) } }
        let catalog = Dictionary(uniqueKeysWithValues: anchorCatalog.anchors.map { ($0.id.lowercased(), $0) })
        guard anchored.count >= 2 else { return nil }

        var weightTotal = 0.0
        var weightedX = 0.0
        var weightedY = 0.0
        var observed = 0

        for anchorAsset in anchored {
            let components = anchorAsset.identity.split(separator: ":", maxSplits: 1)
            guard components.count == 2 else { continue }
            let anchorID = String(components[1]).lowercased()
            guard let anchor = catalog[anchorID],
                  let x = anchor.x, let y = anchor.y,
                  let sample = anchorAsset.sources[.anchor]
            else { continue }
            let age = now.timeIntervalSince(sample.at)
            if age > 90 { continue }
            let quality = max(0.05, (Double(sample.rssi) + 100) / 45.0)
            let ageFactor = max(0.0, 1.0 - age / 90.0)
            let weight = quality * ageFactor
            weightTotal += weight
            weightedX += x * weight
            weightedY += y * weight
            observed += 1
        }

        guard weightTotal > 0 else { return nil }
        return TriangulationEstimate(
            x: weightedX / weightTotal,
            y: weightedY / weightTotal,
            confidence: min(1.0, Double(observed) / 6.0),
            sources: observed
        )
    }

    // MARK: - Classic polling

    /// Skipped while the GATT link is live: the link is both fresher and far
    /// cheaper than spawning system_profiler. macOS serves a cached RSSI
    /// between its own refreshes, so only a changed value is a real
    /// measurement.
    private func pollClassic(name: String) {
        DispatchQueue(label: "classic.poll").async { [weak self] in
            var lastRaw: Int?
            var addressResolved = false
            while true {
                guard let self else { return }
                if self.isLive && addressResolved {
                    lastRaw = nil
                } else {
                    let found = Classic.find(name: name)
                    let value = found?.rssi
                    let changed = value != nil && value != lastRaw
                    lastRaw = value
                    addressResolved = true
                    DispatchQueue.main.async {
                        self.address = found?.address ?? self.address
                        self.linkUp = value != nil
                        if changed, let v = value {
                                                        if let addr = self.address {
                                self.recordAsset(AssetSignal(
                                    source: .classic,
                                    identity: "classic:\(addr)",
                                    label: "Classic: \(found?.name ?? name)",
                                    rssi: v,
                                    at: Date()
                                ))
                            }
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
    }

    // MARK: - Central

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            radioIssue = nil
            c.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            restoreCachedTarget()
        case .poweredOff:
            radioIssue = "Bluetooth is off. Waiting for it to come back on."
            dropLink()
        case .unauthorized:
            fail("""
                 Bluetooth permission denied.
                 System Settings > Privacy & Security > Bluetooth > enable your terminal.
                 """)
        case .unsupported:
            fail("This Mac has no Bluetooth LE support.")
        default:
            radioIssue = "Bluetooth unavailable."
        }
    }

    /// A remembered peripheral can be connected before any advertisement
    /// arrives, which is the difference between a 2s and a 30s cold start.
    private func restoreCachedTarget() {
        guard target == nil, let id = cachedID,
              let p = central.retrievePeripherals(withIdentifiers: [id]).first
        else { return }
        adopt(p)
    }

    private func adopt(_ p: CBPeripheral) {
        target = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    private func dropLink() {
        lock.withLock { liveLink = false }
        linkTimer?.invalidate()
        linkTimer = nil
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData d: [String: Any], rssi RSSI: NSNumber) {
        let r = RSSI.intValue
        guard r < 0, r > -127 else { return }

        let types = continuityTypes(d)
        let name = (d[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        let recognized = types.intersection(handheldTypes).isEmpty == false || name != nil

        let now = Date()

        if targetName != nil {
            if let t = targetName, let n = name, n.localizedCaseInsensitiveContains(t) {
                let identity = "ble:\(p.identifier.uuidString)"
                recordAsset(AssetSignal(source: .bleAdvert, identity: identity,
                                       label: n,
                                       rssi: r, at: now))
                                if cachedID != p.identifier {
                    cachedID = p.identifier
                    DeviceCache.store(p.identifier, for: t)
                }
                guard let current = target else { return adopt(p) }
                if current.state != .connected && current.identifier != p.identifier {
                    central.cancelPeripheralConnection(current)
                    adopt(p)
                }
            }
            return
        }

        guard recognized else { return }

        let identity = "ble:\(p.identifier.uuidString)"
        let label = name ?? "BLE"
        recordAsset(AssetSignal(source: .bleAdvert, identity: identity,
                               label: label, rssi: r, at: now))
    }

    private func continuityTypes(_ d: [String: Any]) -> Set<UInt8> {
        guard let mfg = d[CBAdvertisementDataManufacturerDataKey] as? Data else { return [] }
        let bytes = [UInt8](mfg)
        guard bytes.count >= 3,
              UInt16(bytes[0]) | (UInt16(bytes[1]) << 8) == appleCompanyID else { return [] }
        var types = Set<UInt8>()
        var i = 2
        while i + 1 < bytes.count {
            types.insert(bytes[i])
            let len = Int(bytes[i + 1])
            if len == 0 { break }
            i += 2 + len
        }
        return types
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        lock.withLock { liveLink = true }
        linkTimer?.invalidate()
        linkTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            p.readRSSI()
        }
    }

    /// CoreBluetooth holds an unfulfilled connect pending indefinitely, so
    /// simply reissuing it is a complete reconnect strategy.
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                        error: Error?) {
        dropLink()
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        dropLink()
        c.connect(p, options: nil)
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let rssi = RSSI.intValue
        guard rssi < 0, rssi > -127 else { return }
        recordAsset(AssetSignal(
            source: .bleLink,
            identity: "ble:\(p.identifier.uuidString)",
            label: p.name ?? "BLE target",
            rssi: rssi,
            at: Date()
        ))
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("findphone: \(message)\n".utf8))
    exit(1)
}
