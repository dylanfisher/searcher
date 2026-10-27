/// Whose list of a server's shares to ask for. A `Server` is its host alone, so two users on one
/// host are one server, and the list is the one the user sees (docs/decisions/0115-server-shares.md).
public struct ShareRequest: Hashable, Sendable {
    /// The server, its host as its first SMB share's source writes it.
    public let server: Server
    /// The user, percent-decoded, a `DOMAIN;user` kept whole; nil asks with none.
    public let user: String?

    public init(server: Server, user: String?) {
        self.server = server
        self.user = user
    }

    /// The request for `server`'s shares from the mount table's `volumes`: as the user of the
    /// first SMB share of `server`, in the table's order. Nil when no SMB share of `server` is
    /// mounted, and when that share's source has no share name or a user that doesn't decode,
    /// since its share can't be matched with the list or its user named.
    public init?(server: Server, volumes: [VolumeIdentity]) {
        guard
            let first = volumes.first(where: {
                $0.fsType == VolumeIdentity.smbFSType && $0.server == server
            }),
            let firstServer = first.server, first.share != nil
        else { return nil }
        switch first.sourceUser {
        case .absent: self.init(server: firstServer, user: nil)
        case .named(let user): self.init(server: firstServer, user: user)
        case .undecodable: return nil
        }
    }
}
