import Foundation

/// Razer's 90-byte feature report: a header, the command, its arguments and an
/// XOR checksum. Every Razer device here speaks it on its control interface.
enum RazerReport {
    static let transaction: UInt8 = 0x1F

    static func make(_ commandClass: UInt8, _ id: UInt8, _ args: [UInt8], size: UInt8? = nil) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 90)
        body[1] = transaction
        body[5] = size ?? UInt8(min(args.count, 80))
        body[6] = commandClass
        body[7] = id
        for (i, byte) in args.prefix(80).enumerated() {
            body[8 + i] = byte
        }
        body[88] = body[2..<88].reduce(0, ^)
        return body
    }
}
