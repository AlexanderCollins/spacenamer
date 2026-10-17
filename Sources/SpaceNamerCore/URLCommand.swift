import Foundation

/// Commands accepted on the `spacenamer://` URL scheme, for Shortcuts, Raycast, Alfred,
/// shell scripts (`open "spacenamer://go/2"`) and so on.
public enum URLCommand: Equatable, Sendable {
    case jumpToPosition(Int)
    case jumpToName(String)
    case jumpToKey(SpaceKey)
    case next
    case previous
    case back
    case switcher
    case rename(String?)
    case settings

    public static let scheme = "spacenamer"

    /// Accepts both `spacenamer://go/3` and `spacenamer:go?position=3` styles (`jump` works too).
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        var segments = (components.host.map { [$0] } ?? []) + components.path.split(separator: "/").map(String.init)
        if segments.isEmpty, let opaque = url.absoluteString.split(separator: ":", maxSplits: 1).last {
            segments = opaque.split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
        }
        guard let verb = segments.first?.lowercased() else { return nil }
        let argument = segments.dropFirst().first?.removingPercentEncoding
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name.lowercased()] = value }
        }

        switch verb {
        case "jump", "go", "space":
            if let raw = query["position"] ?? query["number"] ?? argument, let position = Int(raw), position > 0 {
                self = .jumpToPosition(position)
            } else if let name = query["name"] ?? argument, !name.isEmpty {
                self = .jumpToName(name)
            } else if let key = query["uuid"] ?? query["id"], !key.isEmpty {
                self = .jumpToKey(key)
            } else {
                return nil
            }
        case "next": self = .next
        case "previous", "prev": self = .previous
        case "back", "last", "toggle": self = .back
        case "switcher", "show", "open": self = .switcher
        case "rename": self = .rename(query["name"] ?? argument)
        case "settings", "preferences": self = .settings
        default: return nil
        }
    }
}
