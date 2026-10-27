/// Why a server's shares couldn't be listed. Its own type, since `ListingError.reason` has no
/// case for rejected credentials and is switched on exhaustively in many places
/// (docs/decisions/0115-server-shares.md).
public enum ShareListError: Error, Equatable, Sendable {
    /// The server rejected the user's credentials: `smbutil` exited 77.
    case rejected
    /// The server didn't answer within `LoadTimeouts.giveUp`.
    case unreachable
    /// The tool failed another way, with the first line it wrote to stderr.
    case failed(String)
    /// The tool's output wasn't in the shape it is parsed in.
    case unparsable
    /// The tool isn't installed where it is run from.
    case toolMissing
}
