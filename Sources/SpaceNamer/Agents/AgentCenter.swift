import AppKit
import Combine
import os
import SpaceNamerCore

/// Tracks coding agents (reported by the `spacenamer` helper: Claude Code hooks, the MCP
/// server, scripts) and the desktop each one's terminal is on, for the menu bar, the menu,
/// the switcher and Mission Control to show.
///
/// - Claude Code sessions are followed through the status files Claude Code keeps for each
///   (so even sessions started before the plugin show), and through the plugin's hooks.
/// - A session belongs to the desktop of the terminal window showing it, where the
///   terminal app can say (iTerm2, Terminal); otherwise to the desktop its terminal was on
///   when the user last typed into it, until the terminal's window is no longer there.
/// - Done and failed are results waiting to be seen: being on that desktop for a moment
///   turns them back to idle.
/// - Desktops take their agent's chat title as a name (unless the user named them), and
///   a new chat on a desktop the user named takes the desktop's name. Renaming a chat
///   (`/rename`) renames its desktop too, whoever named it: the transcript is watched for
///   it, since no hook reports it.
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
    /// Each chat's own title as last seen ("" for none), to tell a rename from the title
    /// it already had.
    private var customTitles: [Int32: String] = [:]
    private var transcriptWatchers: [Int32: (path: String, source: DispatchSourceFileSystemObject)] = [:]
    private var pendingTitleReads = Set<Int32>()
    private var watchRetry: Timer?
    private let terminals = TerminalLocator()
    private var fileTimer: Timer?
    /// What each Claude Code status file last said, to act only on changes.
    private var fileSignatures: [Int32: String] = [:]
    private var transcriptPaths: [String: (path: String?, lookedAt: Date)] = [:]
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
        terminals.onChange = { [weak self] in self?.rebindToWindows() }
        model.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebindToWindows()
                self?.noteVisibility()
            }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readSessionFiles() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        fileTimer = timer
        readSessionFiles()
    }

    // MARK: Claude Code status files

    private func readSessionFiles() {
        for record in ClaudeSessionFiles.read() {
            let signature = [record.sessionID, record.status, record.waitingFor, record.name, record.nameSource, record.statusUpdatedAt.map { "\($0)" }]
                .map { $0 ?? "" }.joined(separator: "|")
            guard fileSignatures[record.pid] != signature, ProcessTree.isAlive(record.pid) else { continue }
            fileSignatures[record.pid] = signature
            var report = ClaudeSessionFiles.report(for: record, previous: sessions[record.pid]?.state)
            report.transcript = record.sessionID.flatMap(transcriptPath(forSession:))
            if sessions[record.pid] != nil, sessions[record.pid]?.sessionID != record.sessionID {
                // Seen from the file, a new chat in the same process (/clear) has no title yet.
                report.event = report.event == .query ? .started : report.event
            }
            // The file names the chat whenever the user has, so no name means none yet.
            if record.customName == nil, customTitles[record.pid] == nil { customTitles[record.pid] = "" }
            _ = handle(report, fromStatusFile: true)
        }
    }

    /// A session's transcript, wherever Claude Code keeps its project.
    private func transcriptPath(forSession id: String) -> String? {
        if let known = transcriptPaths[id], known.path != nil || Date().timeIntervalSince(known.lookedAt) < 10 { return known.path }
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        let path = folders.lazy.map { $0.appendingPathComponent("\(id).jsonl").path }.first { FileManager.default.fileExists(atPath: $0) }
        transcriptPaths[id] = (path, Date())
        return path
    }

    /// Moves sessions to the desktop of the terminal window showing them, where known.
    private func rebindToWindows() {
        var changed = false
        for (pid, session) in sessions {
            guard let key = windowSpace(of: pid), key != session.space, var moved = sessions[pid] else { continue }
            moved.space = key
            sessions[pid] = moved
            nameDesktop(after: moved)
            changed = true
        }
        if changed { publish() }
    }

    /// The desktop of the terminal window showing an agent's process, if its terminal app
    /// can say.
    private func windowSpace(of pid: Int32) -> SpaceKey? {
        guard pid > 0, let terminal = ProcessTree.terminal(of: pid) else { return nil }
        return terminals.window(showing: terminal).flatMap(model.space(ofWindow:))
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

    private func handle(_ report: AgentReport, fromStatusFile: Bool = false) -> AgentReply {
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
        if report.event == .started, report.resumed != true {
            // A new chat in the same process (/clear) starts from scratch, without a title.
            if session.sessionID != nil, session.sessionID != report.session {
                session = AgentSession(pid: pid, source: report.source)
            }
            customTitles[pid] = ""
        }
        bind(&session, report, fromStatusFile: fromStatusFile)
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
        // Only a title that's there counts: most hooks don't say what the chat is called,
        // and its transcript, read next, does.
        if let title = report.title {
            noteChat(ChatTitle(title: title, isCustom: true), of: pid)
        } else {
            nameDesktop(after: session)
        }
        watchTranscript(of: pid)
        readTitle(of: pid, force: [.started, .prompted, .done].contains(report.event))
        if let key = sessions[pid]?.space, let space = model.snapshot.space(forKey: key) {
            reply.desktop = model.title(for: space)
            reply.desktopNumber = space.position
            reply.desktopNamed = model.hasCustomName(space)
        }
        publish()
        noteVisibility()
        return reply
    }

    /// Works out (or confirms) the desktop a session's terminal is on.
    private func bind(_ session: inout AgentSession, _ report: AgentReport, fromStatusFile: Bool) {
        if let key = windowSpace(of: session.pid) {
            session.space = key
            return
        }
        // A status file says nothing about where the user is, so only a guess that doesn't
        // depend on that.
        if fromStatusFile {
            if session.space == nil, let terminal = ProcessTree.ancestors(of: session.pid).lazy
                .compactMap({ NSRunningApplication(processIdentifier: $0.pid) })
                .first(where: { $0.activationPolicy == .regular }) {
                let spaces = model.spaces(withWindowsOf: terminal.processIdentifier)
                if spaces.count == 1 { session.space = spaces.first }
            }
            return
        }
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
        transcriptWatchers.removeValue(forKey: pid)?.source.cancel()
        visibleSince[pid] = nil
        titleReadAt[pid] = nil
        customTitles[pid] = nil
        pendingTitleReads.remove(pid)
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

    /// Takes in what a chat is called now (nil: no title yet). A title the user gave the
    /// chat that differs from the one it had is a rename, made just now.
    private func noteChat(_ title: ChatTitle?, of pid: Int32) {
        guard var session = sessions[pid] else { return }
        let custom = title?.isCustom == true ? title?.title ?? "" : ""
        let renamed = !custom.isEmpty && customTitles[pid].map { $0 != custom } == true
        if !custom.isEmpty || customTitles[pid] == nil { customTitles[pid] = custom }
        // A title the user gave the chat beats a generated one.
        if let title, title.isCustom || session.chat?.isCustom != true, session.chat != title {
            session.chat = title
            sessions[pid] = session
            log.debug("chat \(pid) is \"\(title.title, privacy: .public)\"\(renamed ? " (renamed)" : "", privacy: .public)")
        }
        nameDesktop(after: session, renamed: renamed)
    }

    /// Names the session's desktop after its chat. A chat the user just renamed renames
    /// its desktop as if they'd done it there; otherwise only a desktop they haven't named
    /// follows its chat, the most recently active one if it has several.
    private func nameDesktop(after session: AgentSession, renamed: Bool = false) {
        guard model.preferences.nameDesktopsFromChats, let key = session.space, let chat = session.chat,
              let space = model.snapshot.space(forKey: key), model.store.name(for: key) != chat.title
        else { return }
        if renamed, chat.isCustom {
            model.rename(space, to: chat.title)
            return
        }
        guard !model.store.hasUserName(key) else { return }
        let latest = sessions.values.filter { $0.space == key && $0.chat != nil }.max { $0.updated < $1.updated }
        guard latest?.pid == session.pid else { return }
        model.store.setName(chat.title, for: space, automatic: true)
    }

    /// Re-reads a chat's title whenever its transcript changes: renaming a chat writes it
    /// there, but no hook reports it.
    private func watchTranscript(of pid: Int32) {
        guard let path = sessions[pid]?.transcript else { return }
        if let watcher = transcriptWatchers[pid] {
            if watcher.path == path { return }
            watcher.source.cancel()
            transcriptWatchers[pid] = nil
        }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Claude Code writes the transcript with its first record.
            retryWatching()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    source.cancel()
                    self.transcriptWatchers[pid] = nil
                    self.retryWatching()
                } else {
                    self.scheduleTitleRead(of: pid)
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        transcriptWatchers[pid] = (path, source)
        scheduleTitleRead(of: pid)
    }

    /// Transcripts change with every message, so reads are gathered up.
    private func scheduleTitleRead(of pid: Int32) {
        guard pendingTitleReads.insert(pid).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingTitleReads.remove(pid)
                self.readTitle(of: pid, force: true)
            }
        }
    }

    /// Looks every couple of seconds for transcripts that don't exist yet.
    private func retryWatching() {
        guard watchRetry == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let waiting = self.sessions.filter { $0.value.transcript != nil && self.transcriptWatchers[$0.key] == nil }.map(\.key)
                self.watchRetry = nil
                waiting.forEach { self.watchTranscript(of: $0) }
                if self.watchRetry == nil { timer.invalidate() } else { self.watchRetry = timer }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchRetry = timer
    }

    #if DEBUG
    /// A pretend agent on the desktop at `position`, to try the display without one.
    /// With a `transcript`, it's a new chat whose title is read (and watched) from there.
    func inject(position: Int, state: AgentState, progress: Double?, note: String?, title: String?, transcript: String?) {
        guard let space = model.snapshot.space(atPosition: position) else { return }
        let pid = Int32(-position)
        var session = sessions[pid] ?? AgentSession(pid: pid, source: "debug")
        session.space = space.key
        session.apply(AgentReport(event: .status, source: "debug", transcript: transcript, title: title, state: state, note: note, progress: progress))
        sessions[pid] = session
        if transcript != nil, customTitles[pid] == nil { customTitles[pid] = "" }
        nameDesktop(after: session)
        watchTranscript(of: pid)
        publish()
        noteVisibility()
    }

    /// Removes pretend agents, and the names their chats gave desktops.
    func removeInjected() {
        for (pid, session) in sessions where pid < 0 {
            if let key = session.space, let space = model.snapshot.space(forKey: key),
               !model.store.hasUserName(key) || model.store.name(for: key) == session.chat?.title {
                model.store.setName(nil, for: space)
            }
            remove(pid)
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
                    guard let self, self.sessions[pid]?.sessionID == id else { return }
                    self.noteChat(title, of: pid)
                }
            }
        }
    }
}
