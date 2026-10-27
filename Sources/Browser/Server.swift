import Foundation

/// A host whose shares are mounted, read from a share's mount source (`f_mntfromname`) with no
/// read of the share or the network. Two servers are equal when their hosts are, without case,
/// so shares mounted by different users from one host are one server.
public struct Server: Hashable, Sendable {
    /// The folder the system mounts shares in. A server's shares are the folders it has here.
    public static let sharesFolder = Location(path: "/Volumes")

    /// The host as the mount source writes it, without a user, port or IPv6 brackets.
    public let host: String
    /// The name to show: the Bonjour instance name for a host such as
    /// `HAL9000._smb._tcp.local`, with its escapes undone, and the host as written otherwise.
    public let name: String

    /// The server named in `mountSource`: `//[user@]host[:port]/share` (SMB, AFP),
    /// `scheme://[user@]host[:port]/…` (WebDAV) or `host:/path` (NFS). Nil for a source in none
    /// of these forms, such as a local disk's `/dev/disk3s1`, and for a Bonjour name whose
    /// escapes don't decode.
    public init?(mountSource: String) {
        guard let host = Self.host(inMountSource: mountSource),
            let name = Self.name(ofHost: host)
        else { return nil }
        self.host = host
        self.name = name
    }

    public static func == (lhs: Server, rhs: Server) -> Bool {
        lhs.host.lowercased() == rhs.host.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(host.lowercased())
    }

    private static func host(inMountSource source: String) -> String? {
        if source.hasPrefix("//") {
            return host(inURLRest: source.dropFirst(2), needsPath: true)
        }
        if let schemeEnd = source.range(of: "://") {
            let scheme = source[..<schemeEnd.lowerBound]
            guard let first = scheme.first, first.isASCII, first.isLetter,
                scheme.allSatisfy({
                    $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0))
                })
            else { return nil }
            return host(inURLRest: source[schemeEnd.upperBound...], needsPath: false)
        }
        return host(inNFSSource: Substring(source))
    }

    /// The host in `[user@]host[:port]/…`, the part of a URL after its `//`. An SMB or AFP
    /// source names a share after the host, so `needsPath` asks for one.
    private static func host(inURLRest rest: Substring, needsPath: Bool) -> String? {
        let slash = rest.firstIndex(of: "/")
        if needsPath {
            guard let slash, rest.index(after: slash) < rest.endIndex else { return nil }
        }
        var authority = rest[..<(slash ?? rest.endIndex)]
        // A user's own `@` is percent-encoded, so the last `@` ends the user.
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let after = authority[authority.index(after: close)...]
            guard after.isEmpty || isPort(after) else { return nil }
            return nonEmpty(authority[authority.index(after: authority.startIndex)..<close])
        }
        if let colon = authority.firstIndex(of: ":") {
            guard isPort(authority[colon...]) else { return nil }
            authority = authority[..<colon]
        }
        return nonEmpty(authority)
    }

    /// The host in NFS's `host:/path`, or `[address]:/path` for an IPv6 address.
    private static func host(inNFSSource source: Substring) -> String? {
        if source.hasPrefix("[") {
            guard let close = source.firstIndex(of: "]"),
                source[source.index(after: close)...].hasPrefix(":/")
            else { return nil }
            return nonEmpty(source[source.index(after: source.startIndex)..<close])
        }
        guard let separator = source.range(of: ":/") else { return nil }
        let host = source[..<separator.lowerBound]
        guard !host.contains("/"), !host.contains(":"), !host.contains(" ") else { return nil }
        return nonEmpty(host)
    }

    /// Whether `text` is `:` followed by a port number.
    private static func isPort(_ text: Substring) -> Bool {
        text.first == ":" && text.count > 1
            && text.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func nonEmpty(_ text: Substring) -> String? {
        text.isEmpty ? nil : String(text)
    }

    /// The Bonjour instance name of `host` when it has the form
    /// `<instance>._<service>._tcp.<domain>` (or `._udp.`), else `host`. Nil when the instance's
    /// percent, `\DDD` or `\c` escapes don't decode to UTF-8 text.
    private static func name(ofHost host: String) -> String? {
        let labels = escapedLabels(host)
        guard labels.count >= 4, labels[1].hasPrefix("_"), labels[1].count > 1,
            labels[2] == "_tcp" || labels[2] == "_udp", !labels[0].isEmpty
        else { return host }
        guard let instance = labels[0].removingPercentEncoding else { return nil }
        return unescaped(Substring(instance))
    }

    /// `name` split at the dots a backslash doesn't escape, each label still escaped.
    private static func escapedLabels(_ name: String) -> [Substring] {
        var labels: [Substring] = []
        var start = name.startIndex
        var index = name.startIndex
        while index < name.endIndex {
            if name[index] == "\\" {
                index = name.index(after: index)
                if index < name.endIndex { index = name.index(after: index) }
                continue
            }
            if name[index] == "." {
                labels.append(name[start..<index])
                start = name.index(after: index)
            }
            index = name.index(after: index)
        }
        labels.append(name[start...])
        return labels
    }

    /// A DNS-SD label with its escapes undone: `\DDD` is the byte with decimal value DDD, and
    /// `\c` is the character c. Nil for a trailing `\`, a byte above 255, or bytes that aren't
    /// UTF-8.
    private static func unescaped(_ label: Substring) -> String? {
        var bytes: [UInt8] = []
        var characters = label.makeIterator()
        while let character = characters.next() {
            guard character == "\\" else {
                bytes.append(contentsOf: character.utf8)
                continue
            }
            guard let escaped = characters.next() else { return nil }
            guard let first = escaped.asciiDigit else {
                bytes.append(contentsOf: escaped.utf8)
                continue
            }
            guard let second = characters.next()?.asciiDigit,
                let third = characters.next()?.asciiDigit
            else { return nil }
            let value = first * 100 + second * 10 + third
            guard value <= 255 else { return nil }
            bytes.append(UInt8(value))
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

extension Character {
    fileprivate var asciiDigit: Int? {
        isASCII ? wholeNumberValue : nil
    }
}
