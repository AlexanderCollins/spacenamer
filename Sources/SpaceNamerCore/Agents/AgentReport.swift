import Foundation

/// What a coding agent (Claude Code, or anything else through the MCP server or the
/// command line) is doing, as shown on the desktop its terminal is on.
public enum AgentState: String, Codable, CaseIterable, Sendable {
    /// Nothing to show: waiting for its next prompt, or a result already looked at.
    case idle
    /// Finished a turn the user hasn't been back to see yet.
    case done
    case working
    /// Stopped on an error the user hasn't been back to see yet.
    case failed
    /// Waiting on the user: a permission, a question or a plan to approve.
    case needsInput = "needs_input"

    /// Higher is more urgent; a desktop shows its most urgent agent.
    public var urgency: Int {
        switch self {
        case .idle: return 0
        case .done: return 1
        case .working: return 2
        case .failed: return 3
        case .needsInput: return 4
        }
    }

    public var title: String {
        switch self {
        case .idle: return "Idle"
        case .done: return "Done"
        case .working: return "Working"
        case .failed: return "Failed"
        case .needsInput: return "Needs you"
        }
    }
}

/// One process in the reporter's ancestry.
public struct AgentProcess: Codable, Equatable, Sendable {
    public var pid: Int32
    public var name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// A message from an agent integration to the app, one per connection.
public struct AgentReport: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        /// A session started: fresh, or resumed (`resumed`).
        case started
        /// The user sent a prompt.
        case prompted
        /// The agent carried on working (for instance after a permission was granted).
        case working
        case needsInput = "needs_input"
        case done
        case failed
        /// The session ended.
        case ended
        /// An explicit state, progress or note, from the MCP server or command line.
        case status
        /// Give the desktop a name.
        case nameDesktop = "name_desktop"
        /// Just asking about the desktop.
        case query
    }

    public var event: Event
    /// Which integration sent it: "claude-code", "mcp" or "cli".
    public var source: String
    /// The harness's session ID, when it has one.
    public var session: String?
    /// The reporter's ancestors, nearest first. The agent is the first that isn't a shell;
    /// further up is the app its terminal runs in.
    public var processes: [AgentProcess]
    public var transcript: String?
    /// The chat's title as the harness knows it (a name the user gave it).
    public var title: String?
    /// For `nameDesktop`, the name; for `status`, the state.
    public var name: String?
    public var state: AgentState?
    public var note: String?
    /// 0...1
    public var progress: Double?
    /// For `started`: a resumed chat rather than a new one.
    public var resumed: Bool?
    /// When it happened (seconds since 1970), so late deliveries can't undo newer news.
    public var time: Double

    public init(
        event: Event,
        source: String,
        session: String? = nil,
        processes: [AgentProcess] = [],
        transcript: String? = nil,
        title: String? = nil,
        name: String? = nil,
        state: AgentState? = nil,
        note: String? = nil,
        progress: Double? = nil,
        resumed: Bool? = nil,
        time: Double = Date().timeIntervalSince1970
    ) {
        self.event = event
        self.source = source
        self.session = session
        self.processes = processes
        self.transcript = transcript
        self.title = title
        self.name = name
        self.state = state
        self.note = note
        self.progress = progress
        self.resumed = resumed
        self.time = time
    }

    /// The agent's process: the reporter's nearest ancestor that isn't a shell.
    public var agentPID: Int32? {
        processes.first { !ProcessTree.isShell($0.name) }?.pid ?? processes.first?.pid
    }
}

/// The app's answer: the desktop the agent is on.
public struct AgentReply: Codable, Equatable, Sendable {
    public var desktop: String?
    public var desktopNumber: Int?
    /// The desktop has a name the user gave it.
    public var desktopNamed: Bool?
    /// A title to give the chat (a new chat on a desktop the user named).
    public var chatTitle: String?
    public var error: String?

    public init(desktop: String? = nil, desktopNumber: Int? = nil, desktopNamed: Bool? = nil, chatTitle: String? = nil, error: String? = nil) {
        self.desktop = desktop
        self.desktopNumber = desktopNumber
        self.desktopNamed = desktopNamed
        self.chatTitle = chatTitle
        self.error = error
    }
}
