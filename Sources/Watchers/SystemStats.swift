import Foundation

/// CPU and memory percentages, worked out the way psutil does on macOS so the
/// numbers match what the Python prototype showed.
final class SystemStats {
    private var previous: [UInt32]?

    /// Busy share of all cores since the last call.
    func cpuPercent() -> Int {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var processors: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processors, &info, &count) == KERN_SUCCESS,
              let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * 4) }
        let ticks = (0..<Int(count)).map { UInt32(bitPattern: info[$0]) }
        defer { previous = ticks }
        guard let previous, previous.count == ticks.count else { return 0 }

        var busy: UInt64 = 0, total: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(processors) {
            for state in 0..<states {
                let delta = UInt64(ticks[cpu * states + state] &- previous[cpu * states + state])
                total += delta
                if state != Int(CPU_STATE_IDLE) { busy += delta }
            }
        }
        return total == 0 ? 0 : Int((Double(busy) / Double(total) * 100).rounded())
    }

    /// (total - available) / total, where available is free plus inactive.
    func memoryPercent() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(getpagesize())
        let total = ProcessInfo.processInfo.physicalMemory
        let available = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * page
        return Int((Double(total - min(total, available)) / Double(total) * 100).rounded())
    }
}

