import Foundation

/// Claude Code keeps a file per running session in ~/.claude/sessions (`<pid>.json`) with
/// what it's doing: busy, waiting on the user (and why), or idle. Reading those follows
/// every session, including ones started before the plugin was installed, and sees a
/// `/rename` the moment it happens.
public enum ClaudeSessionFiles {
    public struct Record: Decodable, Equatable, Sendable {
        public var pid: Int32
        public var sessionID: String?
        public var cwd: String?
        public var name: String?
        /// "user" for a name the user gave the chat; "derived" for a placeholder.
        public var nameSource: String?
        /// "busy", "waiting", "idle", or "shell" (finished, with background shells running).
        public var status: String?
        public var waitingFor: String?
        /// Milliseconds since 1970.
        public var statusUpdatedAt: Double?

        enum CodingKeys: String, CodingKey {
            case pid
            case sessionID = "sessionId"
            case cwd, name, nameSource, status, waitingFor, statusUpdatedAt
        }

        /// A name the user gave the chat.
        public var customName: String? {
            guard nameSource == "user", let name, !name.isEmpty else { return nil }
            return name
        }
    }

    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// Every session file that parses.
    public static func read(from folder: URL = folder) -> [Record] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        }
    }

    /// The report a session's status stands for, given the state it was last seen in.
    /// Idle after working or waiting means it finished; idle otherwise says nothing new.
    public static func report(for record: Record, previous: AgentState?) -> AgentReport {
        var report = AgentReport(
            event: .query,
            source: "claude-code",
            session: record.sessionID,
            processes: [AgentProcess(pid: record.pid, name: "claude")],
            title: record.customName,
            time: (record.statusUpdatedAt ?? Date().timeIntervalSince1970 * 1000) / 1000
        )
        switch record.status {
        case "busy":
            report.event = .working
        case "waiting" where record.waitingFor != "dialog open":
            report.event = .needsInput
            report.note = describe(waitingFor: record.waitingFor)
        case "idle", "shell", "waiting":
            if previous == .working || previous == .needsInput { report.event = .done }
        default:
            break
        }
        return report
    }

    private static func describe(waitingFor reason: String?) -> String? {
        switch reason {
        case nil: return nil
        case "input needed": return "Needs your input"
        case "goal proposal": return "Has a goal to approve"
        case "sandbox request": return "Wants to leave the sandbox"
        case "worker request": return "A worker needs approval"
        case let reason?: return reason.prefix(1).uppercased() + reason.dropFirst()
        }
    }
}
