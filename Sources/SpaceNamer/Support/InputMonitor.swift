import AppKit
import os

/// One listen-only event tap shared by everything that needs to see input the moment it
/// happens: Space shortcuts, Mission Control shortcuts and trackpad Dock swipes.
///
/// It never modifies or blocks events and keeps nothing. Ordinary typing (keys without
/// ⌃ ⌥ ⇧ ⌘ or function keys) is dropped on arrival.
@MainActor
final class InputMonitor {
    struct Key {
        let keyCode: Int64
        /// ⌃ ⌥ ⇧ ⌘ only, in CGEventFlags bits.
        let modifiers: UInt64
        /// Host time (as `CACurrentMediaTime`) the key went down.
        let timestamp: CFTimeInterval
    }

    struct DockSwipe {
        enum Motion { case horizontal, vertical, other }
        enum Phase { case began, changed, ended, cancelled, other }
        let motion: Motion
        let phase: Phase
        let progress: Double
        let velocity: Double
        let timestamp: CFTimeInterval
    }

    static let modifierMask = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskShift.rawValue | CGEventFlags.maskCommand.rawValue
    private static let dockGestureType: UInt32 = 30
    private static let functionKeyCodes: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90, 160]

    var onKey: [(Key) -> Void] = []
    var onDockSwipe: [(DockSwipe) -> Void] = []

    private let log = Logger(subsystem: "com.alexandercollins.SpaceNamer", category: "input")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << Self.dockGestureType)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    let monitor = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { monitor.handle(type, event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            log.error("couldn't create the event tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    private func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    /// Event timestamps are nanoseconds on the same clock as `CACurrentMediaTime`.
    private static func hostTime(of event: CGEvent) -> CFTimeInterval {
        let now = CACurrentMediaTime()
        let stamp = Double(event.timestamp) / 1_000_000_000
        // Guard against an unexpected clock; never report the future or a stale time.
        return (stamp > now - 1 && stamp <= now + 0.001) ? stamp : now
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let modifiers = event.flags.rawValue & Self.modifierMask
            guard modifiers != 0 || Self.functionKeyCodes.contains(keyCode) else { return }
            let key = Key(keyCode: keyCode, modifiers: modifiers, timestamp: Self.hostTime(of: event))
            onKey.forEach { $0(key) }
        default:
            guard type.rawValue == Self.dockGestureType,
                  let hidType = CGEventField(rawValue: 110),
                  event.getIntegerValueField(hidType) == 23
            else { return }
            func field(_ raw: UInt32) -> Double { CGEventField(rawValue: raw).map { event.getDoubleValueField($0) } ?? 0 }
            let motion: DockSwipe.Motion
            switch Int(field(123)) {
            case 1: motion = .horizontal
            case 2: motion = .vertical
            default: motion = .other
            }
            let phase: DockSwipe.Phase
            switch Int(field(132)) {
            case 1: phase = .began
            case 2: phase = .changed
            case 4: phase = .ended
            case 8: phase = .cancelled
            default: phase = .other
            }
            let swipe = DockSwipe(
                motion: motion,
                phase: phase,
                progress: field(124),
                velocity: motion == .vertical ? field(130) : field(129),
                timestamp: Self.hostTime(of: event)
            )
            #if DEBUG
            log.debug("swipe motion=\(String(describing: swipe.motion), privacy: .public) phase=\(String(describing: swipe.phase), privacy: .public) progress=\(swipe.progress) velocity=\(swipe.velocity) host=\(swipe.timestamp)")
            #endif
            onDockSwipe.forEach { $0(swipe) }
        }
    }
}
