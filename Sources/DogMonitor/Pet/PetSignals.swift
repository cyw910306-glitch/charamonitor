import Combine
import CoreGraphics
import Foundation

/// What happened on this Mac that a pet (or the assistant's 먼저 말 걸기) reacts to.
enum PetSignal: Equatable {
    /// About every 10 s from the menu bar tick (StatusItemController.updateExtra): battery (nil on desktops),
    /// busyness 0...1 (SystemMonitor.load) and seconds since the last key or mouse input.
    case sample(battery: BatteryStats?, load: Double, idle: TimeInterval)
    /// 클리너 finished and freed this many bytes.
    case cleaned(bytes: UInt64)
    /// An internet speed test finished.
    case speedTest
}

/// Main-thread event feed. Subscribe to `events`; the app sends from the places named on each case.
final class PetSignals {
    static let shared = PetSignals()
    let events = PassthroughSubject<PetSignal, Never>()

    func send(_ signal: PetSignal) { events.send(signal) }

    /// Seconds since the last keyboard or mouse event in this login session (no permission needed).
    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
