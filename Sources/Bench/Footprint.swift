import Darwin

/// The process's `phys_footprint`, the memory number Activity Monitor and B9 use.
enum Footprint {
    static func current() throws -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { throw Unreadable(code: errno) }
        return usage.ri_phys_footprint
    }

    struct Unreadable: Error, CustomStringConvertible {
        let code: Int32
        var description: String {
            "proc_pid_rusage failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}
