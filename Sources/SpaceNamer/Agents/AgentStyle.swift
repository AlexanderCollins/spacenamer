import AppKit
import SpaceNamerCore

/// How agent states look everywhere they're shown.
enum AgentStyle {
    static func color(_ state: AgentState) -> NSColor {
        switch state {
        case .working: return .systemBlue
        case .needsInput: return .systemOrange
        case .done: return .systemGreen
        case .failed: return .systemRed
        case .idle: return .secondaryLabelColor
        }
    }

    /// e.g. "Working · 40%", "Needs you · Wants to use Bash", "2 need you".
    static func describe(_ status: DesktopAgentStatus) -> String {
        var text = status.state.title
        if status.count > 1 {
            switch status.state {
            case .needsInput: text = "\(status.count) need you"
            case .working: text = "\(status.count) working"
            case .done: text = "\(status.count) done"
            case .failed: text = "\(status.count) failed"
            case .idle: break
            }
        }
        if let progress = status.progress { text += " · \(Int((progress * 100).rounded()))%" }
        if let note = status.note, !note.isEmpty { text += " · \(note)" }
        return text
    }

    /// A small filled circle in the state's colour (not a template).
    static func dot(_ state: AgentState, diameter: CGFloat = 8) -> NSImage {
        let color = color(state)
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.accessibilityDescription = state.title
        return image
    }
}
