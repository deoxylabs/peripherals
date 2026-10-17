import AppKit
import ServiceManagement

/// Peripherals runs as a launchd agent from a plist inside its own bundle:
/// started at login, restarted if it crashes, and left alone after Quit
/// (KeepAlive is SuccessfulExit = false).
///
/// Opening the app by hand registers that agent if needed, then steps aside so
/// there's only ever one copy talking to the devices.
@MainActor
enum Service {
    static let label = "com.deoxylabs.peripherals"
    static let agent = SMAppService.agent(plistName: "\(label).plist")

    /// launchd names every job it starts in XPC_SERVICE_NAME.
    static var isAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    static var enabled: Bool { agent.status == .enabled }

    /// True when this process should carry on and drive the devices.
    static func shouldRun() -> Bool {
        if isAgent { return true }
        if agent.status != .enabled {
            do {
                try agent.register()
            } catch {
                Log.app.error("agent register: \(error.localizedDescription, privacy: .public)")
            }
        }
        switch agent.status {
        case .enabled:
            // launchd starts (or already runs) the agent copy.
            Log.app.notice("handing over to the launchd agent")
            return false
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            return !otherCopyRunning
        default:
            return !otherCopyRunning
        }
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on { try agent.register() } else { try agent.unregister() }
        } catch {
            Log.app.error("agent \(on ? "register" : "unregister"): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var otherCopyRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: label)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    /// razerlight and razeroled, the Python prototypes this replaces, would
    /// fight it for the devices. They're stopped and their plists parked in
    /// LaunchAgents/disabled, where they can be put back by hand.
    static func retirePrototypes() {
        let agents = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")
        let parked = agents.appending(path: "disabled")
        for old in ["com.deoxylabs.razerlight", "com.deoxylabs.razeroled"] {
            let plist = agents.appending(path: "\(old).plist")
            guard FileManager.default.fileExists(atPath: plist.path) else { continue }
            let launchctl = Process()
            launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            launchctl.arguments = ["bootout", "gui/\(getuid())/\(old)"]
            try? launchctl.run()
            launchctl.waitUntilExit()
            try? FileManager.default.createDirectory(at: parked, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: parked.appending(path: "\(old).plist"))
            do {
                try FileManager.default.moveItem(at: plist, to: parked.appending(path: "\(old).plist"))
                Log.app.notice("retired \(old, privacy: .public)")
            } catch {
                Log.app.error("retire \(old, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
