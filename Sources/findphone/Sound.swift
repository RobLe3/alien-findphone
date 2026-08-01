import AudioToolbox
import Foundation

/// Geiger-style feedback: the closer the device, the faster the clicks, so a
/// room can be swept by ear while looking at the room.
///
/// Self-pacing rather than driven by the render loop, which ticks at 4 Hz and
/// would cap the cadence at four clicks a second.
final class Clicker {
    /// Calibrated to what the radio delivers rather than to the display scale:
    /// a laptop resting on the phone reads about -50 dBm, so the cadence tops
    /// out there instead of ramping toward a -30 that never arrives.
    private let touching = -50.0
    private let distant = -95.0

    private let fastest: TimeInterval = 0.07
    private let slowest: TimeInterval = 1.0

    private var sound: SystemSoundID = 0
    private var rssi: Int?

    init?(path: String = "/System/Library/Sounds/Tink.aiff") {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              AudioServicesCreateSystemSoundID(url as CFURL, &sound) == kAudioServicesNoError
        else { return nil }
    }

    deinit {
        AudioServicesDisposeSystemSoundID(sound)
    }

    func start() {
        schedule()
    }

    /// Pass nil when contact is stale, so silence means no signal.
    func update(rssi: Int?) {
        self.rssi = rssi
    }

    private func interval(for rssi: Int) -> TimeInterval {
        let ramp = (Double(rssi) - distant) / (touching - distant)
        return slowest - min(1, max(0, ramp)) * (slowest - fastest)
    }

    private func schedule() {
        let wait = rssi.map(interval) ?? slowest
        Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.rssi != nil { AudioServicesPlaySystemSound(self.sound) }
            self.schedule()
        }
    }
}
