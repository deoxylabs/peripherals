import AppKit
import IOKit.hid
import SwiftUI

@main
struct PeripheralsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Peripherals", systemImage: "flag.filled.and.flag.crossed") {
            Panel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = Model()

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting the unit tests: touch neither launchd nor the devices.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        // For install scripts: withdraw this copy's launchd registration.
        if CommandLine.arguments.contains("--unregister") {
            Service.setEnabled(false)
            exit(0)
        }
        if Service.isAgent {
            Service.retirePrototypes()
            model.start()
            return
        }
        // Opened by hand: ask for Input Monitoring (on a normal Mac this shows
        // a prompt; agents never may), then hand over to the agent.
        let model = model
        Task.detached {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            await MainActor.run {
                guard Service.shouldRun() else { return NSApp.terminate(nil) }
                Service.retirePrototypes()
                model.start()
            }
        }
    }
}

/// Everything the app drives, wired together, and the state the menu shows.
@MainActor
final class Model: ObservableObject {
    @Published var keyboard = false
    @Published var mouse = false
    @Published var screen = "—"
    @Published var message: String?
    @Published var mode: OledController.Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "screenMode")
            oled.setMode(mode)
        }
    }
    @Published var lightsOn: Bool {
        didSet {
            UserDefaults.standard.set(lightsOn, forKey: "lightsOn")
            lighting.setDark(!lightsOn || displaysAsleep)
        }
    }
    @Published var startAtLogin = Service.enabled
    @Published var uploading = false
    @Published var keyboardBattery: Battery?
    @Published var mouseBattery: Battery?
    @Published var lightBrightness: Double {
        didSet {
            UserDefaults.standard.set(lightBrightness, forKey: "lightBrightness")
            lighting.setBrightness(lightBrightness)
        oled.setBrightness(screenBrightness)
        }
    }
    @Published var screenBrightness: Double {
        didSet {
            UserDefaults.standard.set(screenBrightness, forKey: "screenBrightness")
            oled.setBrightness(screenBrightness)
        }
    }

    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
    }

    private let hub = DeviceHub()
    private let link: OledLink
    private let lighting: LightingEngine
    private let oled: OledController
    private let music = MusicWatcher()
    private var displaysAsleep = false

    init() {
        link = OledLink(hub: hub)
        lighting = LightingEngine(hub: hub)
        let saved = UserDefaults.standard.string(forKey: "screenMode").flatMap(OledController.Mode.init)
        mode = saved ?? .auto
        lightsOn = UserDefaults.standard.object(forKey: "lightsOn") as? Bool ?? true
        lightBrightness = UserDefaults.standard.object(forKey: "lightBrightness") as? Double ?? 1
        screenBrightness = UserDefaults.standard.object(forKey: "screenBrightness") as? Double ?? 1
        oled = OledController(hub: hub, link: link, mode: saved ?? .auto)
    }

    func start() {
        let link = link, lighting = lighting, oled = oled
        hub.onOledInput = { link.received($0) }
        hub.onChange = { [weak self] role, present in
            if present {
                if role == .oled { oled.deviceAppeared() } else { lighting.deviceAppeared(role) }
                if role == .keyboard { oled.deviceAppeared() }
            }
            Task { @MainActor in
                self?.refreshConnections()
                self?.refreshBatteries()
            }
        }
        oled.onStatus = { [weak self] text in Task { @MainActor in self?.screen = text } }
        music.onChange = { oled.setMusic($0) }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setDisplaysAsleep(true) }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setDisplaysAsleep(false) }
        }

        lighting.setDark(!lightsOn)
        lighting.setBrightness(lightBrightness)
        lighting.start()
        oled.start()
        hub.start()
        music.start()
        oled.setMusic(music.now)
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBatteries() }
        }
        // Idle is the Mac's idea of it, which counts the mouse too. The
        // keyboard's own timers only see keypresses, so they're switched off
        // (FirmwarePolicy) and this decides when the keys dim instead.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        Log.app.notice("started (agent: \(Service.isAgent, privacy: .public))")
    }

    /// Razer's battery query (class 0x07): level 0-255 from 0x80, charging
    /// from 0x84. Asked off the main thread; each is a couple of round trips.
    func refreshBatteries() {
        let hub = hub
        Task.detached { [weak self] in
            func battery(_ role: DeviceHub.Role) -> Battery? {
                guard let level = hub.query(role, 0x07, 0x80, size: 2) else { return nil }
                let charging = hub.query(role, 0x07, 0x84, size: 2).map { $0[1] == 1 } ?? false
                return Battery(percent: Int((Double(level[1]) / 255 * 100).rounded()), charging: charging)
            }
            let keyboard = battery(.keyboard), mouse = battery(.mouse)
            Log.app.notice("battery: keyboard \(keyboard.map { "\($0.percent)%\($0.charging ? " charging" : "")" } ?? "?", privacy: .public), mouse \(mouse.map { "\($0.percent)%\($0.charging ? " charging" : "")" } ?? "?", privacy: .public)")
            await MainActor.run {
                self?.keyboardBattery = keyboard
                self?.mouseBattery = mouse
            }
        }
    }

    func uploadBootAnimation() {
        uploading = true
        message = "Uploading boot animation…"
        oled.uploadBootAnimation { [weak self] result in
            Task { @MainActor in
                self?.uploading = false
                self?.message = result
            }
        }
    }

    func setStartAtLogin(_ on: Bool) {
        Service.setEnabled(on)
        startAtLogin = Service.enabled
    }

    func quit() {
        lighting.restAndStop()
        oled.restoreAndStop()
        NSApp.terminate(nil)
    }

    private var idle = false
    static let idleAfter: Double = 10 * 60

    private func checkIdle() {
        let now = SystemStats.idleSeconds() >= Self.idleAfter
        guard now != idle else { return }
        idle = now
        lighting.setIdle(now)
        Log.app.notice("\(now ? "idle" : "active", privacy: .public)")
    }

    private func setDisplaysAsleep(_ asleep: Bool) {
        displaysAsleep = asleep
        lighting.setDark(asleep || !lightsOn)
        oled.setDark(asleep)
        Log.app.notice("displays \(asleep ? "asleep" : "awake", privacy: .public)")
    }

    private func refreshConnections() {
        let connected = hub.connected
        keyboard = connected.contains(.keyboard)
        mouse = connected.contains(.mouse)
    }
}
