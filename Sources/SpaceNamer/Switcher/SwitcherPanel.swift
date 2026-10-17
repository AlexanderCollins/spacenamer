import AppKit

/// A borderless panel that takes keyboard focus without activating the app, so the app
/// you were using stays frontmost and gets focus straight back when the panel closes.
final class SwitcherPanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?
    var cancelHandler: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        cancelHandler?()
    }
}

/// Rounded selection that matches the system's inset list style.
final class SwitcherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 8, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        path.fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

/// Number (or full-screen) badge drawn to match selection state.
final class BadgeView: NSView {
    var text: String? { didSet { needsDisplay = true } }
    var isFullscreen = false { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }
    var isOnSelection = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let fill: NSColor
        let ink: NSColor
        if isOnSelection {
            fill = NSColor.white.withAlphaComponent(isCurrent ? 0.95 : 0.22)
            ink = isCurrent ? NSColor.selectedContentBackgroundColor : .white
        } else if isCurrent {
            fill = .controlAccentColor
            ink = .white
        } else {
            fill = .quaternaryLabelColor
            ink = .labelColor
        }
        fill.setFill()
        path.fill()

        if isFullscreen {
            let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            guard let symbol = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            let tinted = NSImage(size: symbol.size, flipped: false) { imageRect in
                symbol.draw(in: imageRect)
                ink.set()
                imageRect.fill(using: .sourceAtop)
                return true
            }
            let origin = NSPoint(x: bounds.midX - symbol.size.width / 2, y: bounds.midY - symbol.size.height / 2)
            tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }

        guard let text else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: ink,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let point = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}
