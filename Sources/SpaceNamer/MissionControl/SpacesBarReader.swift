import ApplicationServices
import QuartzCore

/// Watches the Dock's Mission Control interface through Accessibility on a background
/// queue, so a slow reply from the Dock can never stall the overlay's rendering.
///
/// It only runs while Mission Control is (or is about to be) on screen. Each tick costs two
/// tiny Accessibility round trips per display; the full layout is re-read when something
/// moves and every 100 ms otherwise, to catch Spaces being added, removed or reordered.
///
/// Layouts are reported at rest (as they are with the bar fully in), with the bar's live
/// offset reported separately. During a swipe the Dock moves the bar frame by frame and
/// says so, but inconsistently: name-only labels report positions that ride along with
/// the bar, while thumbnails keep reporting where they rest. `restFrame` undoes that, so a
/// moving bar never looks like a layout change. Timed animations only ever report the end.
final class SpacesBarReader: @unchecked Sendable {
    struct Label: Equatable {
        /// Identity of the Dock's element for this Space; it survives reordering, while
        /// titles ("Desktop N") are renumbered by position.
        let element: Int
        let title: String
        /// Global, top-left-origin coordinates, exactly as the Dock reports them.
        let frame: CGRect
    }

    struct Layout: Equatable {
        let displayID: CGDirectDisplayID
        /// Bar and label frames as they are when the bar is fully in.
        let barFrame: CGRect
        let labels: [Label]
        /// The "add desktop" button, so clicks on it aren't mistaken for leaving.
        var addFrame: CGRect?
    }

    enum Event {
        /// Mission Control's interface appeared or went away. Times are host times
        /// (`CACurrentMediaTime`), estimated halfway between the two polls that saw it.
        case appeared(CFTimeInterval)
        case gone(CFTimeInterval)
        case layout([Layout], changedAt: CFTimeInterval)
        /// How far each bar currently sits above its resting position (0 = fully in,
        /// negative = sliding out of the top of the screen).
        case offsets([CGDirectDisplayID: CGFloat], at: CFTimeInterval)
    }

    private final class Bar {
        let displayID: CGDirectDisplayID
        let bar: AXUIElement
        let list: AXUIElement
        let addButton: AXUIElement?
        var firstButton: AXUIElement?

        init(displayID: CGDirectDisplayID, bar: AXUIElement, list: AXUIElement, addButton: AXUIElement?) {
            self.displayID = displayID
            self.bar = bar
            self.list = list
            self.addButton = addButton
        }
    }

    private static let interval: TimeInterval = 1.0 / 250
    /// While a swipe moves the bar, poll twice as often so each new position reliably
    /// reaches the screen on the very next frame.
    private static let fastInterval: TimeInterval = 1.0 / 500
    private static let fullReadInterval: CFTimeInterval = 0.1

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "SpaceNamer.SpacesBarReader", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var app: AXUIElement?
    private var missionControl: AXUIElement?
    private var bars: [Bar] = []
    private var present = false
    private var lastTick: CFTimeInterval = 0
    private var lastFullRead: CFTimeInterval = 0
    private var lastLayouts: [Layout] = []
    private var lastQuick: [CGRect] = []
    private var lastOffsets: [CGDirectDisplayID: CGFloat] = [:]
    private var fast = false
    private var absentSince: CFTimeInterval?
    private static let goneAfter: CFTimeInterval = 0.012

    /// Starts polling the given Dock process. Safe to call repeatedly.
    func start(dockPID: pid_t) {
        queue.async { [self] in
            guard timer == nil else { return }
            let element = AXUIElementCreateApplication(dockPID)
            AXUIElementSetMessagingTimeout(element, 0.1)
            app = element
            missionControl = nil
            bars = []
            present = false
            absentSince = nil
            lastLayouts = []
            lastQuick = []
            lastTick = CACurrentMediaTime()
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Faster polling while the bar is being moved by a swipe.
    func setFast(_ fast: Bool) {
        queue.async { [self] in
            guard fast != self.fast else { return }
            self.fast = fast
            timer?.schedule(deadline: .now(), repeating: fast ? Self.fastInterval : Self.interval, leeway: .microseconds(250))
        }
    }

    func stop() {
        queue.async { [self] in
            fast = false
            absentSince = nil
            timer?.cancel()
            timer = nil
            app = nil
            missionControl = nil
            bars = []
            present = false
        }
    }

    // MARK: Polling

    private func tick() {
        guard let app else { return }
        let now = CACurrentMediaTime()
        let estimate = (now + lastTick) / 2
        defer { lastTick = now }

        let isPresent = missionControlGroup(in: app) != nil
        if isPresent {
            absentSince = nil
        } else if present, absentSince == nil {
            absentSince = estimate
        }
        // Gone only once it stays gone for a few polls: the Dock rebuilds its interface now
        // and then (changing Space inside Mission Control), which isn't leaving.
        let confirmedGone = present && !isPresent && (absentSince.map { now - $0 >= Self.goneAfter } ?? false)
        if (isPresent && !present) || confirmedGone {
            present = isPresent
            bars = []
            lastLayouts = []
            lastQuick = []
            lastOffsets = [:]
            emit(isPresent ? .appeared(estimate) : .gone(absentSince ?? estimate))
            absentSince = nil
        }
        guard isPresent else { return }

        if bars.isEmpty { bars = resolveBars() }
        guard !bars.isEmpty else {
            missionControl = nil // possibly rebuilt; look it up afresh next time
            return
        }

        // Cheap check every tick: where the bar is, and where its first label sits in it.
        let (quick, offsets) = quickSignature()
        if offsets != lastOffsets, !offsets.isEmpty {
            lastOffsets = offsets
            emit(.offsets(offsets, at: estimate))
        }
        let moved = quick != lastQuick
        lastQuick = quick
        guard moved || now - lastFullRead >= Self.fullReadInterval || lastLayouts.isEmpty else { return }

        lastFullRead = now
        guard let layouts = readLayouts() else {
            bars = []
            missionControl = nil
            return
        }
        if layouts != lastLayouts {
            if layouts.map(\.labels.count) != lastLayouts.map(\.labels.count) {
                bars.forEach { $0.firstButton = nil }
            }
            lastLayouts = layouts
            emit(.layout(layouts, changedAt: moved ? estimate : now))
        }
    }

    private func emit(_ event: Event) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }

    // MARK: Accessibility

    private func missionControlGroup(in app: AXUIElement) -> AXUIElement? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(app, kAXChildrenAttribute as CFString, &count) == .success, count > 1 else {
            missionControl = nil
            return nil
        }
        if let missionControl { return missionControl }
        missionControl = children(of: app).first { identifier(of: $0) == "mc" }
        return missionControl
    }

    private func resolveBars() -> [Bar] {
        guard let missionControl else { return [] }
        return children(of: missionControl).compactMap { display in
            guard identifier(of: display) == "mc.display",
                  let number = attribute(display, "AXDisplayID") as? NSNumber,
                  let bar = children(of: display).first(where: { identifier(of: $0) == "mc.spaces" })
            else { return nil }
            let parts = children(of: bar)
            guard let list = parts.first(where: { identifier(of: $0) == "mc.spaces.list" }) else { return nil }
            let add = parts.first { identifier(of: $0) == "mc.spaces.add" }
            return Bar(displayID: number.uint32Value, bar: bar, list: list, addButton: add)
        }
    }

    /// Two round trips per display: the bar's frame (its live offset) and the first label's
    /// resting frame, which changes whenever the bar expands or shifts. Additions, removals
    /// and reorders are caught by the full read.
    private func quickSignature() -> ([CGRect], [CGDirectDisplayID: CGFloat]) {
        var result: [CGRect] = []
        var offsets: [CGDirectDisplayID: CGFloat] = [:]
        for bar in bars {
            guard let barFrame = frame(of: bar.bar) else { continue }
            let offset = barFrame.minY - CGDisplayBounds(bar.displayID).minY
            offsets[bar.displayID] = offset
            if bar.firstButton == nil { bar.firstButton = children(of: bar.list).first }
            if let button = bar.firstButton, let frame = frame(of: button) {
                result.append(Self.restFrame(frame, offset: offset))
                result.append(CGRect(origin: .zero, size: barFrame.size))
            } else {
                bar.firstButton = nil
            }
        }
        return (result, offsets)
    }

    /// Where a reported frame sits with the bar at rest (see the type's notes).
    static func restFrame(_ frame: CGRect, offset: CGFloat) -> CGRect {
        frame.height < 40 ? frame.offsetBy(dx: 0, dy: -offset) : frame
    }

    private func readLayouts() -> [Layout]? {
        var layouts: [Layout] = []
        for bar in bars {
            guard let barFrame = frame(of: bar.bar) else { return nil }
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(bar.list, kAXChildrenAttribute as CFString, &value) == .success,
                  let buttons = value as? [AXUIElement]
            else { return nil }
            let offset = barFrame.minY - CGDisplayBounds(bar.displayID).minY
            let labels = buttons.compactMap(label(for:)).map { Label(element: $0.element, title: $0.title, frame: Self.restFrame($0.frame, offset: offset)) }
            let addFrame = bar.addButton.flatMap(frame(of:)).map { $0.offsetBy(dx: 0, dy: -offset) }
            layouts.append(Layout(displayID: bar.displayID, barFrame: barFrame.offsetBy(dx: 0, dy: -offset), labels: labels, addFrame: addFrame))
        }
        return layouts
    }

    /// Role, title and frame in one round trip.
    private func label(for button: AXUIElement) -> Label? {
        let names = [kAXRoleAttribute, kAXTitleAttribute, "AXFrame"] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(button, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [AnyObject], array.count == 3,
              (array[0] as? String) == (kAXButtonRole as String),
              let rect = Self.rect(from: array[2])
        else { return nil }
        return Label(element: Int(bitPattern: UInt(CFHash(button))), title: array[1] as? String ?? "", frame: rect)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func identifier(of element: AXUIElement) -> String? {
        attribute(element, kAXIdentifierAttribute) as? String
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        attribute(element, "AXFrame").flatMap(Self.rect(from:))
    }

    private static func rect(from value: AnyObject) -> CGRect? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }
}
