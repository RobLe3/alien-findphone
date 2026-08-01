import AudioToolbox
import Foundation

/// Geiger-style feedback: the closer the device, the faster the clicks, so a
/// room can be swept without watching the screen.
final class Clicker {
    private var sound: SystemSoundID = 0

    private let fastest: TimeInterval = 0.12
    private let slowest: TimeInterval = 2.0
    private var lastClick = Date.distantPast

    init?(path: String = "/System/Library/Sounds/Tink.aiff") {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              AudioServicesCreateSystemSoundID(url as CFURL, &sound) == kAudioServicesNoError
        else { return nil }
    }

    deinit {
        AudioServicesDisposeSystemSoundID(sound)
    }

    func click(rssi: Int, now: Date) {
        let interval = slowest - Proximity.fraction(rssi) * (slowest - fastest)
        guard now.timeIntervalSince(lastClick) >= interval else { return }
        lastClick = now
        AudioServicesPlaySystemSound(sound)
    }
}
