import Foundation

/// Key and mouse lighting, ported from razerlight.py.
///
/// At rest everything sits at a dim, faintly cool white. While DuoChart plays
/// it sends the cover's path, the beat phase and whether star power is running
/// over UDP 52737; the album is painted one pixel per key, breathing on the
/// beat and washing to blue during a boost. While the displays sleep, or when
/// switched off from the menu, everything goes dark.
final class LightingEngine: @unchecked Sendable {
    struct Target {
        let role: DeviceHub.Role
        let cols: Int, rows: Int
        let period: Double             // seconds between writes
        // The mouse's frames cross the 2.4 GHz link its movement shares, so it
        // is written at half the keyboard's rate.
        var lastWrite = 0.0
        var lastFrame: [[UInt8]]?
    }

    static let rest: RGB = (0.22, 0.22, 0.24)       // dim white, a touch cool so it is not yellow
    static let boost: RGB = (0.10, 0.45, 1.00)      // the star power blue off the highway
    static let pulseDepth = 0.30
    static let ease = 0.18
    static let fps = 30.0
    static let idleAfter = 2.0
    /// An unchanged frame is still resent this often. These devices lose what
    /// they were showing (sleep, a radio drop, anything else talking to them)
    /// while the handle stays valid, and frame writes are never acknowledged,
    /// so nothing else would ever notice.
    static let refresh = 4.0
    static let port: UInt16 = 52737

    private let hub: DeviceHub
    private let queue = DispatchQueue(label: "com.deoxylabs.peripherals.lighting", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var socket: Int32 = -1
    private var socketRetry = 0.0
    private var targets = [
        Target(role: .mouse, cols: 13, rows: 1, period: 1 / 15),
        // 18 columns, not the 16 razerlight borrowed from OpenRazer's entry for
        // a neighbouring model: the firmware's own matrix query (0x0F/0x80)
        // answers 6 rows by 0x12, and columns 16-17 are the nav keys on the
        // right edge, which stayed dark until this was fixed.
        Target(role: .keyboard, cols: 18, rows: 6, period: 1 / 30),
    ]
    private var art: String?
    private var beat = 0.0
    private var boost = 0.0
    private var heard = 0.0
    private var level = 0.0                          // how far into "a song is playing" we are
    private var dark = false
    private var brightnessLevel = 1.0          // the menu's slider
    private var wasDark = false

    init(hub: DeviceHub) {
        self.hub = hub
    }

    func start() {
        queue.async { [self] in
            openSocket()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1 / Self.fps, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Dark while the displays sleep or the lights are switched off.
    func setDark(_ value: Bool) {
        queue.async { [self] in dark = value }
    }

    /// The overall brightness, 0...1, kept separate from the colours so a
    /// dimmed keyboard still breathes on the beat.
    func setBrightness(_ value: Double) {
        queue.async { [self] in
            brightnessLevel = max(0, min(1, value))
            guard !dark else { return }
            for target in targets { hub.send(target.role, brightness(brightnessLevel)) }
        }
    }

    /// A device that just came back shows whatever effect it stores itself.
    func deviceAppeared(_ role: DeviceHub.Role) {
        queue.async { [self] in
            guard let i = targets.firstIndex(where: { $0.role == role }) else { return }
            hub.send(role, RazerReport.make(0x0F, 0x02, [0x00, 0x00, 0x08], size: 0x0C))   // custom frame mode
            hub.send(role, brightness(dark ? 0 : brightnessLevel))
            targets[i].lastFrame = nil
        }
    }

    /// Dim white, for quitting: the lights shouldn't freeze on a song.
    func restAndStop() {
        queue.sync { [self] in
            timer?.cancel()
            for i in targets.indices {
                hub.send(targets[i].role, brightness(0.6))
                targets[i].lastFrame = nil
                targets[i].lastWrite = 0
                paint(&targets[i], flat(Self.rest, targets[i]))
            }
        }
    }

    // MARK: - The loop

    private func tick() {
        receive()
        let now = Date().timeIntervalSince1970

        if dark != wasDark {
            wasDark = dark
            for i in targets.indices {
                hub.send(targets[i].role, brightness(dark ? 0 : brightnessLevel))
                targets[i].lastFrame = nil
                targets[i].lastWrite = 0
            }
            Log.lighting.notice("\(self.dark ? "dark" : "lit", privacy: .public)")
        }
        if dark {
            for i in targets.indices { paint(&targets[i], flat((0, 0, 0), targets[i])) }
            return
        }

        let playing = art != nil && now - heard < Self.idleAfter
        level += ((playing ? 1 : 0) - level) * Self.ease

        for i in targets.indices {
            let target = targets[i]
            guard level >= 0.02, let path = art,
                  let cover = ArtworkGrid.grid(path: path, cols: target.cols, rows: target.rows) else {
                paint(&targets[i], flat(Self.rest, target))
                continue
            }
            // A raised cosine: the swell lands on the beat and falls away
            // gently, which reads as breathing rather than blinking.
            let swell = 0.5 + 0.5 * cos(2 * Double.pi * beat)
            let gain = 1 - Self.pulseDepth + Self.pulseDepth * swell
            let grid = cover.map { row in
                row.map { pixel -> RGB in
                    let colour = mix(pixel, Self.boost, boost * 0.85)
                    return mix(Self.rest, (colour.r * gain, colour.g * gain, colour.b * gain), level)
                }
            }
            paint(&targets[i], grid)
        }
    }

    /// One frame, row by row, at this device's own pace. Quantised to the
    /// bytes the device stores before deciding anything changed: a smooth fade
    /// produces new floats every frame and identical bytes most of the time.
    private func paint(_ target: inout Target, _ grid: [[RGB]]) {
        guard hub.device(target.role) != nil else { return }
        let now = Date().timeIntervalSince1970
        guard now - target.lastWrite >= target.period else { return }
        let frame: [[UInt8]] = (0..<target.rows).map { y in
            let source = grid[y * grid.count / target.rows]
            return (0..<target.cols).flatMap { x -> [UInt8] in
                let c = source[x * source.count / target.cols]
                return [c.r, c.g, c.b].map { UInt8(max(0, min(255, Int($0 * 255)))) }
            }
        }
        if frame == target.lastFrame, now - target.lastWrite < Self.refresh { return }
        target.lastFrame = frame
        target.lastWrite = now
        for (y, rgb) in frame.enumerated() {
            hub.send(target.role, RazerReport.make(0x0F, 0x03, [0, 0, UInt8(y), 0, UInt8(target.cols - 1)] + rgb, size: 0x47))
        }
    }

    private func brightness(_ level: Double) -> [UInt8] {
        RazerReport.make(0x0F, 0x04, [0x01, 0x00, UInt8(level * 255)], size: 3)
    }

    private func flat(_ colour: RGB, _ target: Target) -> [[RGB]] {
        Array(repeating: Array(repeating: colour, count: target.cols), count: target.rows)
    }

    private func mix(_ a: RGB, _ b: RGB, _ amount: Double) -> RGB {
        (a.r + (b.r - a.r) * amount, a.g + (b.g - a.g) * amount, a.b + (b.b - a.b) * amount)
    }

    // MARK: - DuoChart

    /// Retried from the loop until it works: at first launch the Python
    /// prototype may still be letting go of the port.
    private func openSocket() {
        socketRetry = Date().timeIntervalSince1970 + 2
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Log.lighting.error("UDP \(Self.port) bind failed: \(errno)")
            close(socket)
            socket = -1
            return
        }
        _ = fcntl(socket, F_SETFL, O_NONBLOCK)
    }

    /// Only the newest state matters; a backlog would light the song late.
    private func receive() {
        if socket < 0 {
            guard Date().timeIntervalSince1970 >= socketRetry else { return }
            openSocket()
            if socket < 0 { return }
        }
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = recv(socket, &buffer, buffer.count, 0)
            guard n > 0 else { return }
            guard let message = try? JSONSerialization.jsonObject(with: Data(buffer[0..<n])) as? [String: Any]
            else { continue }
            let path = message["art"] as? String ?? ""
            art = !path.isEmpty && FileManager.default.fileExists(atPath: path) ? path : nil
            beat = (message["beat"] as? NSNumber)?.doubleValue ?? 0
            boost = max(0, min(1, (message["boost"] as? NSNumber)?.doubleValue ?? 0))
            heard = Date().timeIntervalSince1970
        }
    }
}
