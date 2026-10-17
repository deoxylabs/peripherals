import Foundation

/// Image uploads over the keyboard's interface 5. Each 64-byte packet is
/// answered with an echo of its command byte and a status: 1 busy, 2 OK,
/// 3 failed, 5 unsupported.
///
/// Blocking by design and only ever called from the OLED queue: an upload is a
/// strict sequence, and the acks arrive on the HID thread, so waiting here
/// never holds up the thing being waited for.
final class OledLink: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case disconnected, noAck(UInt8), status(UInt8, UInt8)
        var description: String {
            switch self {
            case .disconnected: "keyboard not connected"
            case .noAck(let command): "no ack for 0x\(String(command, radix: 16))"
            case .status(let command, let status): "status \(status) for 0x\(String(command, radix: 16))"
            }
        }
    }

    private let hub: DeviceHub
    private let lock = NSLock()
    private var acks: [[UInt8]] = []
    private let arrived = DispatchSemaphore(value: 0)

    init(hub: DeviceHub) {
        self.hub = hub
    }

    /// Wired to DeviceHub.onOledInput.
    func received(_ report: [UInt8]) {
        lock.withLock { acks.append(report) }
        arrived.signal()
    }

    /// One home-screen-style image: a begin packet, then a 0x40-byte header
    /// and the pixels, 60 bytes at a time. The header ends with a plain sum of
    /// the pixel bytes, which the display checks.
    func upload(command: UInt8, index: UInt8, image: GreyImage) throws {
        let pixels = image.packed()
        var header = [UInt8](repeating: 0, count: 0x40)
        header[0...3] = [UInt8(image.width >> 8), UInt8(image.width & 255),
                         UInt8(image.height >> 8), UInt8(image.height & 255)]
        header[60...63] = ArraySlice(bigEndian(pixels.reduce(UInt32(0)) { $0 &+ UInt32($1) }))
        try begin([command, 0, index, 0] + Array(header[0...3]))
        try stream(command: command + 1, data: header + pixels)
    }

    /// An animation: frame count in the begin packet, a 0x200-byte header with
    /// the frame interval and a sum, then the frames back to back.
    func uploadAnimation(slot: UInt8, frames: [GreyImage], intervalMS: Int) throws {
        let body = frames.flatMap { $0.packed() }
        var header = [UInt8](repeating: 0, count: 0x200)
        header[0] = UInt8(frames.count)
        header[2] = UInt8(intervalMS >> 8)
        header[3] = UInt8(intervalMS & 255)
        header[24...27] = ArraySlice(bigEndian(body.reduce(UInt32(0)) { $0 &+ UInt32($1) }))
        try begin([0x04, 0, slot, UInt8(frames.count)])
        try stream(command: 0x05, data: header + body)
    }

    private func begin(_ packet: [UInt8]) throws {
        lock.withLock { acks.removeAll() }
        while arrived.wait(timeout: .now()) == .success {}
        try send(packet)
    }

    private func stream(command: UInt8, data: [UInt8]) throws {
        var sequence = 0
        var offset = 0
        while offset < data.count {
            let chunk = data[offset..<min(offset + 60, data.count)]
            try send([command, UInt8(chunk.count), UInt8(sequence >> 8), UInt8(sequence & 255)] + chunk)
            offset += 60
            sequence += 1
        }
    }

    private func send(_ packet: [UInt8]) throws {
        // 0x30 and 0x31 open a passthrough to the display MCU's bootloader.
        precondition(packet[0] != 0x30 && packet[0] != 0x31)
        let padded = packet + [UInt8](repeating: 0, count: 64 - packet.count)
        guard hub.sendOutput(padded) else { throw Failure.disconnected }
        while true {
            guard arrived.wait(timeout: .now() + 1.0) == .success else { throw Failure.noAck(packet[0]) }
            guard let ack = lock.withLock({ acks.isEmpty ? nil : acks.removeFirst() }) else { continue }
            guard ack.count >= 2, ack[0] == packet[0], ack[1] != 1 else { continue }
            guard ack[1] == 2 else { throw Failure.status(packet[0], ack[1]) }
            return
        }
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
    }
}
