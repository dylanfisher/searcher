import Base
import Darwin
import Foundation
import NetFS

/// Mounts a share with `NetFSMountURLAsync`, where the system mounts shares: no mount path, so it
/// makes the folder in `/Volumes` and names it. The system shows its sign-in window only when the
/// session and the keychain don't cover the share (`AllowUI`); `NoUI` would fail with nothing the
/// user can answer. No file-system call is made, so a hung share can't hold it
/// (docs/decisions/0115-server-shares.md, docs/decisions/0038-slow-volumes.md).
public struct NetFSShareMounter: ShareMounter {
    /// Where NetFS runs each completion, one at a time.
    private let queue = DispatchQueue(label: "NetFSShareMounter")

    public init() {}

    public func start(
        _ request: ShareMountRequest,
        completion: @escaping @Sendable (_ status: Int32, _ mountPoints: [String]) -> Void
    ) -> ShareMountStart {
        BlockingCallThread.requireCurrent()
        guard let url = URL(string: request.url) else { return .failed(EINVAL) }
        // NetFS.h's `kNAUIOptionKey` and `kNAUIOptionAllowUI`, macros Swift doesn't import. The
        // dictionaries aren't `Sendable`, so they are made here, on the thread that makes the call.
        let openOptions = NSMutableDictionary(dictionary: ["UIOption": "AllowUI"])
        let mountOptions = NSMutableDictionary()
        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(
            url as CFURL, nil, nil, nil, openOptions as CFMutableDictionary,
            mountOptions as CFMutableDictionary, &requestID, queue
        ) { status, _, mountPoints in
            completion(status, (mountPoints as? [String]) ?? [])
        }
        guard status == 0 else { return .failed(status) }
        guard let requestID else {
            preconditionFailure("NetFSMountURLAsync started \(request.url) with no request ID")
        }
        return .started(ShareMountHandle(id: UInt(bitPattern: requestID)))
    }

    public func cancel(_ handle: ShareMountHandle) {
        BlockingCallThread.requireCurrent()
        guard let requestID = UnsafeMutableRawPointer(bitPattern: handle.id) else {
            preconditionFailure("a mount's handle \(handle.id) is no request ID")
        }
        // A request that already ended answers with an error; there is nothing left to cancel.
        _ = NetFSMountURLCancel(requestID)
    }
}
