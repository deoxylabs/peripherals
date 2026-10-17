import AppKit

/// What Apple Music is doing, from the notification it posts on every change,
/// so nothing polls. The two things the notification doesn't give, the state
/// at launch and the artwork, come from AppleScript (see OsaScript for why
/// that goes through osascript).
@MainActor
final class MusicWatcher {
    enum State: String, Sendable { case playing, paused, stopped }

    struct Now: Sendable, Equatable {
        var state: State
        var track: Screens.Track?
    }

    private(set) var now = Now(state: .stopped, track: nil)
    var onChange: ((Now) -> Void)?

    nonisolated private static let bundle = "com.apple.Music"

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            let info = Info(note.userInfo ?? [:])
            MainActor.assumeIsolated { self?.received(info) }
        }
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.bundle else { return }
            MainActor.assumeIsolated { self?.update(Now(state: .stopped, track: nil)) }
        }
        // Music says nothing until something changes, so ask what it's doing.
        // Retried until it answers: the first osascript may sit behind its
        // one-time Automation prompt.
        Task.detached { [weak self] in
            while true {
                if let now = Self.current() {
                    await MainActor.run { self?.update(now) }
                    return
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// What Music is playing right now, or nil if it couldn't be asked.
    /// Never launches Music: when it isn't running the answer is "stopped".
    nonisolated static func current() -> Now? {
        guard isRunning else { return Now(state: .stopped, track: nil) }
        let script = """
        tell application "Music"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as text) & tab & (persistent ID of t) & tab & (name of t) & tab & (artist of t) & tab & (album of t)
        end tell
        """
        guard let out = OsaScript.run(script) else { return nil }
        let fields = out.components(separatedBy: "\t")
        guard fields.count == 5, let state = State(rawValue: fields[0]) else { return Now(state: .stopped, track: nil) }
        return Now(state: state, track: Screens.Track(id: fields[1], name: fields[2], artist: fields[3], album: fields[4]))
    }

    /// The cover of the current track as image data, or nil.
    nonisolated static func artwork() -> Data? {
        guard isRunning,
              let out = OsaScript.run(#"tell application "Music" to return raw data of artwork 1 of current track"#)
        else { return nil }
        return OsaScript.decodeData(out)
    }

    nonisolated private static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    /// The parts of Music's notification this app uses.
    private struct Info: Sendable {
        let state: String?, name: String?, artist: String, album: String, persistentID: Int64?
        init(_ info: [AnyHashable: Any]) {
            state = info["Player State"] as? String
            name = info["Name"] as? String
            artist = info["Artist"] as? String ?? ""
            album = info["Album"] as? String ?? ""
            persistentID = (info["PersistentID"] as? NSNumber)?.int64Value
        }
    }

    private func received(_ info: Info) {
        let state: State = switch info.state {
        case "Playing": .playing
        case "Paused": .paused
        default: .stopped
        }
        guard state != .stopped, let name = info.name else {
            return update(Now(state: .stopped, track: nil))
        }
        // The notification's PersistentID is a number; AppleScript's is the
        // same value as 16 hex digits. One form, so a launch-time query and a
        // later notification agree on what is already on the screen.
        let id = info.persistentID.map { String(format: "%016llX", $0) } ?? "\(name)|\(info.artist)"
        update(Now(state: state, track: Screens.Track(id: id, name: name, artist: info.artist, album: info.album)))
    }

    private func update(_ value: Now) {
        guard value != now else { return }
        now = value
        onChange?(value)
    }
}
