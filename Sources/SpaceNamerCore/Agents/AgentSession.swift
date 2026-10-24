import Foundation

/// One running agent, keyed by its process, as the app tracks it.
public struct AgentSession: Equatable, Sendable {
    /// The agent's process ID.
    public let pid: Int32
    public var source: String
    public var sessionID: String?
    public var state: AgentState = .idle
    public var note: String?
    /// 0...1, while working, when the agent reports it.
    public var progress: Double?
    public var chat: ChatTitle?
    /// The desktop its terminal is on, once known.
    public var space: SpaceKey?
    public var transcript: String?
    /// When the newest change of state happened.
    public var updated: Double = 0

    public init(pid: Int32, source: String) {
        self.pid = pid
        self.source = source
    }

    /// Takes in a report. Reports can arrive out of order (hooks run in parallel), so one
    /// older than the latest change of state can't change the state any more.
    public mutating func apply(_ report: AgentReport) {
        if let session = report.session { sessionID = session }
        if let path = report.transcript { transcript = path }
        if report.event == .started, report.resumed != true { chat = nil }
        if let title = report.title, !title.isEmpty, report.event != .nameDesktop {
            chat = ChatTitle(title: title, isCustom: true)
        }
        guard report.time >= updated else { return }

        switch report.event {
        case .started:
            set(.idle)
        case .prompted:
            set(.working)
        case .working:
            if state != .working { set(.working) }
        case .needsInput:
            set(.needsInput, note: report.note)
        case .done:
            set(.done)
        case .failed:
            set(.failed, note: report.note)
        case .status:
            if let state = report.state, state != self.state { set(state, note: report.note) }
            if let note = report.note { self.note = note }
            if let progress = report.progress { self.progress = min(max(progress, 0), 1) }
            if state != .working { progress = nil }
        case .ended, .nameDesktop, .query:
            return
        }
        updated = report.time
    }

    /// The user has seen the result on its desktop: done and failed go back to idle.
    public mutating func acknowledge() {
        guard state == .done || state == .failed else { return }
        set(.idle)
    }

    private mutating func set(_ state: AgentState, note: String? = nil) {
        self.state = state
        self.note = note
        progress = nil
    }
}

/// What a desktop shows for the agents on it: the most urgent one.
public struct DesktopAgentStatus: Equatable, Sendable {
    public var state: AgentState
    public var progress: Double?
    public var note: String?
    /// How many agents on the desktop are in this state.
    public var count: Int

    public init(state: AgentState, progress: Double? = nil, note: String? = nil, count: Int = 1) {
        self.state = state
        self.progress = progress
        self.note = note
        self.count = count
    }

    public static func of<Sessions: Sequence>(_ sessions: Sessions) -> DesktopAgentStatus? where Sessions.Element == AgentSession {
        let active = sessions.filter { $0.state != .idle }
        guard let top = active.max(by: { ($0.state.urgency, $0.updated) < ($1.state.urgency, $1.updated) }) else { return nil }
        return DesktopAgentStatus(
            state: top.state,
            progress: top.progress,
            note: top.note,
            count: active.filter { $0.state == top.state }.count
        )
    }
}
