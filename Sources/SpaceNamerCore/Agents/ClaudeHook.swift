import Foundation

/// Turns Claude Code hook input (the JSON on a hook command's stdin) into reports, and
/// the app's reply into hook output. See the plugin's hooks/hooks.json for which hooks run.
public enum ClaudeHook {
    public struct Input: Decodable, Equatable {
        public var hookEventName: String
        public var sessionID: String?
        public var transcriptPath: String?
        public var source: String?
        public var sessionTitle: String?
        public var toolName: String?
        public var notificationType: String?
        public var message: String?
        public var error: String?

        enum CodingKeys: String, CodingKey {
            case hookEventName = "hook_event_name"
            case sessionID = "session_id"
            case transcriptPath = "transcript_path"
            case source
            case sessionTitle = "session_title"
            case toolName = "tool_name"
            case notificationType = "notification_type"
            case message
            case error
        }
    }

    /// Notifications that mean Claude is waiting on the user. (`idle_prompt`, a reminder
    /// that it's waiting for the next prompt, isn't one: a finished turn stays "done".)
    private static let waitingNotifications: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]

    /// The report for a hook, or nil for hooks that don't change anything.
    public static func report(for input: Input, processes: [AgentProcess], time: Double = Date().timeIntervalSince1970) -> AgentReport? {
        var report = AgentReport(
            event: .working,
            source: "claude-code",
            session: input.sessionID,
            processes: processes,
            transcript: input.transcriptPath,
            title: input.sessionTitle.flatMap { $0.isEmpty ? nil : $0 },
            time: time
        )
        switch input.hookEventName {
        case "SessionStart":
            report.event = .started
            report.resumed = input.source == "resume" || input.source == "compact"
        case "UserPromptSubmit":
            report.event = .prompted
        case "PostToolUse", "PostToolUseFailure":
            report.event = .working
        case "PermissionRequest":
            report.event = .needsInput
            report.note = input.toolName.map { "Wants to use \(toolLabel($0))" } ?? "Waiting for permission"
        case "PreToolUse":
            switch input.toolName {
            case "AskUserQuestion":
                report.event = .needsInput
                report.note = "Has a question"
            case "ExitPlanMode":
                report.event = .needsInput
                report.note = "Has a plan to approve"
            default:
                return nil
            }
        case "Notification":
            guard let type = input.notificationType, waitingNotifications.contains(type) else { return nil }
            report.event = .needsInput
            report.note = input.message
        case "Stop":
            report.event = .done
        case "StopFailure":
            report.event = .failed
            report.note = input.error.map { "Stopped: \($0.replacingOccurrences(of: "_", with: " "))" } ?? "Stopped on an error"
        case "SessionEnd":
            report.event = .ended
        default:
            return nil
        }
        return report
    }

    /// What the hook prints: a title for a new chat on a desktop the user named.
    public static func output(for input: Input, reply: AgentReply?) -> Data? {
        // Claude Code takes a title from SessionStart for these sources only, and a chat
        // that already has a name keeps it.
        guard input.hookEventName == "SessionStart", ["startup", "resume", "fork"].contains(input.source ?? ""),
              input.sessionTitle?.isEmpty ?? true,
              let title = reply?.chatTitle, !title.isEmpty
        else { return nil }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "SessionStart", "sessionTitle": title]]
        return try? JSONSerialization.data(withJSONObject: output)
    }

    private static func toolLabel(_ name: String) -> String {
        if name.hasPrefix("mcp__") { return name.split(separator: "__").dropFirst().joined(separator: " ") }
        return name
    }
}
