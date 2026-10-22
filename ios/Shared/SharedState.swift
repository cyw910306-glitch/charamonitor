import CharaCore
import Foundation
import UIKit
import WidgetKit

/// The small state the app and its widgets pass through the app group (Shared.defaults): who is chosen, how they
/// talk, sound and haptics, the 집중 타이머 run, the last battery the app saw, and the medium widget's tap reaction.
/// Keys are saved; never rename one.
enum SharedState {
    /// 소리, 진동: on unless turned off.
    static let soundKey = "sound", hapticsKey = "haptics"
    /// Who the widgets show: a character id, or "" for the one the app shows.
    static let widgetCharacterKey = "widgetCharacterID"
    /// The 집중 타이머 run: when it ends (a Date, absent when none runs) and how long it is in minutes.
    static let focusEndKey = "focusEnd", focusMinutesKey = "focusMinutes"
    /// Minutes of finished focus runs today, and which day that is ("2026-10-23").
    static let focusTodayKey = "focusToday", focusDayKey = "focusDay"

    static func flag(_ key: String) -> Bool { Shared.defaults.object(forKey: key) as? Bool ?? true }

    static var chosenCharacterID: String? { Shared.defaults.string(forKey: Shared.chosenKey) }

    /// The character the widgets show: their own pick, else the app's.
    static var widgetCharacterID: String? {
        let id = Shared.defaults.string(forKey: widgetCharacterKey) ?? ""
        return id.isEmpty ? chosenCharacterID : id
    }

    /// The owner's 말투 pick (a PersonaStyle raw value); .auto when unset.
    static var persona: PersonaStyle { PersonaStyle(rawValue: Shared.defaults.string(forKey: "persona") ?? "") ?? .auto }

    /// The running focus run's end, nil when none.
    static var focusEnd: Date? { Shared.defaults.object(forKey: focusEndKey) as? Date }

    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
    }

    /// The device's battery now; what the app saved in the last `savedBatteryLasts` when this process cannot read it
    /// (the simulator, or a widget the system will not tell); nil when neither knows. Monitoring is on only to read.
    static var battery: Battery? { deviceBattery ?? saved(at: Shared.defaults.object(forKey: "batteryAt") as? Date) }

    /// What this process reads itself, nil when it cannot.
    static var deviceBattery: Battery? {
        let device = UIDevice.current, was = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = was }
        guard device.batteryLevel >= 0 else { return nil }
        return Battery(percent: Int((device.batteryLevel * 100).rounded()), charging: device.batteryState == .charging || device.batteryState == .full)
    }

    /// An older saved battery is dropped: it may say charging (or 15%) long after the phone was unplugged.
    static let savedBatteryLasts: TimeInterval = 30 * 60

    static func saved(at: Date?, now: Date = .now) -> Battery? {
        guard let at, abs(now.timeIntervalSince(at)) < savedBatteryLasts else { return nil }
        return Battery(percent: Shared.defaults.integer(forKey: "batteryPercent"), charging: Shared.defaults.bool(forKey: "batteryCharging"))
    }

    /// The app calls this when it comes forward and when the battery changes while it shows, so the widgets have a
    /// battery even where they cannot read one.
    static func saveBattery() {
        guard let b = deviceBattery else { return }   // never re-date a saved one
        Shared.defaults.set(b.percent, forKey: "batteryPercent")
        Shared.defaults.set(b.charging, forKey: "batteryCharging")
        Shared.defaults.set(Date.now, forKey: "batteryAt")
    }

    /// The last tap on the medium widget's character: which reaction (it counts up) and when.
    static var reaction: (index: Int, at: Date)? {
        guard let at = Shared.defaults.object(forKey: "reactionAt") as? Date else { return nil }
        return (Shared.defaults.integer(forKey: "reactionIndex"), at)
    }

    static func react(now: Date = .now) {
        Shared.defaults.set((reaction?.index ?? -1) + 1, forKey: "reactionIndex")
        Shared.defaults.set(now, forKey: "reactionAt")
    }

    /// After any change the widgets show.
    static func changed() { WidgetCenter.shared.reloadAllTimelines() }
}
