import Foundation

/// The keyboard's own idle handling, switched off while the app drives it.
///
/// The firmware dims the OLED, then swaps in Razer's screensaver, sleeps, and
/// dims the keys, all on timers that only count keypresses. Mouse use doesn't
/// reset them, and a full battery reads as "not charging", so even on the cable
/// the keyboard thinks it's on battery and runs its battery timers. The app
/// decides idleness from the Mac instead (any input device, see Model), so the
/// firmware's versions are turned off here and put back when the app lets go.
///
/// Every one of these lives in the keyboard's flash, so each is read first and
/// only written when it differs. Whatever the keyboard had before the app first
/// changed it is remembered, and that's what gets restored.
enum FirmwarePolicy {
    struct Setting: Sendable {
        let name: String
        let commandClass: UInt8
        let get: UInt8
        let set: UInt8
        let size: UInt8
        /// The app's value, keeping any bytes it doesn't care about.
        let owned: @Sendable ([UInt8]) -> [UInt8]
        /// What the keyboard ships with, for when nothing was remembered.
        let factory: [UInt8]
    }

    static let settings: [Setting] = [
        // Minutes until the OLED dims; Synapse's "off" is 0.
        Setting(name: "OLED dim", commandClass: 0x17, get: 0x86, set: 0x06, size: 1,
                owned: { _ in [0] }, factory: [4]),
        // A second OLED idle timer in minutes, off on this keyboard; kept off.
        Setting(name: "OLED timer", commandClass: 0x17, get: 0x85, set: 0x05, size: 1,
                owned: { _ in [0] }, factory: [0]),
        // [mode, item]: mode 0 is Synapse's "No screensaver".
        Setting(name: "OLED screensaver", commandClass: 0x17, get: 0x96, set: 0x16, size: 2,
                owned: { [0, max($0[1], 1)] }, factory: [1, 1]),
        // [?, enabled]
        Setting(name: "auto sleep", commandClass: 0x07, get: 0x88, set: 0x08, size: 2,
                owned: { [$0[0], 0] }, factory: [0, 1]),
        // [?, enabled, seconds (BE16), brightness %]
        Setting(name: "lighting dim", commandClass: 0x07, get: 0x8B, set: 0x0B, size: 5,
                owned: { [$0[0], 0, $0[2], $0[3], $0[4]] }, factory: [0, 1, 0x01, 0x2C, 0x14]),
    ]

    /// Takes the firmware's idle handling over (`own`), or gives it back.
    /// Returns false if the keyboard couldn't be asked, so the caller retries.
    @discardableResult
    static func apply(own: Bool, hub: DeviceHub) -> Bool {
        let defaults = UserDefaults.standard
        var remembered = defaults.dictionary(forKey: "firmwareOriginals") as? [String: [Int]] ?? [:]
        var ok = true
        for setting in settings {
            guard let reply = hub.query(.keyboard, setting.commandClass, setting.get, size: setting.size) else {
                ok = false
                continue
            }
            let current = Array(reply.prefix(Int(setting.size)))
            let ours = setting.owned(current)
            let wanted: [UInt8]
            if own {
                if current != ours, remembered[setting.name] == nil {
                    remembered[setting.name] = current.map(Int.init)
                }
                wanted = ours
            } else {
                wanted = remembered[setting.name].map { $0.map(UInt8.init) } ?? setting.factory
            }
            guard current != wanted else { continue }
            hub.send(.keyboard, RazerReport.make(setting.commandClass, setting.set, wanted))
            Log.hid.notice("\(setting.name, privacy: .public): \(hex(current), privacy: .public) -> \(hex(wanted), privacy: .public)")
        }
        defaults.set(remembered, forKey: "firmwareOriginals")
        return ok
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
