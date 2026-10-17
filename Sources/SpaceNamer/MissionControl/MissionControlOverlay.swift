import AppKit
import ApplicationServices
import CGSBridge
import Combine
import os
import SpaceNamerCore

/// Shows your Space names in Mission Control's Spaces bar.
///
/// The Dock's own labels can't be changed without disabling SIP, so names are drawn in a
/// click-through window above Mission Control, exactly over the Dock's labels, and moved
/// in step with them:
///
/// - opening and closing replay the Dock's measured slide (`DockMotion`), anchored to the
///   key press, the interface appearing, or the interface going away;
/// - a three-finger swipe drives the slide from the gesture's progress while the fingers
///   are down, then from the Dock's own live bar position (which it publishes during
///   swipes) as it finishes opening, springs back or closes;
/// - hovering, adding, removing or reordering Spaces replays the Dock's own transition
///   from wherever each label currently is.
///
/// Positions come from the Dock's Accessibility tree, read off the main thread only while
/// Mission Control is up. Nothing runs between uses.
@MainActor
final class MissionControlOverlay {
    private enum Phase: Equatable {
        case idle
        /// A trigger was seen; waiting for the Dock to build Mission Control.
        case armed
        case opening
        case open
        case closing
    }

    /// What started Mission Control. Triggers we can see start watching the Dock early;
    /// every timed open is then anchored to the interface appearing.
    private enum OpenSource {
        /// A Mission Control shortcut.
        case key
        /// Launched another way (Dock, Launchpad, Spotlight, hot corner).
        case interface
        /// A vertical three-finger swipe is driving it.
        case gesture
    }

    private struct Gesture {
        enum Direction { case opening, closing }
        var direction: Direction?
        /// How open the bar is, 0...1, as currently shown.
        var fraction: Double
        var progress: Double = 0
        /// The swipe asked Mission Control back while it was leaving; the Dock turns the
        /// bar around on its own and ignores the rest of the swipe.
        var reversing = false
        /// The names move with the fingers themselves, a frame sooner than the Dock's
        /// reports could move them, unless the Dock turns out not to be moving the bar.
        var fingersTrusted = true
        /// The Dock has moved the bar since the swipe began.
        var dockMoved = false
        var startedAt: CFTimeInterval = 0
    }

    private static let armTimeout: TimeInterval = 1.2
    private static let snapshotInterval: TimeInterval = 0.1
    private static let collapsedBarHeight: CGFloat = 78
    /// Gesture progress needed to bring Mission Control fully in.
    private static let gestureTravel = 1.0

    private let model: AppModel
    private let log = Logger(subsystem: "com.alexandercollins.SpaceNamer", category: "mission-control")
    private let reader = SpacesBarReader()
    private var phase: Phase = .idle
    private var openSource: OpenSource?
    private var windows: [CGDirectDisplayID: OverlayWindow] = [:]
    private var layouts: [CGDirectDisplayID: SpacesBarReader.Layout] = [:]
    /// The last names-only layout per display, used to place names before the Dock
    /// publishes this session's layout (which it does only partway through the slide).
    /// Kept across launches, so the first Mission Control after a login has names too.
    private var cache: [CGDirectDisplayID: SpacesBarReader.Layout] = MissionControlOverlay.loadCache() {
        didSet { if cache != oldValue { Self.saveCache(cache) } }
    }
    private static let cacheKey = "MissionControlLayouts.v1"

    private static func loadCache() -> [CGDirectDisplayID: SpacesBarReader.Layout] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let layouts = try? JSONDecoder().decode([SpacesBarReader.Layout].self, from: data)
        else { return [:] }
        return Dictionary(layouts.map { ($0.displayID, $0) }, uniquingKeysWith: { _, last in last })
    }

    private static func saveCache(_ cache: [CGDirectDisplayID: SpacesBarReader.Layout]) {
        if let data = try? JSONEncoder().encode(Array(cache.values)) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
    private var gesture: Gesture?
    /// After a swipe is released: mirror the Dock's live bar position until it settles.
    private var followsDock = false {
        didSet { if followsDock != oldValue { reader.setFast(followsDock || gesture != nil) } }
    }
    private var releaseFallback: DispatchWorkItem?
    private var observer: AXObserver?
    private var dock: NSRunningApplication?
    private var armTimeoutWork: DispatchWorkItem?
    private var endWork: DispatchWorkItem?
    private var snapshotTimer: Timer?
    private var hotCornerTimer: Timer?
    private var hotCorners: [String] = []
    private var cornerLatched = false
    /// Which Space each of the Dock's thumbnail elements stands for, per display. Built
    /// from the Space order, then kept by element so names stay with their thumbnails
    /// while one is dragged to a new place (the Dock renumbers titles by position).
    private var elementSpaces: [CGDirectDisplayID: [Int: SpaceKey]] = [:]
    private var mappedOrder: [CGDirectDisplayID: [SpaceKey]] = [:]
    /// When the bar last started growing from names into thumbnails.
    private var expandStartedAt: CFTimeInterval?
    /// The bar's position as the Dock last reported it, per display. Once known, swipes
    /// follow it rather than the fingers: the Dock doesn't always move the bar with them
    /// (with thumbnails showing and the pointer over them, a swipe down leaves it put).
    private var dockOffsets: [CGDirectDisplayID: CGFloat] = [:]
    /// How long the bar may stay put under moving fingers before we stop believing it
    /// follows them (its first report of a move can take ~16 ms).
    private static let followTimeout: CFTimeInterval = 0.03
    /// When the slide that's taking the names out ends (timed closes only).
    private var closeEndsAt: CFTimeInterval = 0
    /// Until then the bar is turning around on the Dock's timing, which Accessibility
    /// doesn't show (it reports the end straight away).
    private var reversalEndsAt: CFTimeInterval = 0
    /// The thumbnail being dragged; the Dock hides its label while it's held.
    private var draggedElement: Int?
    /// Where the button went down, and what was under it at that moment (the bar starts
    /// shifting as soon as the pointer moves, so this can't be worked out later).
    private var pressLocation: CGPoint?
    private var pressTarget: PressTarget?
    private enum PressTarget {
        /// The + or × buttons, which don't leave Mission Control.
        case control
        case desktop(display: CGDirectDisplayID, element: Int, isThumbnail: Bool, isCurrent: Bool)
        case background
    }

    /// A click we expect to close Mission Control; cleared once the Dock confirms.
    private var predictedExit: DispatchWorkItem?
    private var launcherObservation: NSKeyValueObservation?
    private var mouseTap: CFMachPort?
    private var mouseTapSource: CFRunLoopSource?
    private var missionControlKeys: [(keyCode: Int64, modifiers: UInt64)] = []
    private var keysLoaded = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?

    /// Mission Control is coming up (anything else on screen at its top should go).
    var onOpening: (() -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    private var isEnabled: Bool { model.preferences.showNamesInMissionControl && model.hasAccess }

    /// Whether Mission Control is on screen (or on its way), names or not.
    var isMissionControlUp: Bool {
        if phase != .idle && phase != .armed { return true }
        guard model.hasAccess, let dock = currentDock() else { return false }
        var count: CFIndex = 0
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        return AXUIElementGetAttributeValueCount(app, kAXChildrenAttribute as CFString, &count) == .success && count > 1
    }

    // MARK: Lifecycle

    func start() {
        reader.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }

        // The window server says when Mission Control starts to come up, however it was
        // asked for (keys, gestures, hot corners, the Dock icon, Launchpad, scripts).
        Self.current = self
        SNObserveWindowServerEvent(.exposeBegan) { _ in
            let now = CACurrentMediaTime()
            DispatchQueue.main.async { MainActor.assumeIsolated { MissionControlOverlay.current?.exposeBegan(at: now) } }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                switch bundleID {
                case "com.apple.exposelauncher":
                    self.arm(.interface)
                case "com.apple.dock":
                    // The Dock restarted: anything on screen is stale.
                    self.endSession()
                    self.detach()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.attachIfPossible() }
                default:
                    break
                }
            }
        }
        // Mission Control.app (Dock icon, Launchpad, Spotlight) is background-only, so it
        // never shows up in launch notifications; watch the running list instead.
        launcherObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, change in
            let launched = (change.newValue ?? []).contains { $0.bundleIdentifier == "com.apple.exposelauncher" }
            guard launched else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.arm(.interface) } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endSession()
                self?.rebuildWindows()
            }
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            let appearance = app.effectiveAppearance
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.windows.values.forEach { $0.canvas.style = LabelStyle.resolve(for: appearance) } }
            }
        }

        Publishers.CombineLatest(model.preferences.$showNamesInMissionControl, model.$hasAccess)
            .map { $0 && $1 }
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    attachIfPossible()
                    rebuildWindows()
                    reloadHotCorners()
                } else {
                    endSession()
                    detach()
                    hotCornerTimer?.invalidate()
                    hotCornerTimer = nil
                }
            }
            .store(in: &cancellables)

        // Names, the current Space and the Space order can change while Mission Control is up.
        Publishers.Merge(model.$snapshot.map { _ in () }, model.$namesRevision.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.relabel() }
            .store(in: &cancellables)
    }

    // MARK: Input

    func handle(_ key: InputMonitor.Key) {
        guard isEnabled else { return }
        if Date().timeIntervalSince(keysLoaded) > 10 { reloadMissionControlKeys() }
        guard missionControlKeys.contains(where: { $0.keyCode == key.keyCode && $0.modifiers == key.modifiers }) else { return }
        switch phase {
        case .idle, .armed, .closing:
            arm(.key, at: key.timestamp)
        case .opening, .open:
            break // This press closes Mission Control; the interface going away anchors that.
        }
    }

    func handle(_ swipe: InputMonitor.DockSwipe) {
        guard isEnabled, swipe.motion == .vertical else { return }
        switch swipe.phase {
        case .began:
            gesture = Gesture(direction: nil, fraction: currentFraction, startedAt: swipe.timestamp)
            reader.setFast(true)
        case .changed:
            guard var current = gesture else { return }
            let progress = swipe.progress
            if current.direction == nil, abs(progress) > 0.002 {
                if progress < 0, phase == .closing, isLeaving(at: swipe.timestamp) {
                    current.direction = .opening
                    current.reversing = true
                    gesture = current
                    reverseClose(at: swipe.timestamp)
                    return
                } else if progress < 0, [.idle, .armed, .closing].contains(phase) {
                    current.direction = .opening
                    beginGestureOpen()
                } else if progress > 0, [.open, .opening].contains(phase) {
                    current.direction = .closing
                    endWork?.cancel()
                } else {
                    gesture = nil // e.g. a swipe down into App Exposé
                    return
                }
                // From here the bar is wherever the Dock says it is.
                followsDock = true
            }
            guard let direction = current.direction, !current.reversing else {
                gesture = current
                return
            }
            current.progress = progress
            let travel = min(max(abs(progress) / Self.gestureTravel, 0), 1)
            current.fraction = direction == .opening ? travel : 1 - travel
            // The Dock's report of the bar is the truth, but it comes a little late; the
            // fingers lead it as long as the Dock moves the bar with them. Should the bar
            // stay put while they move on (the Dock sometimes ignores a swipe), go back to
            // where the Dock says it is.
            if current.fingersTrusted, !current.dockMoved, let (displayID, reported) = dockOffsets.first,
               swipe.timestamp - current.startedAt > Self.followTimeout {
                let height = direction == .opening ? collapsedHeight(displayID) : (layouts[displayID]?.barFrame.height ?? collapsedHeight(displayID))
                if abs(Double(1 + reported / height) - current.fraction) * Double(height) > 4 {
                    current.fingersTrusted = false
                }
            }
            gesture = current
            if current.fingersTrusted {
                setFraction(current.fraction, direction: direction)
            } else {
                followDock(dockOffsets, at: swipe.timestamp)
            }
        case .ended, .cancelled:
            guard let current = gesture, let direction = current.direction else {
                gesture = nil
                return
            }
            gesture = nil
            guard !current.reversing else { return }
            // The Dock decides whether the swipe completes and animates the rest itself,
            // publishing the bar's position as it goes, or leaves; follow that. Only if it
            // never said where the bar is, finish on our own after a moment.
            followsDock = true
            releaseFallback?.cancel()
            if dockOffsets.isEmpty {
                let commit = swipe.phase == .ended
                let time = swipe.timestamp
                let fallback = DispatchWorkItem { [weak self] in
                    guard let self, dockOffsets.isEmpty else { return }
                    finishGesture(direction, commit: commit, at: time)
                }
                releaseFallback = fallback
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: fallback)
            } else {
                followDock(dockOffsets, at: swipe.timestamp)
            }
        case .other:
            break
        }
    }

    private func reloadMissionControlKeys() {
        keysLoaded = Date()
        missionControlKeys = SymbolicHotKeys.missionControl().map {
            (Int64($0.keyCode), $0.modifierFlags & InputMonitor.modifierMask)
        }
    }

    // MARK: Watching the Dock

    private func currentDock() -> NSRunningApplication? {
        if let dock, !dock.isTerminated { return dock }
        dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        return dock
    }

    private func attachIfPossible() {
        guard observer == nil, isEnabled, let dock = currentDock() else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, context in
            guard let context else { return }
            let overlay = Unmanaged<MissionControlOverlay>.fromOpaque(context).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { overlay.handleDockNotification(name) }
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let opened = AXObserverAddNotification(created, element, "AXExposeShowAllWindows" as CFString, context)
        AXObserverAddNotification(created, element, "AXExposeExit" as CFString, context)
        guard opened == .success else {
            log.error("couldn't watch the Dock: \(opened.rawValue)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dock = nil
    }

    private func handleDockNotification(_ name: String) {
        let now = CACurrentMediaTime()
        log.debug("dock \(name, privacy: .public) at \(now)")
        switch name {
        case "AXExposeShowAllWindows":
            switch phase {
            case .idle, .armed:
                // We missed the start (nothing we could see triggered it): ease in now.
                beginLateSession()
            case .opening:
                if gesture == nil { phase = .open }
            case .open, .closing:
                break
            }
        case "AXExposeExit":
            if [.opening, .open].contains(phase), gesture?.direction != .closing {
                startClose(reference: now)
            }
        default:
            break
        }
    }

    // MARK: Arming

    private static weak var current: MissionControlOverlay?

    private func exposeBegan(at time: CFTimeInterval) {
        log.debug("window server: expose began at \(time)")
        guard phase == .idle else { return }
        arm(.interface, at: time)
    }

    private func arm(_ source: OpenSource, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard isEnabled, let dock = currentDock() else { return }
        guard [.idle, .armed, .closing].contains(phase) else { return }
        if phase == .closing {
            if isLeaving(at: time) {
                reverseClose(at: time)
                return
            }
            // Already gone from the screen: this is a fresh start.
            endSession()
        }
        openSource = source
        if phase != .closing { phase = .armed }
        reader.start(dockPID: dock.processIdentifier)
        armTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, phase == .armed, gesture == nil else { return }
            phase = .idle
            openSource = nil
            reader.stop()
        }
        armTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armTimeout, execute: work)
    }

    // MARK: Reader events

    private func handle(_ event: SpacesBarReader.Event) {
        switch event {
        case .appeared(let time):
            log.debug("interface appeared at \(time)")
            interfaceAppeared(at: time)
        case .gone(let time):
            log.debug("interface gone at \(time)")
            dockOffsets.removeAll()
            if followsDock {
                // A released swipe closed Mission Control or sprang back; the Dock has
                // already been moving the bar, so finish from where it is.
                followsDock = false
                releaseFallback?.cancel()
                if windows.values.allSatisfy({ $0.canvas.presentedOffset <= -0.9 * barHeight(for: $0) }) {
                    endSession()
                } else {
                    phase = .open
                    startClose(reference: time)
                }
            } else if [.opening, .open].contains(phase), gesture?.direction != .closing {
                startClose(reference: time)
            } else if phase == .closing, predictedExit != nil {
                // The click we acted on did close Mission Control.
                predictedExit?.cancel()
                predictedExit = nil
                if endWork == nil { endSession() }
            } else if phase == .armed, gesture == nil {
                phase = .idle
                reader.stop()
            }
        case .layout(let newLayouts, let changedAt):
            layoutChanged(newLayouts, at: changedAt)
        case .offsets(let offsets, let time):
            #if DEBUG
            log.debug("dock offset \(offsets.values.first ?? 0) at \(time) received \(CACurrentMediaTime())")
            #endif
            if !dockOffsets.isEmpty, offsets != dockOffsets, var current = gesture, time >= current.startedAt {
                current.dockMoved = true
                gesture = current
            }
            dockOffsets = offsets
            followDock(offsets, at: time)
        }
    }

    /// Mirrors the bar's live position after a swipe is released, position for position:
    /// the Dock itself steps the bar irregularly here, so copying beats smoothing.
    private func followDock(_ offsets: [CGDirectDisplayID: CGFloat], at time: CFTimeInterval) {
        guard followsDock, gesture?.reversing != true, time >= reversalEndsAt else { return }
        releaseFallback?.cancel()
        // Still under the fingers, which lead the reports.
        if let current = gesture, current.direction != nil, current.fingersTrusted { return }
        var settledIn = true
        for (displayID, offset) in offsets {
            guard let window = windows[displayID] else { continue }
            let height = layouts[displayID]?.barFrame.height ?? collapsedHeight(displayID)
            let fraction = height > 0 ? Double(1 + offset / height) : 1
            window.canvas.setSlide(offset: offset, opacity: Float(DockMotion.openingOpacity(fraction)))
            if abs(offset) > 0.5 { settledIn = false }
        }
        if settledIn, gesture == nil, phase == .opening || phase == .open {
            phase = .open
        }
    }

    private func interfaceAppeared(at time: CFTimeInterval) {
        armTimeoutWork?.cancel()
        switch phase {
        case .opening, .open:
            return
        case .idle, .armed, .closing:
            break
        }
        if phase == .closing {
            // Back before the names had gone (the Dock can drop its interface for a moment,
            // e.g. while changing Space inside Mission Control).
            reverseClose(at: time)
            return
        }
        let source = openSource ?? .interface
        if case .gesture = source { return } // the swipe already started the session
        let wasClosing = phase == .closing
        beginSession()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for window in windows.values {
            let from = wasClosing ? window.canvas.presentedOffset : -collapsedHeight(for: window)
            if reduceMotion {
                window.canvas.setSlide(offset: 0, opacity: window.canvas.presentedOpacity)
                window.canvas.fadeSlide(to: 1, duration: DockMotion.open.duration * 0.8)
                continue
            }
            window.canvas.animateSlide(from: from, to: 0, timing: DockMotion.open, reference: time, opacity: DockMotion.openingOpacity)
        }
        phase = .opening
    }

    // MARK: Sessions

    /// Whether a timed close is still taking the names out (asked back now, the Dock turns
    /// the bar around instead of opening Mission Control afresh).
    private func isLeaving(at time: CFTimeInterval) -> Bool {
        phase == .closing && time < closeEndsAt - 0.01
    }

    /// Mission Control was asked back while it was leaving. The Dock turns the bar around
    /// from wherever it is, as it was (thumbnails stay thumbnails), on a fixed ease; it
    /// doesn't follow a swipe that asked for it, and Accessibility shows only the end.
    private func reverseClose(at time: CFTimeInterval) {
        guard let dock = currentDock() else { return }
        endWork?.cancel()
        endWork = nil
        predictedExit?.cancel()
        predictedExit = nil
        armTimeoutWork?.cancel()
        releaseFallback?.cancel()
        followsDock = false
        keepOnEverySpace()
        reader.start(dockPID: dock.processIdentifier)
        let now = CACurrentMediaTime()
        for window in windows.values {
            let fromOpacity = Double(window.canvas.presentedOpacity)
            // Undo the names' growth for the way out.
            if let id = windows.first(where: { $0.value === window })?.key, let layout = layouts[id], !Self.isCollapsed(layout) {
                render(layout, transition: .resize(at: now, duration: 0.06), fadeNew: false)
            }
            window.canvas.animateSlide(from: window.canvas.presentedOffset, to: 0, timing: DockMotion.reverse, reference: time) { progress in
                fromOpacity + (1 - fromOpacity) * progress
            }
        }
        reversalEndsAt = time + DockMotion.reverse.end
        phase = .opening
    }

    /// Shows the overlay windows, with names placed from the last known layout.
    private func beginSession() {
        onOpening?()
        endWork?.cancel()
        startWatchingMouse()
        if windows.isEmpty { rebuildWindows() }
        model.refresh()
        startSnapshotRefresh()
        for (displayID, layout) in cache where layouts[displayID] == nil {
            // Only while the display is as it was (same size, so the same bar).
            guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }),
                  abs(screen.frame.width - layout.barFrame.width) < 1
            else { continue }
            render(layout, transition: nil, fadeNew: false)
        }
        for window in windows.values where !window.isVisible {
            window.canvas.setSlide(offset: -collapsedHeight(for: window), opacity: 0)
            window.orderFrontRegardless()
        }
        log.debug("session began: \(self.windows.count) windows, cache \(self.cache.count), visible \(self.windows.values.filter(\.isVisible).count)")
    }

    private func beginLateSession() {
        guard let dock = currentDock() else { return }
        armTimeoutWork?.cancel()
        reader.start(dockPID: dock.processIdentifier)
        beginSession()
        for window in windows.values {
            window.canvas.setSlide(offset: 0, opacity: window.canvas.presentedOpacity)
            window.canvas.fadeSlide(to: 1, duration: DockMotion.lateFade)
        }
        phase = .open
    }

    private func beginGestureOpen() {
        guard let dock = currentDock() else { return }
        // A close that's still on screen is turned around instead (see `reverseClose`);
        // one that has finished leaves nothing to pick up from.
        if phase == .closing { endSession() }
        armTimeoutWork?.cancel()
        openSource = .gesture
        reader.start(dockPID: dock.processIdentifier)
        beginSession()
        phase = .opening
    }

    private func startClose(reference: CFTimeInterval, afterClick: Bool = false) {
        guard phase != .closing else { return }
        phase = .closing
        followsDock = false
        releaseFallback?.cancel()
        let expanded = layouts.values.contains { !Self.isCollapsed($0) }
        let grown = expandStartedAt.map { (reference - $0 - DockMotion.expand.delay) / DockMotion.expand.duration } ?? 1
        var timing = expanded ? DockMotion.closeExpanded : DockMotion.closeCollapsed
        var distance = 1.0
        if afterClick, expanded, grown < 1 {
            (timing, distance) = DockMotion.closeExpandedAfterClick(expandProgress: grown)
        } else if afterClick {
            timing = expanded ? DockMotion.closeExpandedAfterClick : DockMotion.closeCollapsedAfterClick
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for window in windows.values {
            if reduceMotion {
                window.canvas.fadeSlide(to: 0, duration: timing.duration * 0.8)
            } else {
                if expanded { window.canvas.growLabels(toHeight: 24, duration: 0.06) }
                let height = barHeight(for: window) * distance
                window.canvas.animateSlide(from: window.canvas.presentedOffset, to: -height, timing: timing, reference: reference, opacity: DockMotion.closingOpacity)
            }
        }
        closeEndsAt = reference + timing.end
        scheduleEnd(at: reference + timing.end)
    }

    private func scheduleEnd(at hostTime: CFTimeInterval) {
        endWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            endWork = nil
            // A predicted exit that the Dock hasn't confirmed yet: keep watching.
            if predictedExit != nil { windows.values.forEach { $0.orderOut(nil) } } else { endSession() }
        }
        endWork = work
        let delay = max(0, hostTime - CACurrentMediaTime()) + 0.03
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Hides the overlay. Label layers are kept so the next session draws nothing new.
    private func endSession() {
        endWork?.cancel()
        endWork = nil
        predictedExit?.cancel()
        predictedExit = nil
        armTimeoutWork?.cancel()
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        reader.stop()
        for window in windows.values {
            window.orderOut(nil)
            window.staysOnCurrentSpace = false
            window.canvas.setSlide(offset: -collapsedHeight(for: window), opacity: 0)
        }
        layouts.removeAll()
        elementSpaces.removeAll()
        mappedOrder.removeAll()
        expandStartedAt = nil
        dockOffsets.removeAll()
        closeEndsAt = 0
        reversalEndsAt = 0
        draggedElement = nil
        pressLocation = nil
        pressTarget = nil
        stopWatchingMouse()
        gesture = nil
        followsDock = false
        releaseFallback?.cancel()
        openSource = nil
        phase = .idle
    }

    // MARK: Gestures

    private var currentFraction: Double {
        guard let (id, window) = windows.first, window.isVisible else { return phase == .open ? 1 : 0 }
        let height = layouts[id]?.barFrame.height ?? collapsedHeight(id)
        return height > 0 ? Double(1 + window.canvas.presentedOffset / height) : 0
    }

    private func setFraction(_ fraction: Double, direction: Gesture.Direction) {
        let opacity = DockMotion.openingOpacity(fraction)
        for window in windows.values {
            let height = direction == .opening ? collapsedHeight(for: window) : barHeight(for: window)
            window.canvas.setSlide(offset: -CGFloat(1 - fraction) * height, opacity: Float(opacity))
        }
    }

    private func finishGesture(_ direction: Gesture.Direction, commit: Bool, at time: CFTimeInterval) {
        let opening = (direction == .opening) == commit
        let fraction = currentFraction
        let remaining = opening ? 1 - fraction : fraction
        let timing = DockMotion.Timing(
            delay: 0,
            duration: max(0.08, DockMotion.release.duration * max(remaining, 0.35)),
            curve: DockMotion.release.curve
        )
        followsDock = false
        for window in windows.values {
            let height = opening ? collapsedHeight(for: window) : barHeight(for: window)
            let from = window.canvas.presentedOffset
            window.canvas.animateSlide(from: from, to: opening ? 0 : -height, timing: timing, reference: time) { progress in
                DockMotion.openingOpacity(fraction + (opening ? 1 - fraction : -fraction) * progress)
            }
        }
        if opening {
            phase = .opening
        } else {
            phase = .closing
            closeEndsAt = time + timing.end
            scheduleEnd(at: time + timing.end)
        }
    }

    // MARK: Layout

    private func layoutChanged(_ newLayouts: [SpacesBarReader.Layout], at time: CFTimeInterval) {
        guard phase != .idle else { return }
        // A desktop was added or removed: bring the Space list up to date first, so names
        // are matched against the new set.
        if newLayouts.contains(where: { $0.labels.count != layouts[$0.displayID]?.labels.count }) {
            model.refresh()
        }
        for layout in newLayouts {
            let placedFromCache = windows[layout.displayID]?.canvas.labels.isEmpty == false
            let previous = layouts[layout.displayID] ?? (placedFromCache ? cache[layout.displayID] : nil)
            layouts[layout.displayID] = layout
            var transition: LabelTransition?
            // While the mouse is down (a drag, or a window being moved between Spaces),
            // place labels directly rather than easing them.
            let dragging = NSEvent.pressedMouseButtons & 1 != 0
            if let previous, previous.labels.map(\.frame) != layout.labels.map(\.frame), phase != .closing, !dragging {
                transition = Self.transition(from: previous, to: layout, at: time)
                if Self.isCollapsed(previous), !Self.isCollapsed(layout) { expandStartedAt = time }
            }
            // Names placed from nothing (no earlier layout to start from) go straight on;
            // only names added to ones already showing fade in.
            render(layout, transition: transition, fadeNew: placedFromCache)
            if Self.isCollapsed(layout), !layout.labels.isEmpty { cache[layout.displayID] = layout }
        }
    }

    /// Re-derives names for the current layouts (renames, reorders, a new current Space).
    private func relabel() {
        guard phase != .idle else { return }
        // Pinned to the current Space only for a desktop click's zoom; if the Space changes
        // inside Mission Control instead, the names have to come along.
        if predictedExit == nil { keepOnEverySpace() }
        let now = CACurrentMediaTime()
        for layout in layouts.values {
            render(layout, transition: .shift(at: now - DockMotion.shift.delay), fadeNew: true)
        }
    }

    private func render(_ layout: SpacesBarReader.Layout, transition: LabelTransition?, fadeNew: Bool) {
        guard let window = windows[layout.displayID],
              let screen = NSScreen.screens.first(where: { $0.displayID == layout.displayID }),
              let display = displaySpaces(for: layout.displayID)
        else { return }

        let spaces = spacesForLabels(layout, display: display)
        // Accessibility uses a top-left origin at the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)

        let geometries = layout.labels.map { Self.geometry(for: $0.frame, bar: layout.barFrame, origin: origin) }
        let names: [String?] = spaces.map { space in space.flatMap { model.store.name(for: $0.key) } }
        let widths = OverlayCanvas.layoutWidths(
            centers: geometries.map(\.center.x),
            baseWidths: geometries.map(\.size.width),
            names: names,
            textScale: geometries.map(\.textScale),
            nativeWidths: layout.labels.map { $0.frame.height >= 40 ? 59 : $0.frame.width }
        )

        var targets: [OverlayCanvas.Target] = []
        for (index, space) in spaces.enumerated() {
            guard let space, let name = names[index], layout.labels[index].element != draggedElement else { continue }
            targets.append(OverlayCanvas.Target(
                key: space.key,
                name: name,
                isCurrent: space.managedID == display.currentManagedID,
                geometry: geometries[index],
                maxWidth: widths[index]
            ))
        }
        window.canvas.update(targets, transition: transition, fadeNew: fadeNew)
        log.debug("render display \(layout.displayID): \(layout.labels.count) labels, \(targets.count) names, visible=\(window.isVisible), offset=\(window.canvas.presentedOffset), opacity=\(window.canvas.presentedOpacity)")
    }

    private func displaySpaces(for displayID: CGDirectDisplayID) -> DisplaySpaces? {
        model.snapshot.displays.first { DisplayResolver.displayID(for: $0.id) == displayID }
            ?? (model.snapshot.displays.count == 1 ? model.snapshot.displays.first : nil)
    }

    /// The Space behind each label. Positions are trusted only when the window server's
    /// Space order has caught up with the bar; otherwise each Dock element keeps the Space
    /// it was first matched with, which is what keeps names right during and after a drag.
    private func spacesForLabels(_ layout: SpacesBarReader.Layout, display: DisplaySpaces) -> [Space?] {
        let id = layout.displayID
        let order = display.spaces.map(\.key)
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        if !dragging, layout.labels.count == display.spaces.count, mappedOrder[id] != order || elementSpaces[id] == nil {
            elementSpaces[id] = Dictionary(uniqueKeysWithValues: zip(layout.labels.map(\.element), order))
            mappedOrder[id] = order
        }
        let byKey = Dictionary(uniqueKeysWithValues: display.spaces.map { ($0.key, $0) })
        let known = elementSpaces[id] ?? [:]
        let fallback = Self.match(layout.labels, to: display.spaces)
        return layout.labels.enumerated().map { index, label in
            if let key = known[label.element] { return byKey[key] }
            return fallback[index]
        }
    }

    // MARK: Dragging thumbnails

    /// Listens for clicks and drags only while Mission Control is up.
    private func startWatchingMouse() {
        guard mouseTap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            if let context {
                let overlay = Unmanaged<MissionControlOverlay>.fromOpaque(context).takeUnretainedValue()
                let location = event.location
                let stamp = Double(event.timestamp) / 1_000_000_000
                MainActor.assumeIsolated { overlay.handleMouse(type, at: location, time: stamp) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        mouseTap = tap
        mouseTapSource = source
    }

    private func stopWatchingMouse() {
        guard let mouseTap else { return }
        CGEvent.tapEnable(tap: mouseTap, enable: false)
        if let mouseTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), mouseTapSource, .commonModes) }
        CFMachPortInvalidate(mouseTap)
        self.mouseTap = nil
        mouseTapSource = nil
    }

    /// `location` is in global top-left coordinates, like the Dock's frames.
    private func handleMouse(_ type: CGEventType, at location: CGPoint, time: CFTimeInterval) {
        #if DEBUG
        if type == .leftMouseUp { log.debug("mouse up at \(time) x=\(Int(location.x)) y=\(Int(location.y))") }
        #endif
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: true) }
        case .leftMouseDown:
            pressLocation = location
            let target = self.target(at: location)
            pressTarget = target
            if case .desktop(let display, _, _, false) = target, [.open, .opening].contains(phase) {
                // Clicking this would zoom another desktop up over the bar; be under it
                // before it starts.
                windows[display]?.staysOnCurrentSpace = true
            }
        case .leftMouseDragged:
            guard draggedElement == nil, let start = pressLocation,
                  case .desktop(let display, let element, true, _) = pressTarget,
                  hypot(location.x - start.x, location.y - start.y) > 4
            else { return }
            // Picked up a thumbnail; the Dock hides its name while it's held.
            draggedElement = element
            windows[display]?.staysOnCurrentSpace = false
            if let layout = layouts[display] { render(layout, transition: nil, fadeNew: true) }
        case .leftMouseUp:
            let start = pressLocation
            let target = pressTarget
            pressLocation = nil
            pressTarget = nil
            if draggedElement == nil {
                if let start, let target, hypot(location.x - start.x, location.y - start.y) <= 4 {
                    handleClick(on: target, time: time)
                } else {
                    keepOnEverySpace()
                }
                return
            }
            // Dropped: show the name again once the Dock has settled the new order.
            draggedElement = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                model.refresh()
                for layout in layouts.values { render(layout, transition: nil, fadeNew: true) }
            }
        default:
            break
        }
    }

    /// Which of the Dock's animations turns `old` into `new`; each moves names differently.
    static func transition(from old: SpacesBarReader.Layout, to new: SpacesBarReader.Layout, at time: CFTimeInterval) -> LabelTransition {
        if new.labels.count > old.labels.count { return .add(at: time) }
        if new.labels.count < old.labels.count { return .remove(at: time) }
        if isCollapsed(old) && !isCollapsed(new) { return .expand(at: time) }
        return .shift(at: time)
    }

    // MARK: Clicks

    /// What the pointer is over: a desktop (its thumbnail, or its name in the names-only
    /// bar), one of the bar's buttons, or anything else.
    private func target(at location: CGPoint) -> PressTarget {
        for layout in layouts.values {
            if let add = layout.addFrame, add.contains(location) { return .control }
            for (index, label) in layout.labels.enumerated() {
                let isThumbnail = label.frame.height >= 40
                if isThumbnail {
                    // The × that removes a desktop sits on a thumbnail's top-left corner.
                    let remove = CGRect(x: label.frame.minX - 14, y: label.frame.minY - 14, width: 28, height: 28)
                    if remove.contains(location) { return .control }
                }
                let area = isThumbnail ? label.frame : Self.geometry(for: label.frame, bar: layout.barFrame, origin: .zero).hitRect
                guard area.contains(location) else { continue }
                let display = displaySpaces(for: layout.displayID)
                let space = display.flatMap { spacesForLabels(layout, display: $0)[index] }
                let isCurrent = space != nil && space?.managedID == display?.currentManagedID
                return .desktop(display: layout.displayID, element: label.element, isThumbnail: isThumbnail, isCurrent: isCurrent)
            }
        }
        return .background
    }

    /// Any plain click in Mission Control leaves it, except on the + and × buttons. The
    /// Dock keeps its interface around for ~250 ms afterwards, so act on the click itself.
    private func handleClick(on target: PressTarget, time: CFTimeInterval) {
        let barMoving = dockOffsets.values.contains { abs($0) > 0.5 } || CACurrentMediaTime() < reversalEndsAt
        guard [.open, .opening].contains(phase), gesture == nil, !barMoving else {
            keepOnEverySpace()
            return
        }
        switch target {
        case .control:
            return
        case .desktop(_, _, _, false):
            // That desktop zooms up over the bar, which hides the names where they are,
            // the windows having been moved under the zoom on the way down.
            phase = .closing
        case .desktop, .background:
            // The bar slides away, just as it does when leaving with a key.
            startClose(reference: time, afterClick: true)
        }
        // If Mission Control stays up after all, bring the names back.
        let restore = DispatchWorkItem { [weak self] in self?.restoreAfterMissedExit() }
        predictedExit?.cancel()
        predictedExit = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: restore)
    }

    private func keepOnEverySpace() {
        windows.values.forEach { $0.staysOnCurrentSpace = false }
    }

    private func restoreAfterMissedExit() {
        guard predictedExit != nil, phase == .closing else { return }
        predictedExit = nil
        endWork?.cancel()
        endWork = nil
        phase = .open
        keepOnEverySpace()
        for window in windows.values {
            if !window.isVisible { window.orderFrontRegardless() }
            window.canvas.setSlide(offset: 0, opacity: window.canvas.presentedOpacity)
            window.canvas.fadeSlide(to: 1, duration: DockMotion.lateFade)
        }
    }

    static func isCollapsed(_ layout: SpacesBarReader.Layout) -> Bool {
        layout.labels.allSatisfy { $0.frame.height < 40 }
    }

    /// Where the Dock draws a Space's name, from the frame it reports for that Space.
    ///
    /// Collapsed, the bar shows only names and the reported frame is the name's pill,
    /// though current releases report it one bar-height too high. Expanded (hovered),
    /// the frame is the thumbnail and the name, drawn about 12% smaller, sits centred
    /// 14 pt below it (measured from screen captures).
    static func geometry(for frame: CGRect, bar: CGRect, origin: CGPoint) -> LabelGeometry {
        if frame.height >= 40 {
            return LabelGeometry(
                center: CGPoint(x: frame.midX - origin.x, y: frame.maxY + 14 - origin.y),
                size: CGSize(width: 67, height: 18),
                textScale: 0.877
            )
        }
        var label = frame
        if label.minY < bar.minY { label.origin.y += bar.height }
        return LabelGeometry(
            center: CGPoint(x: label.midX - origin.x, y: label.midY - origin.y),
            // Wide enough to keep the Dock's label covered through any timing jitter.
            size: CGSize(width: label.width + 8, height: label.height),
            textScale: 1
        )
    }

    /// Pairs labels with Spaces. Labels list Spaces in order, so match by position when the
    /// counts agree; mid-change, fall back to the number in "Desktop N".
    static func match(_ labels: [SpacesBarReader.Label], to spaces: [Space]) -> [Space?] {
        if labels.count == spaces.count { return spaces.map(Optional.some) }
        return labels.map { label in
            guard let number = label.title.split(separator: " ").last.flatMap({ Int($0) }) else { return nil }
            return spaces.first { $0.desktopNumber == number }
        }
    }

    /// The names-only bar's height on a display, as last measured there (it is 78 pt on
    /// the displays measured so far, which is the guess until it has been seen).
    private func collapsedHeight(_ id: CGDirectDisplayID?) -> CGFloat {
        id.flatMap { cache[$0]?.barFrame.height } ?? Self.collapsedBarHeight
    }

    private func collapsedHeight(for window: OverlayWindow) -> CGFloat {
        collapsedHeight(windows.first { $0.value === window }?.key)
    }

    private func barHeight(for window: OverlayWindow) -> CGFloat {
        let id = windows.first { $0.value === window }?.key
        return id.flatMap { layouts[$0]?.barFrame.height } ?? collapsedHeight(id)
    }

    // MARK: Windows

    private func rebuildWindows() {
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
        guard isEnabled else { return }
        let style = LabelStyle.resolve(for: NSApp.effectiveAppearance)
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let window = OverlayWindow(screen: screen)
            window.canvas.style = style
            window.canvas.setSlide(offset: -collapsedHeight(for: window), opacity: 0)
            windows[id] = window
        }
    }

    private func startSnapshotRefresh() {
        guard snapshotTimer == nil else { return }
        let timer = Timer(timeInterval: Self.snapshotInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        snapshotTimer = timer
    }

    // MARK: Hot corners

    /// Watches the pointer (cheaply, 15 times a second) only when a hot corner opens
    /// Mission Control, so those opens can be animated from their very start too.
    private func reloadHotCorners() {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        hotCorners = ["tl", "tr", "bl", "br"].filter { dockDefaults?.integer(forKey: "wvous-\($0)-corner") == 2 }
        hotCornerTimer?.invalidate()
        hotCornerTimer = nil
        guard !hotCorners.isEmpty else { return }
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHotCorners() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        hotCornerTimer = timer
    }

    private func checkHotCorners() {
        let point = NSEvent.mouseLocation
        let inCorner = NSScreen.screens.contains { screen in
            let frame = screen.frame
            return hotCorners.contains { corner in
                let x = corner.hasSuffix("l") ? frame.minX : frame.maxX - 1
                let y = corner.hasPrefix("b") ? frame.minY : frame.maxY - 1
                return abs(point.x - x) <= 2 && abs(point.y - y) <= 2
            }
        }
        if inCorner, !cornerLatched {
            cornerLatched = true
            arm(.interface)
        } else if !inCorner {
            cornerLatched = false
        }
    }
}
