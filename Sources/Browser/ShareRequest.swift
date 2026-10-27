import Foundation

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

    /// `[user@]host`, the part of a URL to the server that `smbutil` and a mount both take: the
    /// user percent-encoded once for a URL's user part, `;` kept and `:` encoded, which `smbutil`
    /// reads as the start of a password; the host as its share's source writes it, not passed
    /// through `URLComponents`, which checks it as a URL host and refuses a Bonjour name's
    /// `\032`; an IPv6 address in brackets (docs/decisions/0115-server-shares.md).
    public var urlAuthority: String {
        var authority = ""
        if let user {
            let allowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":"))
            guard let encoded = user.addingPercentEncoding(withAllowedCharacters: allowed) else {
                preconditionFailure("the user \(user) has no percent-encoding")
            }
            authority = encoded + "@"
        }
        let host = server.host
        // Only an IPv6 address holds a `:` (`Server.init(host:)`); it needs its brackets back.
        return authority + (host.contains(":") ? "[\(host)]" : host)
    }
}
