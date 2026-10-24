import AppKit
import Combine
import os
import SpaceNamerCore

/// Tracks coding agents (reported by the `spacenamer` helper: Claude Code hooks, the MCP
/// server, scripts) and the desktop each one's terminal is on, for the menu bar, the menu,
/// the switcher and Mission Control to show.
///
/// - A session belongs to the desktop its terminal was on when the user last typed into
///   it, and keeps it until the terminal's window is no longer there.
/// - Done and failed are results waiting to be seen: being on that desktop for a moment
///   turns them back to idle.
/// - Desktops take their agent's chat title as a name (unless the user named them), and
///   a new chat on a desktop the user named takes the desktop's name.
@MainActor
final class AgentCenter: ObservableObject {
    @Published private(set) var sessions: [Int32: AgentSession] = [:]
    /// What each desktop shows: its most urgent agent.
    @Published private(set) var statusBySpace: [SpaceKey: DesktopAgentStatus] = [:]

    /// How long a result stays once its desktop is on screen.
    private static let seenAfter: TimeInterval = 2
    /// How often the chat title is re-read while an agent keeps reporting.
    private static let titleInterval: TimeInterval = 15

    private unowned let model: AppModel
    private var server: AgentSocket.Server?
    private var exitWatchers: [Int32: DispatchSourceProcess] = [:]
    private var visibleSince: [Int32: Date] = [:]
    private var acknowledgeWork: DispatchWorkItem?
    private var titleReadAt: [Int32: Date] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let titleQueue = DispatchQueue(label: "SpaceNamer.ChatTitle", qos: .utility)
    private let log = Logger(subsystem: "com.alexandercollins.SpaceNamer", category: "agents")

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        server = AgentSocket.Server(queue: .main) { [weak self] report in
            MainActor.assumeIsolated { self?.handle(report) ?? AgentReply(error: "SpaceNamer is quitting.") }
        }
        linkHelper()
        model.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.noteVisibility() }
            .store(in: &cancellables)
    }

    func status(for space: Space) -> DesktopAgentStatus? {
        model.preferences.showAgentStatus ? statusBySpace[space.key] : nil
    }

    /// The agents on a desktop, most recently active first.
    func sessions(on space: Space) -> [AgentSession] {
        sessions.values.filter { $0.space == space.key }.sorted { $0.updated > $1.updated }
    }

    /// Keeps `~/Library/Application Support/SpaceNamer/spacenamer` pointing at this copy's
    /// helper, so the Claude Code plugin finds it wherever the app is installed.
    private func linkHelper() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spacenamer")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
        let link = AgentSocket.folder.appendingPathComponent("spacenamer")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == helper.path { return }
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
    }

    // MARK: Reports

    private func handle(_ report: AgentReport) -> AgentReply {
        guard let pid = report.agentPID else { return AgentReply(error: "Couldn't tell which agent this is.") }

        if report.event == .ended {
            if sessions[pid].map({ report.session == nil || $0.sessionID == report.session }) == true { remove(pid) }
            return AgentReply()
        }

        var session = sessions[pid] ?? AgentSession(pid: pid, source: report.source)
        if sessions[pid] == nil {
            guard ProcessTree.isAlive(pid) else { return AgentReply() }
            watchExit(of: pid)
        }
        // A new chat in the same process (/clear) starts from scratch.
        if report.event == .started, report.resumed != true, session.sessionID != nil, session.sessionID != report.session {
            session = AgentSession(pid: pid, source: report.source)
        }
        bind(&session, report)
        session.apply(report)

        var reply = AgentReply()
        if report.event == .nameDesktop, let key = session.space, let space = model.snapshot.space(forKey: key) {
            // Asked for by the user, through their agent: theirs.
            model.rename(space, to: report.name)
        }
        if report.event == .started, model.preferences.nameChatsFromDesktops {
            reply.chatTitle = chatTitle(forNewChat: session, report: report)
        }

        sessions[pid] = session
        log.debug("\(report.source, privacy: .public) \(report.event.rawValue, privacy: .public) from \(pid): \(session.state.rawValue, privacy: .public), desktop \(session.space.flatMap { self.model.snapshot.space(forKey: $0)?.position } ?? 0)")
        if let key = session.space, let space = model.snapshot.space(forKey: key) {
            reply.desktop = model.title(for: space)
            reply.desktopNumber = space.position
            reply.desktopNamed = model.hasCustomName(space)
        }
        nameDesktop(after: session)
        readTitle(of: pid, force: [.started, .prompted, .done].contains(report.event))
        publish()
        noteVisibility()
        return reply
    }

    /// Works out (or confirms) the desktop a session's terminal is on.
    private func bind(_ session: inout AgentSession, _ report: AgentReport) {
        let snapshot = model.snapshot
        let terminal = report.processes.lazy
            .compactMap { NSRunningApplication(processIdentifier: $0.pid) }
            .first { $0.activationPolicy == .regular }
        // The user just typed into the terminal, so it's in front, on the current desktop.
        let typed = report.event == .prompted || (report.event == .started && report.resumed != true) || report.source == "cli"

        if let key = session.space, snapshot.space(forKey: key) != nil {
            // Keep it unless the terminal's window has moved away from there.
            guard typed, let terminal, !model.spaces(withWindowsOf: terminal.processIdentifier).contains(key) else { return }
        }
        let inFront = terminal == nil || terminal?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier
        if inFront, typed || session.space == nil {
            model.refresh()
            if let current = model.snapshot.current {
                session.space = current.key
                return
            }
        }
        if let terminal {
            let spaces = model.spaces(withWindowsOf: terminal.processIdentifier)
            if spaces.count == 1 { session.space = spaces.first }
        }
    }

    private func remove(_ pid: Int32) {
        exitWatchers.removeValue(forKey: pid)?.cancel()
        visibleSince[pid] = nil
        titleReadAt[pid] = nil
        guard sessions.removeValue(forKey: pid) != nil else { return }
        publish()
    }

    private func watchExit(of pid: Int32) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.remove(pid) }
        }
        source.resume()
        exitWatchers[pid] = source
    }

    private func publish() {
        var grouped: [SpaceKey: [AgentSession]] = [:]
        for session in sessions.values {
            guard let key = session.space else { continue }
            grouped[key, default: []].append(session)
        }
        let statuses = grouped.compactMapValues { DesktopAgentStatus.of($0) }
        if statuses != statusBySpace { statusBySpace = statuses }
    }

    // MARK: Seen

    /// Results on a desktop that's on screen count as seen after a moment.
    private func noteVisibility() {
        let snapshot = model.snapshot
        let now = Date()
        for (pid, session) in sessions {
            let showing = session.space.flatMap(snapshot.space(forKey:)).map(snapshot.isCurrent) ?? false
            if showing, session.state == .done || session.state == .failed {
                if visibleSince[pid] == nil { visibleSince[pid] = now }
            } else {
                visibleSince[pid] = nil
            }
        }
        acknowledgeWork?.cancel()
        guard let earliest = visibleSince.values.min() else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.acknowledgeSeen() }
        }
        acknowledgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, Self.seenAfter - now.timeIntervalSince(earliest)), execute: work)
    }

    private func acknowledgeSeen() {
        model.refresh()
        let now = Date()
        var changed = false
        for (pid, since) in visibleSince where now.timeIntervalSince(since) >= Self.seenAfter - 0.05 {
            let snapshot = model.snapshot
            guard var session = sessions[pid], let key = session.space, let space = snapshot.space(forKey: key), snapshot.isCurrent(space) else { continue }
            session.acknowledge()
            sessions[pid] = session
            visibleSince[pid] = nil
            changed = true
        }
        if changed { publish() }
        noteVisibility()
    }

    // MARK: Names

    /// A new chat on a desktop the user named takes the desktop's name; so does a resumed
    /// one that has no title yet.
    private func chatTitle(forNewChat session: AgentSession, report: AgentReport) -> String? {
        guard report.title == nil, let key = session.space, model.store.hasUserName(key),
              let space = model.snapshot.space(forKey: key)
        else { return nil }
        if report.resumed == true, let path = report.transcript,
           ChatTitle.read(transcript: URL(fileURLWithPath: path), session: report.session) != nil {
            return nil
        }
        return model.title(for: space)
    }

    /// Names the session's desktop after its chat, unless the user named the desktop or a
    /// more recently active agent there has a title of its own.
    private func nameDesktop(after session: AgentSession) {
        guard model.preferences.nameDesktopsFromChats, let key = session.space, let chat = session.chat,
              !model.store.hasUserName(key), let space = model.snapshot.space(forKey: key)
        else { return }
        let latest = sessions.values.filter { $0.space == key && $0.chat != nil }.max { $0.updated < $1.updated }
        guard latest?.pid == session.pid, model.store.name(for: key) != chat.title else { return }
        model.store.setName(chat.title, for: space, automatic: true)
    }

    #if DEBUG
    /// A pretend agent on the desktop at `position`, to try the display without one.
    func inject(position: Int, state: AgentState, progress: Double?, note: String?, title: String?) {
        guard let space = model.snapshot.space(atPosition: position) else { return }
        let pid = Int32(-position)
        var session = sessions[pid] ?? AgentSession(pid: pid, source: "debug")
        session.space = space.key
        session.apply(AgentReport(event: .status, source: "debug", title: title, state: state, note: note, progress: progress))
        sessions[pid] = session
        nameDesktop(after: session)
        publish()
        noteVisibility()
    }

    /// Removes pretend agents, and the names their chats gave desktops.
    func removeInjected() {
        for (pid, session) in sessions where pid < 0 {
            if let key = session.space, let space = model.snapshot.space(forKey: key), !model.store.hasUserName(key) {
                model.store.setName(nil, for: space)
            }
            sessions[pid] = nil
        }
        publish()
    }
    #endif

    /// Reads the chat's title from its transcript, off the main thread.
    private func readTitle(of pid: Int32, force: Bool) {
        guard let session = sessions[pid], let path = session.transcript else { return }
        if !force, let last = titleReadAt[pid], Date().timeIntervalSince(last) < Self.titleInterval { return }
        titleReadAt[pid] = Date()
        let id = session.sessionID
        titleQueue.async { [weak self] in
            let title = ChatTitle.read(transcript: URL(fileURLWithPath: path), session: id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let title, var session = self.sessions[pid], session.sessionID == id else { return }
                    // A title the user gave the chat beats a generated one.
                    guard title.isCustom || session.chat?.isCustom != true, session.chat != title else { return }
                    session.chat = title
                    self.sessions[pid] = session
                    self.log.debug("chat \(pid) is \"\(title.title, privacy: .public)\"")
                    self.nameDesktop(after: session)
                }
            }
        }
    }
}
