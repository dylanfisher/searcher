import Foundation

/// A share of a server to mount, as the user of the server's first mounted SMB share
/// (`ShareRequest`). Two requests are one mount when their server, user and share key
/// (`ShareNames.key`) are equal (docs/decisions/0115-server-shares.md).
public struct ShareMountRequest: Hashable, Sendable {
    /// The server and the user to mount as.
    public let share: ShareRequest
    /// The share's name, as the server listed it.
    public let name: String

    public init(share: ShareRequest, name: String) {
        self.share = share
        self.name = name
    }

    /// The URL to mount: `smb://[user@]host/<share>`, the authority as `ShareRequest.urlAuthority`
    /// writes it and the share percent-encoded as one path component.
    public var url: String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else {
            preconditionFailure("the share \(name) has no percent-encoding")
        }
        return "smb://\(share.urlAuthority)/\(encoded)"
    }

    public static func == (lhs: ShareMountRequest, rhs: ShareMountRequest) -> Bool {
        lhs.share == rhs.share && ShareNames.key(lhs.name) == ShareNames.key(rhs.name)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(share)
        hasher.combine(ShareNames.key(name))
    }
}

/// One mount a `ShareMounter` started, to cancel it by.
public struct ShareMountHandle: Hashable, Sendable {
    /// NetFS's request ID as its bits, or a fake's number.
    public let id: UInt

    public init(id: UInt) {
        self.id = id
    }
}

/// How `ShareMounter.start` returned.
public enum ShareMountStart: Equatable, Sendable {
    /// The mount runs; its completion runs once unless it is cancelled first.
    case started(ShareMountHandle)
    /// It failed at once with this status, and its completion never runs.
    case failed(Int32)
}

/// Mounts a share, shaped like NetFS's `NetFSMountURLAsync`. `ShareMounts` runs one; tests pass a
/// gated one that mounts nothing.
public protocol ShareMounter: Sendable {
    /// Starts mounting `request`. `completion` runs once, on a queue of the mounter's, with the
    /// status (0, an `errno` above 0, an `OSStatus` below) and the mount points, unless
    /// `cancel` is called first or this returns `.failed`. It can block, so it is called on a
    /// `BlockingCallThread`.
    func start(
        _ request: ShareMountRequest,
        completion: @escaping @Sendable (_ status: Int32, _ mountPoints: [String]) -> Void
    ) -> ShareMountStart
    /// Cancels the mount `handle` names; its completion never runs after. Called on a
    /// `BlockingCallThread`.
    func cancel(_ handle: ShareMountHandle)
}
