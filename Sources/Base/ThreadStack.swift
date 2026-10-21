import Darwin
import Foundation

/// Captures another thread's call stack: suspends the thread, walks its frame pointers, and
/// resumes it.
///
/// The suspended thread may hold the malloc lock or a Swift runtime lock, so nothing between
/// suspend and resume may allocate, take a lock, or call into generic or runtime code. `walk()`
/// only calls `thread_get_state` and `vm_read_overwrite` and reads and writes buffers allocated
/// in `init`. Debug builds don't optimize that code, so any change to it is checked against the
/// unoptimized object: the calls between `thread_suspend` and `thread_resume` must stay those two.
public final class ThreadStack: @unchecked Sendable {
    /// The most frames one capture returns.
    public static let maximumDepth = 128

    private let thread: thread_act_t
    // Read once here: reading the global `mach_task_self_` in `walk()` is a dynamic exclusivity
    // check in debug builds, which uses thread-local storage.
    private let task = mach_task_self_
    private let lock = NSLock()
    // Everything below is written only while `lock` is held.
    private let depth = ThreadStack.maximumDepth
    private let frames = UnsafeMutablePointer<UInt>.allocate(capacity: ThreadStack.maximumDepth)
    private let frame = UnsafeMutablePointer<UInt>.allocate(capacity: 2)
    private let frameAddress: vm_address_t
    // Register values are 64-bit; `UInt` avoids a width conversion in `walk()`, which debug builds
    // compile to a checked call.
    private let registers: UnsafeMutablePointer<UInt>
    private let registerWords: Int
    private let state: thread_state_t
    private let stateCount: mach_msg_type_number_t
    private let stateFlavor: thread_state_flavor_t
    private let pcIndex: Int
    private let lrIndex: Int?
    private let fpIndex: Int
    private let addressMask: UInt

    private init(thread: thread_act_t) {
        self.thread = thread
        frameAddress = vm_address_t(UInt(bitPattern: frame))
        #if arch(arm64)
            typealias State = arm_thread_state64_t
            stateFlavor = ARM_THREAD_STATE64
            pcIndex = MemoryLayout<State>.offset(of: \.__pc)! / 8
            lrIndex = MemoryLayout<State>.offset(of: \.__lr)! / 8
            fpIndex = MemoryLayout<State>.offset(of: \.__fp)! / 8
            // Return addresses signed by pointer authentication carry the signature in the high
            // bits; user-space addresses fit in the low 47.
            addressMask = 0x0000_7FFF_FFFF_FFFF
        #elseif arch(x86_64)
            typealias State = x86_thread_state64_t
            stateFlavor = x86_THREAD_STATE64
            pcIndex = MemoryLayout<State>.offset(of: \.__rip)! / 8
            lrIndex = nil
            fpIndex = MemoryLayout<State>.offset(of: \.__rbp)! / 8
            addressMask = .max
        #endif
        registerWords = (MemoryLayout<State>.size + 7) / 8
        registers = UnsafeMutablePointer<UInt>.allocate(capacity: registerWords)
        state = thread_state_t(OpaquePointer(registers))
        stateCount = mach_msg_type_number_t(MemoryLayout<State>.size / MemoryLayout<natural_t>.size)
    }

    /// The calling thread. Holds a reference to the thread's port, so a capture after the thread
    /// exits fails instead of reaching a different thread that reused the port name.
    public static func current() -> ThreadStack {
        ThreadStack(thread: mach_thread_self())
    }

    deinit {
        mach_port_deallocate(mach_task_self_, thread)
        frames.deallocate()
        frame.deallocate()
        registers.deallocate()
    }

    /// Return addresses on the thread, innermost first. The thread is suspended for the walk only,
    /// which takes well under a millisecond.
    ///
    /// - Precondition: called from another thread while the captured thread is still running.
    public func capture() -> [UInt] {
        precondition(
            thread != pthread_mach_thread_np(pthread_self()),
            "a thread cannot capture its own stack")
        lock.lock()
        defer { lock.unlock() }
        let suspended = thread_suspend(thread)
        precondition(suspended == KERN_SUCCESS, "thread_suspend failed: \(suspended)")
        let (count, stateResult) = walk()
        let resumed = thread_resume(thread)
        precondition(resumed == KERN_SUCCESS, "thread_resume failed: \(resumed)")
        precondition(stateResult == KERN_SUCCESS, "thread_get_state failed: \(stateResult)")
        return Array(UnsafeBufferPointer(start: frames, count: count))
    }

    /// Runs while the thread is suspended: fills `frames` from its registers and frame chain.
    private func walk() -> (count: Int, stateResult: kern_return_t) {
        var count = stateCount
        let stateResult = thread_get_state(thread, stateFlavor, state, &count)
        if stateResult != KERN_SUCCESS { return (0, stateResult) }
        var filled = 0
        frames[filled] = registers[pcIndex] & addressMask
        filled += 1
        // A leaf function may not have stored its return address in a frame yet.
        if let lrIndex {
            frames[filled] = registers[lrIndex] & addressMask
            filled += 1
        }
        // Each frame starts with the caller's frame pointer, then the return address. The stack
        // grows down, so a caller's frame is always at a higher address.
        var framePointer = registers[fpIndex]
        while filled < depth, framePointer != 0, framePointer % 8 == 0 {
            // vm_read_overwrite rather than a plain load: a bad frame pointer fails the call
            // instead of crashing the process.
            var size: vm_size_t = 0
            let read = vm_read_overwrite(
                task, framePointer, 16, frameAddress, &size)
            let next = frame[0]
            let returnAddress = frame[1]
            if read != KERN_SUCCESS || returnAddress == 0 { break }
            frames[filled] = returnAddress & addressMask
            filled += 1
            if next <= framePointer { break }
            framePointer = next
        }
        return (filled, KERN_SUCCESS)
    }
}
