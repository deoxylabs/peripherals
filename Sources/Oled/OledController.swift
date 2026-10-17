import Foundation

/// The keyboard's OLED: now playing while Music plays, a clock otherwise.
///
/// The now-playing frame is one 232x64 image, uploaded once per track, because
/// every upload is a flash write on the display's own MCU. The clock is the
/// firmware's system-info screen: the time, CPU and memory go into a RAM
/// buffer every second and the firmware draws the digits, so it costs no flash
/// at all. Only its three slide backgrounds are images, and they change daily.
final class OledController: @unchecked Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case auto, clock, razer, off
        var title: String {
            switch self {
            case .auto: "Now playing, then clock"
            case .clock: "Clock"
            case .razer: "Razer animation"
            case .off: "Off"
            }
        }
    }

    static let pauseGrace = 60.0          // a paused track stays up this long
    static let imageSlot: UInt8 = 0
    /// Bump when the clock backgrounds change, so they're uploaded again.
    static let backgroundDesign = 1

    private let hub: DeviceHub
    private let link: OledLink
    private let stats = SystemStats()
    private let queue = DispatchQueue(label: "com.deoxylabs.peripherals.oled")
    private var timer: DispatchSourceTimer?

    private var mode: Mode
    private var dark = false
    private var music = MusicWatcher.Now(state: .stopped, track: nil)
    private var pausedSince: Date?
    private var shown: String?            // what the screen was last told to show
    private var onSlot: String?           // the track id the image slot holds
    private var retryAt = Date.distantPast

    /// Reports what's on screen, for the menu.
    var onStatus: (@Sendable (String) -> Void)?

    init(hub: DeviceHub, link: OledLink, mode: Mode) {
        self.hub = hub
        self.link = link
        self.mode = mode
    }

    func start() {
        queue.async { [self] in
            _ = stats.cpuPercent()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 1.0)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func setMode(_ value: Mode) { queue.async { [self] in mode = value; tick() } }
    func setDark(_ value: Bool) { queue.async { [self] in dark = value; shown = nil; tick() } }
    func setMusic(_ value: MusicWatcher.Now) { queue.async { [self] in music = value; tick() } }

    /// Whatever the keyboard was showing may be gone after a reconnect.
    func deviceAppeared() { queue.async { [self] in shown = nil; tick() } }

    /// Razer's own animation again, rather than a clock frozen at this minute.
    func restoreAndStop() {
        queue.sync { [self] in
            timer?.cancel()
            hub.send(.keyboard, setting(0x0D, [0, 0]))
        }
    }

    /// Writes the power-on animation. Slow (about 11,000 packets), so it runs
    /// on this queue and the screen just pauses meanwhile.
    func uploadBootAnimation(completion: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            do {
                try link.uploadAnimation(slot: 0, frames: BootAnimation.frames(),
                                         intervalMS: 1000 / BootAnimation.fps)
                completion("Boot animation uploaded. Power-cycle the keyboard to see it.")
            } catch {
                completion("Boot animation failed: \(error)")
            }
        }
    }

    // MARK: -

    private func tick() {
        let connected = hub.connected
        guard connected.contains(.keyboard), connected.contains(.oled) else { return }
        if dark { return show("off") { hub.send(.keyboard, setting(0x0D, [7, 7])) } }

        switch mode {
        case .razer: return show("razer") { hub.send(.keyboard, setting(0x0D, [0, 0])) }
        case .off: return show("off") { hub.send(.keyboard, setting(0x0D, [7, 7])) }
        case .clock: showClock()
        case .auto:
            switch music.state {
            case .playing: pausedSince = nil
            case .paused: pausedSince = pausedSince ?? Date()
            case .stopped: pausedSince = nil
            }
            let holding = pausedSince.map { Date().timeIntervalSince($0) < Self.pauseGrace } ?? false
            if let track = music.track, music.state == .playing || holding {
                showTrack(track)
            } else {
                showClock()
            }
        }
        let now = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        hub.send(.keyboard, setting(0x09, Screens.liveValues(
            hour: now.hour!, minute: now.minute!, second: now.second!,
            cpu: stats.cpuPercent(), memory: stats.memoryPercent())))
    }

    private func showTrack(_ track: Screens.Track) {
        if onSlot != track.id {
            guard Date() >= retryAt else { return }
            let data = MusicWatcher.artwork()
            let frame = Screens.nowPlaying(track, cover: data.flatMap { Artwork.cover($0) })
            do {
                try link.upload(command: 0x12, index: Self.imageSlot, image: frame)
            } catch {
                Log.oled.error("track upload: \(String(describing: error), privacy: .public)")
                retryAt = Date() + 5
                return
            }
            onSlot = track.id
            shown = nil
            Log.oled.notice("now playing: \(track.name, privacy: .public) - \(track.artist, privacy: .public)")
        }
        show("track") {
            hub.send(.keyboard, setting(0x02, [1, Self.imageSlot + 1] + [UInt8](repeating: 0, count: 17)))
            hub.send(.keyboard, setting(0x0D, [1, 1]))
        }
        onStatus?("\(track.name) — \(track.artist)")
    }

    private func showClock() {
        uploadBackgroundsIfNeeded()
        show("clock") {
            hub.send(.keyboard, setting(0x02, Screens.clockRecord))
            hub.send(.keyboard, setting(0x0D, [6, 6]))
        }
    }

    /// Once a day for the date, and again whenever the design changes.
    private func uploadBackgroundsIfNeeded() {
        let today = Date()
        let day = Calendar.current.dateComponents([.year, .month, .day], from: today)
        let key = "\(day.year!)-\(day.month!)-\(day.day!)/\(Self.backgroundDesign)"
        guard UserDefaults.standard.string(forKey: "clockBackgrounds") != key, Date() >= retryAt else { return }
        do {
            for (index, slide) in Screens.slides.enumerated() {
                try link.upload(command: 0x10, index: UInt8(index), image: Screens.clockBackground(slide, date: today))
            }
        } catch {
            Log.oled.error("backgrounds: \(String(describing: error), privacy: .public)")
            retryAt = Date() + 5
            return
        }
        UserDefaults.standard.set(key, forKey: "clockBackgrounds")
        Log.oled.notice("clock backgrounds for \(key, privacy: .public)")
    }

    private func show(_ name: String, _ apply: () -> Void) {
        guard shown != name else { return }
        apply()
        shown = name
        if name != "track" { onStatus?(name == "clock" ? "Clock" : name == "razer" ? "Razer animation" : "Off") }
    }

    private func setting(_ id: UInt8, _ args: [UInt8]) -> [UInt8] {
        RazerReport.make(0x17, id, args)
    }
}
