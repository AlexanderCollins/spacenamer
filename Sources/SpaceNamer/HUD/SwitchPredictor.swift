import AppKit
import SpaceNamerCore

/// Spots a Space switch the moment it starts, rather than when macOS reports it at the
/// end of its slide animation (about a second for ⌃← / ⌃→), so the name shows at once.
/// Fed by `InputMonitor`: key presses matching the user's Mission Control shortcuts, and
/// the Dock's horizontal swipe gesture.
@MainActor
final class SwitchPredictor {
    enum Move {
        case relative(Int)
        case position(Int)
    }

    private struct Binding {
        let keyCode: Int64
        let modifiers: UInt64
        let move: Move
    }

    var onMove: ((Move) -> Void)?
    /// Swipe direction that means "next Space"; shared with the navigator's calibration.
    var swipeSign: () -> Int = { 1 }
    var isEnabled = false {
        didSet { if isEnabled { reloadBindings() } }
    }

    private var bindings: [Binding] = []
    private var bindingsLoaded = Date.distantPast

    func handle(_ key: InputMonitor.Key) {
        guard isEnabled else { return }
        if let binding = bindings.first(where: { $0.keyCode == key.keyCode && $0.modifiers == key.modifiers }) {
            onMove?(binding.move)
        }
        if Date().timeIntervalSince(bindingsLoaded) > 10 { reloadBindings() }
    }

    func handle(_ swipe: InputMonitor.DockSwipe) {
        guard isEnabled, swipe.motion == .horizontal, swipe.phase == .ended else { return }
        // The Dock completes a swipe that got halfway, or that was flicked in its direction.
        let flicked = abs(swipe.velocity) >= 0.8 && (swipe.velocity > 0) == (swipe.progress > 0)
        guard abs(swipe.progress) >= 0.5 || (flicked && abs(swipe.progress) >= 0.05) else { return }
        onMove?(.relative((swipe.progress > 0 ? 1 : -1) * swipeSign()))
    }

    private func reloadBindings() {
        bindingsLoaded = Date()
        var result: [Binding] = []
        func add(_ shortcut: SystemShortcut?, _ move: Move) {
            guard let shortcut else { return }
            result.append(Binding(keyCode: Int64(shortcut.keyCode), modifiers: shortcut.modifierFlags & InputMonitor.modifierMask, move: move))
        }
        add(SymbolicHotKeys.moveSpace(direction: -1), .relative(-1))
        add(SymbolicHotKeys.moveSpace(direction: 1), .relative(1))
        for number in 1...16 {
            add(SymbolicHotKeys.switchToDesktop(number), .position(number))
        }
        bindings = result
    }
}
