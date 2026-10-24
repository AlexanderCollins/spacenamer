import AppKit
import CGSBridge

/// A space of our own above the desktops. Windows in it stay put while Spaces slide past
/// during a switch: a window that is merely on every Space is drawn as part of each of
/// them, so it slides with them, and the seam between them shows through.
///
/// It's at the desktops' own level (its windows still draw above theirs), because the
/// window server raises a full-screen app's space a level while it zooms into or out of
/// Mission Control, over the Spaces bar; one level up, the names would show through it.
enum OverlaySpace {
    static let id: UInt64? = {
        let space = SNCreateOverlaySpace(0)
        return space == 0 ? nil : space
    }()

    /// Moves a window (already ordered in) into the overlay space, out of every desktop.
    static func adopt(_ window: NSWindow) {
        guard let id, window.windowNumber > 0 else { return }
        SNMoveWindowToSpace(UInt32(window.windowNumber), id)
    }

    /// Moves a window out of the overlay space onto one desktop (by managed ID).
    static func lend(_ window: NSWindow, toDesktop desktop: UInt64) {
        guard window.windowNumber > 0 else { return }
        SNAddWindowToSpace(UInt32(window.windowNumber), desktop)
        if let id { SNRemoveWindowFromSpace(UInt32(window.windowNumber), id) }
    }
}
