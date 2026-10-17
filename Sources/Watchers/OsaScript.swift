import Darwin
import Foundation

/// Runs AppleScript through /usr/bin/osascript, as its own responsible process.
///
/// On a Mac booted with AMFI relaxed (amfi_get_out_of_my_way=1) every binary
/// is a platform binary, and TCC won't prompt for a platform binary that isn't
/// Apple-signed: Peripherals itself can never be asked for Automation access,
/// so NSAppleScript only ever gets -1743. osascript is Apple-signed. Spawned
/// with responsibility disclaimed, TCC judges it rather than us, and it can
/// prompt (once) and be allowed to talk to Music. On a stock Mac this costs
/// nothing and works the same.
enum OsaScript {
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let disclaim: Disclaim? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        else { return nil }
        return unsafeBitCast(symbol, to: Disclaim.self)
    }()

    /// The script's stdout, trimmed, or nil if it failed.
    static func run(_ source: String, timeout: TimeInterval = 10) -> String? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        _ = disclaim?(&attributes, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var output: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { return nil }
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, output[0])

        var pid: pid_t = 0
        let arguments = ["/usr/bin/osascript", "-e", source]
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let spawned = posix_spawn(&pid, arguments[0], &actions, &attributes, &argv, environ)
        close(output[1])
        guard spawned == 0 else { close(output[0]); return nil }

        let reader = FileHandle(fileDescriptor: output[0], closeOnDealloc: true)
        let deadline = Date() + timeout
        var data = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if Date() > deadline { kill(pid, SIGKILL); break }
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        guard status == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// AppleScript prints raw data as «data tdtaHEX»; tdta is the type code.
    static func decodeData(_ text: String) -> Data? {
        guard let start = text.range(of: "«data ") else { return nil }
        var hex = text[start.upperBound...].dropFirst(4)
        if hex.hasSuffix("»") { hex = hex.dropLast() }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
