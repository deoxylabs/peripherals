import Foundation
import IOKit.hid
import os

/// The three HID interfaces this app talks to, opened shared and reopened
/// whenever they come back.
///
/// Shared matters most for the mouse. Its control interface is interface 0,
/// the pointer itself, and an exclusive open takes the movement reports away
/// from the window server: the cursor stops dead. razerlight learnt that with
/// two frozen cursors.
final class DeviceHub: @unchecked Sendable {
    enum Role: String, CaseIterable, Sendable {
        case keyboard        // BlackWidow V4 Pro 75%, interface 3: lighting and OLED settings
        case oled            // the same keyboard, interface 5: image uploads and their acks
        case mouse           // Basilisk V3 Pro over its HyperSpeed dongle, interface 0

        var product: Int { self == .mouse ? 0x00AB : 0x02B3 }
        var interface: Int { switch self { case .keyboard: 3; case .oled: 5; case .mouse: 0 } }
    }

    static let vendor = 0x1532

    /// Called on the HID thread whenever a role appears or goes away.
    var onChange: (@Sendable (Role, Bool) -> Void)?
    /// Input reports from the OLED interface, on the HID thread.
    var onOledInput: (@Sendable ([UInt8]) -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let lock = NSLock()
    private var devices: [Role: IOHIDDevice] = [:]
    /// Matched but not yet openable: usually waiting on Input Monitoring.
    private var pending: [IOHIDDevice] = []
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    func start() {
        let matching = [Role.keyboard.product, Role.mouse.product].map {
            [kIOHIDVendorIDKey: Self.vendor, kIOHIDProductIDKey: $0] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<DeviceHub>.fromOpaque(context!).takeUnretainedValue().matched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<DeviceHub>.fromOpaque(context!).takeUnretainedValue().removed(device)
        }, context)
        // A run loop rather than a dispatch queue: on a queue, devices arrive
        // already activated and registering an input callback then traps.
        let thread = Thread { [manager, self] in
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            // Devices that couldn't be opened are tried again, so granting
            // Input Monitoring takes effect without a restart.
            let retry = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 3, 3, 0, 0) { _ in
                let waiting = self.lock.withLock { () -> [IOHIDDevice] in
                    defer { self.pending.removeAll() }
                    return self.pending
                }
                waiting.forEach { self.matched($0, asking: false) }
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), retry, .defaultMode)
            CFRunLoopRun()
        }
        thread.name = "com.deoxylabs.peripherals.hid"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func device(_ role: Role) -> IOHIDDevice? {
        lock.withLock { devices[role] }
    }

    var connected: Set<Role> {
        lock.withLock { Set(devices.keys) }
    }

    /// A 90-byte Razer report to a control interface. Fire and forget: frame
    /// writes on this family are never acknowledged anyway.
    @discardableResult
    func send(_ role: Role, _ report: [UInt8]) -> Bool {
        guard let device = device(role) else { return false }
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, $0.count)
        }
        if result != kIOReturnSuccess {
            Log.hid.error("\(role.rawValue, privacy: .public): feature report failed \(String(result, radix: 16), privacy: .public)")
        }
        return result == kIOReturnSuccess
    }

    /// A Razer command that answers: send it, then read the reply back. The
    /// device keeps one reply buffer, and lighting frames written meanwhile
    /// land in it too, so a reply only counts if it's for this command.
    func query(_ role: Role, _ commandClass: UInt8, _ id: UInt8, _ args: [UInt8] = [], size: UInt8) -> [UInt8]? {
        guard let device = device(role) else { return nil }
        for _ in 0..<5 {
            guard send(role, RazerReport.make(commandClass, id, args, size: size)) else { return nil }
            usleep(15_000)
            var reply = [UInt8](repeating: 0, count: 90)
            var length = reply.count
            let result = reply.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, &length)
            }
            // Status 2 is a good answer; the arguments start at byte 8.
            if result == kIOReturnSuccess, length >= 90, reply[6] == commandClass, reply[7] == id, reply[0] == 2 {
                return Array(reply[8..<88])
            }
        }
        return nil
    }

    /// A 64-byte output report to the OLED interface.
    func sendOutput(_ packet: [UInt8]) -> Bool {
        guard let device = device(.oled) else { return false }
        return packet.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        } == kIOReturnSuccess
    }

    // MARK: - Matching

    private func matched(_ device: IOHIDDevice, asking: Bool = true) {
        guard let role = role(of: device) else { return }
        if lock.withLock({ devices[role] != nil }) { return }

        var result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnNotPermitted, asking {
            // A keyboard interface wants Input Monitoring. Ask once, then retry.
            Log.hid.notice("\(role.rawValue, privacy: .public): asking for Input Monitoring")
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard result == kIOReturnSuccess else {
            if asking {
                Log.hid.error("\(role.rawValue, privacy: .public): open failed \(String(result, radix: 16), privacy: .public), will retry")
            }
            lock.withLock { pending.append(device) }
            return
        }
        if role == .oled {
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, { context, _, _, _, _, report, length in
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                Unmanaged<DeviceHub>.fromOpaque(context!).takeUnretainedValue().onOledInput?(bytes)
            }, context)
        }
        lock.withLock { devices[role] = device }
        Log.hid.notice("\(role.rawValue, privacy: .public): connected")
        onChange?(role, true)
    }

    private func removed(_ device: IOHIDDevice) {
        let gone = lock.withLock { () -> [Role] in
            pending.removeAll { $0 === device }
            let roles = devices.filter { $0.value === device }.map(\.key)
            roles.forEach { devices[$0] = nil }
            return roles
        }
        for role in gone {
            Log.hid.notice("\(role.rawValue, privacy: .public): gone")
            onChange?(role, false)
        }
    }

    /// Which of our roles a matched device is, by product and USB interface
    /// number. The number lives on the USB interface the HID device hangs off,
    /// which is where hidapi's interface_number comes from too.
    private func role(of device: IOHIDDevice) -> Role? {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
        let service = IOHIDDeviceGetService(device)
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let number = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, "bInterfaceNumber" as CFString, kCFAllocatorDefault, options) as? Int
        else { return nil }
        return Role.allCases.first { $0.product == product && $0.interface == number }
    }
}

enum Log {
    static let hid = Logger(subsystem: "com.deoxylabs.peripherals", category: "hid")
    static let lighting = Logger(subsystem: "com.deoxylabs.peripherals", category: "lighting")
    static let oled = Logger(subsystem: "com.deoxylabs.peripherals", category: "oled")
    static let app = Logger(subsystem: "com.deoxylabs.peripherals", category: "app")
}
