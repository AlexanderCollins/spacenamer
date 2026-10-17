import ApplicationServices
import CGSBridge
import CoreGraphics
import Foundation

/// Posts the synthetic input used to change Spaces. Everything here goes through public
/// event-posting APIs, so it needs the Accessibility permission but never SIP changes.
public enum EventSynth {
    public static var canPost: Bool { CGPreflightPostEventAccess() }

    /// True when both posting events (switching) and reading other apps' interface
    /// (Mission Control labels) are allowed. One Accessibility switch grants both.
    public static var hasAccess: Bool { CGPreflightPostEventAccess() && AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security › Accessibility.
    @discardableResult
    public static func requestAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Swipes `count` Spaces left (-1) or right (+1) on the display under the cursor.
    /// Each swipe ends with enough velocity that the Dock skips its slide animation, and
    /// the Dock merges back-to-back swipes into one move. Overshooting the first or last
    /// Space cancels the whole move, so `count` must be exact.
    @discardableResult
    public static func swipe(direction: Int, count: Int = 1) -> Bool {
        let distance = direction < 0 ? -1.0 : 1.0
        var posted = true
        for _ in 0..<max(1, count) {
            posted = SNPostDockSwipe(.began, 0, 0)
                && SNPostDockSwipe(.changed, distance * 0.1, 0)
                && SNPostDockSwipe(.ended, distance, distance * 4000)
                && posted
        }
        return posted
    }

    public static func press(_ shortcut: SystemShortcut) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags(rawValue: shortcut.modifierFlags)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}
