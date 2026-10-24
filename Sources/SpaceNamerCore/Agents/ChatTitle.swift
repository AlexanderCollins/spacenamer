import Foundation

/// A chat's title from its Claude Code transcript: the name the user gave it (`/rename`),
/// or else the one Claude Code generated. Both are written as records near the end of the
/// transcript, so only its tail is read.
public struct ChatTitle: Equatable, Sendable {
    public var title: String
    /// Given by the user rather than generated.
    public var isCustom: Bool

    public init(title: String, isCustom: Bool) {
        self.title = title
        self.isCustom = isCustom
    }

    /// Longer names don't fit a desktop's label in Mission Control.
    public static let longestDesktopName = 12

    /// What the chat's desktop is called after it: the title if it's short enough, else its
    /// first word if that is; nil if neither is.
    public var desktopName: String? {
        if title.count <= Self.longestDesktopName { return title }
        guard let first = title.split(whereSeparator: \.isWhitespace).first else { return nil }
        let word = String(first).trimmingCharacters(in: CharacterSet(charactersIn: ",:;"))
        return word.isEmpty || word.count > Self.longestDesktopName ? nil : word
    }

    public static func read(transcript url: URL, session: String?) -> ChatTitle? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        for tail in [UInt64(256 << 10), UInt64(4 << 20)] {
            let start = size > tail ? size - tail : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
            if let title = latest(in: data, session: session) { return title }
            if start == 0 { break }
        }
        return nil
    }

    /// The latest custom title in `data` if there is one, else the latest generated one.
    public static func latest(in data: Data, session: String?) -> ChatTitle? {
        var custom: String?
        var generated: String?
        let marker = Data("-title\"".utf8)
        for line in data.split(separator: 0x0A) {
            // Title records are short; test for one before parsing.
            guard line.count < 4096, line.range(of: marker) != nil else { continue }
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let session, let owner = record["sessionId"] as? String, owner != session { continue }
            switch record["type"] as? String {
            case "custom-title": custom = (record["customTitle"] as? String).flatMap(clean) ?? custom
            case "ai-title": generated = (record["aiTitle"] as? String).flatMap(clean) ?? generated
            default: break
            }
        }
        if let custom { return ChatTitle(title: custom, isCustom: true) }
        return generated.map { ChatTitle(title: $0, isCustom: false) }
    }

    private static func clean(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
