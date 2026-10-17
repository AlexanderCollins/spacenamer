import ApplicationServices
import CoreGraphics
import Foundation

/// Maps the window server's display identifiers (UUID strings, or "Main" when all
/// displays share Spaces) onto Core Graphics display IDs.
public enum DisplayResolver {
    public static let sharedSpacesIdentifier = "Main"

    public static func displayID(for identifier: String) -> CGDirectDisplayID? {
        if identifier == sharedSpacesIdentifier { return CGMainDisplayID() }
        return activeDisplays().first { uuidString(for: $0)?.caseInsensitiveCompare(identifier) == .orderedSame }
    }

    public static func uuidString(for display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    public static func cursorLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    public static func isCursor(onDisplay identifier: String) -> Bool {
        guard let target = displayID(for: identifier) else { return true }
        guard let location = cursorLocation() else { return true }
        return CGDisplayBounds(target).contains(location)
    }

    /// Moves the pointer to the middle of a display so gestures and Mission Control
    /// shortcuts apply to that display.
    public static func moveCursor(toDisplay identifier: String) {
        guard let target = displayID(for: identifier) else { return }
        let bounds = CGDisplayBounds(target)
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
}
