import Foundation

/// Web v seznamu: doména včetně subdomén (`youtube.com` platí i pro `m.youtube.com`), volitelně jen
/// část webu (`youtube.com/shorts`). Zápis je tolerantní – vložená adresa `https://www.youtube.com/shorts/…`
/// se zkrátí na `youtube.com/shorts/…`.
public struct SiteRule: Hashable, Sendable {
    /// Doména bez `www.`, malými písmeny.
    public let host: String
    /// Cesta bez lomítka na konci (`/shorts`), nebo prázdná = celý web.
    public let path: String

    public init?(_ entry: String) {
        var s = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where s.hasPrefix(scheme) { s.removeFirst(scheme.count) }
        if s.hasPrefix("*.") { s.removeFirst(2) }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        var path = ""
        if let slash = s.firstIndex(of: "/") {
            path = String(s[slash...])
            s = String(s[..<slash])
        }
        while path.hasSuffix("/") { path.removeLast() }
        let host = Self.normalize(host: s)
        guard host.contains("."), host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              !host.hasPrefix("."), !host.contains("..") else { return nil }
        self.host = host
        self.path = path
    }

    /// Zápis pro seznam a zobrazení (`youtube.com/shorts`).
    public var text: String { host + path }

    /// Patří adresa pod pravidlo? `host` a `path` jsou z navštívené adresy (cesta bez dotazu).
    public func matches(host visited: String, path visitedPath: String = "") -> Bool {
        let h = Self.normalize(host: visited)
        guard h == host || h.hasSuffix("." + host) else { return false }
        guard !path.isEmpty else { return true }
        let p = visitedPath.lowercased()
        return p == path || p.hasPrefix(path + "/")
    }

    /// Malá písmena, bez portu, tečky na konci a úvodního `www.`.
    public static func normalize(host: String) -> String {
        var h = host.lowercased()
        if let colon = h.lastIndex(of: ":"), h[h.index(after: colon)...].allSatisfy(\.isNumber) { h = String(h[..<colon]) }
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// Doména a cesta navštívené adresy (jen http a https).
    public static func target(of url: URL) -> (host: String, path: String)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return (normalize(host: host), url.path(percentEncoded: false))
    }
}
