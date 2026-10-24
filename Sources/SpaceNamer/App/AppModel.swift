import AppKit
import Combine
import SpaceNamerCore

/// The app's state and behaviour. UI controllers observe it and call into it; it never
/// reaches into them except through `Actions`.
@MainActor
final class AppModel: ObservableObject {
    struct Actions {
        var toggleSwitcher: () -> Void = {}
        var renameCurrentSpace: () -> Void = {}
        var showSettings: () -> Void = {}
        /// `early` is true when shown at the start of a switch macOS is still animating.
        var showHUD: (Space, _ early: Bool) -> Void = { _, _ in }
        /// A switch to this Space has just started (macOS reports it once it lands).
        var switchStarted: (Space) -> Void = { _ in }
        var explainPermission: () -> Void = {}
        var explainMissingShortcuts: () -> Void = {}
    }

    @Published private(set) var snapshot: SpacesSnapshot = .empty
    /// Where a switch that has started is heading, until macOS reports it has landed (at
    /// the end of its slide), so the menu bar can name it straight away. During a swipe it's
    /// where the fingers are taking it: macOS draws the arriving desktop's menu bar as the
    /// swipe starts and doesn't redraw it until the switch has landed.
    @Published private(set) var arriving: Space?
    @Published private(set) var hasAccess = EventSynth.hasAccess
    /// Bumped whenever names or per-Space shortcuts change.
    @Published private(set) var namesRevision = 0
    @Published private(set) var appsBySpace: [UInt64: [NSRunningApplication]] = [:]
    /// Shortcuts that could not be registered because something else owns them.
    @Published private(set) var unavailableHotKeys: Set<HotKey> = []

    let preferences: Preferences
    let store: NameStore
    let updates: UpdateChecker
    private(set) lazy var agents = AgentCenter(model: self)
    var actions = Actions()

    private let reader = SpaceReader()
    private let navigator: SpaceNavigator
    private let hotKeys = HotKeyCenter()
    private lazy var inventory = WindowInventory(reader: reader)
    private var pollTimer: Timer?
    private var permissionTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancellables = Set<AnyCancellable>()
    private var history: [SpaceKey] = []
    private var hotKeysSuspended = false
    private var registeredSignature: [HotKey] = []
    private var asleep = false
    private var jumpTask: Task<Void, Never>?
    private let launchedWithAccess = EventSynth.hasAccess

    init(preferences: Preferences, store: NameStore) {
        self.preferences = preferences
        self.store = store
        updates = UpdateChecker(preferences: preferences)
        navigator = SpaceNavigator(reader: reader)
        navigator.method = preferences.switchMethod
    }

    var spacesAvailable: Bool { reader.isAvailable }

    // MARK: Lifecycle

    func start() {
        store.onChange = { [weak self] in
            guard let self else { return }
            namesRevision &+= 1
            registerHotKeys()
        }

        preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                navigator.method = preferences.switchMethod
                registerHotKeys()
            }
            .store(in: &cancellables)

        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { $0.refresh() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { $0.refresh() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { $0.setAsleep(true) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { $0.setAsleep(false) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification) { $0.setAsleep(true) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setAsleep(false) }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { model in
            model.store.noteDisplayReconfiguration()
            model.refresh()
        }
        // Posted whenever the Accessibility list changes; the new state lands shortly after.
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.accessibility.api")) { model in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.refreshPermission() }
        }

        refresh()
        registerHotKeys()
        startPolling()
        refreshPermission()
        updates.start()
        agents.start()
    }

    /// Mission Control reorders, adds and removes Spaces without telling anyone, so a
    /// cheap, coalesced poll catches those. Reading the layout is one window-server call.
    private func startPolling() {
        pollTimer?.invalidate()
        guard !asleep else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func setAsleep(_ asleep: Bool) {
        self.asleep = asleep
        if asleep {
            pollTimer?.invalidate()
            pollTimer = nil
        } else {
            store.noteDisplayReconfiguration()
            refresh()
            startPolling()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (AppModel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    // MARK: Refreshing

    func refresh() {
        let next = reader.snapshot()
        store.reconcile(with: next)
        guard next != snapshot else { return }
        let previous = snapshot
        snapshot = next
        guard !navigator.isJumping, !previous.isEmpty else { return }
        noteTransition(from: previous, to: next)
    }

    func refreshApps() {
        inventory.refresh { [weak self] apps in
            self?.appsBySpace = apps
        }
    }

    func refreshPermission() {
        let granted = EventSynth.hasAccess
        if granted != hasAccess { hasAccess = granted }
        // macOS applies a new grant to event posting only from the next launch.
        if granted, !launchedWithAccess {
            relaunch()
            return
        }
        // Until access is granted, check now and then so the UI updates on its own.
        if granted {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermission() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        }
    }

    private func noteTransition(from previous: SpacesSnapshot, to next: SpacesSnapshot) {
        let before = previous.currentByDisplay
        for display in next.displays {
            guard let old = before[display.id], old != display.currentManagedID, let space = display.current else { continue }
            if display.id == (next.activeDisplayID ?? display.id),
               let left = previous.display(withID: display.id)?.spaces.first(where: { $0.managedID == old }) {
                pushHistory(left.key)
            }
            // Passing through on the way to a Space further along (quick swipes or presses
            // in a row): the pill already names where this is going.
            if let pending = pendingSwitch, pending.display == display.id {
                if pending.key == space.key || Date().timeIntervalSince(pending.started) > Self.pendingSwitchLifetime {
                    pendingSwitch = nil
                } else {
                    continue
                }
            }
            if preferences.showSwitchHUD { actions.showHUD(space, false) }
        }
    }

    /// A switch that has started but not landed (macOS reports the current Space only once
    /// it does). Further moves count on from it.
    private var pendingSwitch: (key: SpaceKey, display: String, started: Date)? {
        didSet { updateArriving() }
    }
    private var swipeHeading: Space? {
        didSet { updateArriving() }
    }

    private func updateArriving() {
        let next = swipeHeading ?? pendingSwitch.flatMap { snapshot.space(forKey: $0.key) }
        if next != arriving { arriving = next }
    }
    private static let pendingSwitchLifetime: TimeInterval = 1.5

    private func pushHistory(_ key: SpaceKey) {
        history.removeAll { $0 == key }
        history.append(key)
        if history.count > 32 { history.removeFirst(history.count - 32) }
    }

    /// The most recently visited Space that still exists, other than the current one.
    var previousSpace: Space? {
        let currentKey = snapshot.current?.key
        for key in history.reversed() where key != currentKey {
            if let space = snapshot.space(forKey: key) { return space }
        }
        return nil
    }

    // MARK: Names

    func title(for space: Space) -> String {
        store.name(for: space.key) ?? systemName(for: space)
    }

    func hasCustomName(_ space: Space) -> Bool {
        store.name(for: space.key) != nil
    }

    /// The name macOS would show, with app names filled in for full-screen Spaces when
    /// the window server leaves them out.
    func systemName(for space: Space) -> String {
        guard space.kind == .fullscreen, space.fullscreenAppNames.isEmpty else { return space.systemName }
        let names = space.fullscreenPIDs.compactMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
            + (appsBySpace[space.managedID] ?? []).compactMap(\.localizedName)
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? space.systemName : unique.joined(separator: " & ")
    }

    func rename(_ space: Space, to name: String?) {
        store.setName(name, for: space)
    }

    func renameCurrentSpace(to name: String?) {
        refresh()
        guard let space = snapshot.current else { return }
        rename(space, to: name)
    }

    func setHotKey(_ hotKey: HotKey?, for space: Space) {
        store.setHotKey(hotKey, for: space)
    }

    func displayName(for displayID: String) -> String {
        guard let target = DisplayResolver.displayID(for: displayID),
              let screen = NSScreen.screens.first(where: { $0.displayID == target })
        else { return displayID == DisplayResolver.sharedSpacesIdentifier ? "All Displays" : "Display" }
        return screen.localizedName
    }

    /// The Space the menu bar on a display (by UUID) names: where a switch there is heading,
    /// else the one showing. Without a display, or with Spaces shared, the active menu bar's.
    func menuBarSpace(onDisplay displayID: String?) -> Space? {
        guard let displayID,
              let display = snapshot.displays.first(where: { $0.id.caseInsensitiveCompare(displayID) == .orderedSame })
        else { return arriving ?? snapshot.current }
        if let arriving, arriving.displayID == display.id { return arriving }
        return display.current
    }

    func screen(for displayID: String) -> NSScreen? {
        // Displays sharing Spaces all switch together: show it where the pointer is.
        if displayID == DisplayResolver.sharedSpacesIdentifier {
            let pointer = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        }
        guard let target = DisplayResolver.displayID(for: displayID) else { return NSScreen.main }
        return NSScreen.screens.first { $0.displayID == target } ?? NSScreen.main
    }

    /// The Space a window is on, if it's on just one.
    func space(ofWindow window: CGWindowID) -> SpaceKey? {
        let spaces = reader.spaces(forWindow: window)
        guard spaces.count == 1 else { return nil }
        return snapshot.allSpaces.first { $0.managedID == spaces[0] }?.key
    }

    /// The Spaces where an app has a window (ignoring windows on every Space).
    func spaces(withWindowsOf pid: pid_t) -> Set<SpaceKey> {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var managedIDs = Set<UInt64>()
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 64, bounds.height >= 64
            else { continue }
            let spaces = reader.spaces(forWindow: number)
            if spaces.count == 1 { managedIDs.formUnion(spaces) }
        }
        return Set(snapshot.allSpaces.filter { managedIDs.contains($0.managedID) }.map(\.key))
    }

    func shortcutLabel(for space: Space) -> String? {
        if let hotKey = store.hotKey(for: space.key) { return hotKey.displayString }
        if let position = space.position, let hotKey = preferences.positionHotKey(position) { return hotKey.displayString }
        return nil
    }

    // MARK: Jumping

    func jump(to space: Space) {
        jump(toKey: space.key)
    }

    func jump(toKey key: SpaceKey) {
        refresh()
        pendingSwitch = nil // this jump decides where we end up
        let origin = snapshot.current
        jumpTask?.cancel()
        jumpTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await navigator.jump(to: key)
            finishJump(outcome, to: key, from: origin)
        }
    }

    func jump(toPosition position: Int) {
        refresh()
        guard let space = snapshot.space(atPosition: position) else {
            NSSound.beep()
            return
        }
        jump(to: space)
    }

    func jump(toName query: String) {
        refresh()
        let spaces = snapshot.allSpaces
        if let exact = spaces.first(where: { title(for: $0).caseInsensitiveCompare(query) == .orderedSame }) {
            jump(to: exact)
            return
        }
        let best = spaces
            .compactMap { space in FuzzyMatcher.match(query, in: title(for: space)).map { (space, $0.score) } }
            .max { $0.1 < $1.1 }
        if let best { jump(to: best.0) } else { NSSound.beep() }
    }

    func jumpBack() {
        refresh()
        guard let space = previousSpace else {
            NSSound.beep()
            return
        }
        jump(to: space)
    }

    /// Next (+1) or previous (-1) Space on the active display.
    func jumpRelative(_ offset: Int) {
        refresh()
        guard let display = snapshot.activeDisplay, let current = display.current, display.spaces.count > 1 else { return }
        var index = current.index + offset
        if preferences.wrapAround {
            index = (index % display.spaces.count + display.spaces.count) % display.spaces.count
        }
        guard display.spaces.indices.contains(index) else {
            NSSound.beep()
            return
        }
        jump(to: display.spaces[index])
    }

    private func finishJump(_ outcome: SpaceNavigator.Outcome, to key: SpaceKey, from origin: Space?) {
        // Take the final layout without treating the hops on the way as user switches.
        let previous = snapshot
        snapshot = reader.snapshot()
        store.reconcile(with: snapshot)

        switch outcome {
        case .arrived:
            if let origin, origin.key != key { pushHistory(origin.key) }
            if preferences.showSwitchHUD, let space = snapshot.space(forKey: key) { actions.showHUD(space, false) }
        case .alreadyThere:
            break
        case .needsPermission:
            refreshPermission()
            actions.explainPermission()
        case .noShortcut:
            actions.explainMissingShortcuts()
        case .notFound, .failed:
            NSSound.beep()
            if previous != snapshot, !previous.isEmpty { noteTransition(from: previous, to: snapshot) }
        case .cancelled:
            break
        }
    }

    /// Called when a switch starts that macOS will report only once its animation ends.
    func predictSwitch(_ move: SwitchPredictor.Move) {
        guard !navigator.isJumping, let (target, display) = switchTarget(for: move) else { return }
        let started = Date()
        pendingSwitch = (target.key, display.id, started)
        // A switch macOS didn't make after all.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pendingSwitchLifetime) { [weak self] in
            guard let self, pendingSwitch?.started == started else { return }
            pendingSwitch = nil
        }
        actions.switchStarted(target)
        if preferences.showSwitchHUD { actions.showHUD(target, true) }
    }

    /// A swipe between Spaces is under way, heading `move` (nil: back where it started, or
    /// over). The pill waits to see whether it goes through; the menu bar can't.
    func swipeHeading(_ move: SwitchPredictor.Move?) {
        swipeHeading = navigator.isJumping ? nil : move.flatMap { switchTarget(for: $0)?.space }
    }

    /// The Space `move` goes to on the display under the pointer, counting on from a switch
    /// still on its way there.
    private func switchTarget(for move: SwitchPredictor.Move) -> (space: Space, display: DisplaySpaces)? {
        let cursorDisplay = snapshot.displays.first { DisplayResolver.isCursor(onDisplay: $0.id) }
        guard let display = cursorDisplay ?? snapshot.activeDisplay, let current = display.current else { return nil }
        // Still on the way to an earlier move's Space: this one goes on from there.
        var from = current
        if let pending = pendingSwitch, pending.display == display.id,
           Date().timeIntervalSince(pending.started) < Self.pendingSwitchLifetime,
           let heading = display.spaces.first(where: { $0.key == pending.key }) {
            from = heading
        }

        let target: Space?
        switch move {
        case .relative(let offset):
            let index = from.index + offset
            target = display.spaces.indices.contains(index) ? display.spaces[index] : nil
        case .position(let position):
            target = snapshot.space(atPosition: position)
        }
        guard let target, target.key != from.key else { return nil }
        return (target, display)
    }

    var swipeSign: Int { navigator.swipeSign }

    // MARK: Hot keys

    func suspendHotKeys(_ suspended: Bool) {
        hotKeysSuspended = suspended
        registerHotKeys(force: true)
    }

    private func registerHotKeys(force: Bool = false) {
        var bindings: [(HotKey, () -> Void)] = []
        func bind(_ hotKey: HotKey?, _ action: @escaping (AppModel) -> Void) {
            guard let hotKey else { return }
            bindings.append((hotKey, { [weak self] in if let self { action(self) } }))
        }

        if !hotKeysSuspended {
            bind(preferences.switcherHotKey) { $0.actions.toggleSwitcher() }
            bind(preferences.backHotKey) { $0.jumpBack() }
            bind(preferences.nextHotKey) { $0.jumpRelative(1) }
            bind(preferences.previousHotKey) { $0.jumpRelative(-1) }
            bind(preferences.renameHotKey) { $0.actions.renameCurrentSpace() }
            for position in 1...HotKey.numberRowKeyCodes.count {
                bind(preferences.positionHotKey(position)) { $0.jump(toPosition: position) }
            }
            for (key, record) in store.records.sorted(by: { $0.key < $1.key }) {
                bind(record.hotKey) { $0.jump(toKey: key) }
            }
        }

        let signature = bindings.map(\.0)
        guard force || signature != registeredSignature else { return }
        registeredSignature = signature

        hotKeys.unregisterAll()
        var unavailable = Set<HotKey>()
        for (hotKey, action) in bindings where !hotKeys.register(hotKey, action: action) {
            unavailable.insert(hotKey)
        }
        if unavailable != unavailableHotKeys { unavailableHotKeys = unavailable }
    }

    /// Starts a fresh copy once this one has quit.
    private func relaunch() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    // MARK: URL commands

    func handle(_ command: URLCommand) {
        switch command {
        case .jumpToPosition(let position): jump(toPosition: position)
        case .jumpToName(let name): jump(toName: name)
        case .jumpToKey(let key): jump(toKey: key)
        case .next: jumpRelative(1)
        case .previous: jumpRelative(-1)
        case .back: jumpBack()
        case .switcher: actions.toggleSwitcher()
        case .rename(let name?): renameCurrentSpace(to: name)
        case .rename(nil): actions.renameCurrentSpace()
        case .settings: actions.showSettings()
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The identifier the window server lists this display's Spaces under.
    var displayUUID: String? {
        displayID.flatMap(DisplayResolver.uuidString(for:))
    }
}
