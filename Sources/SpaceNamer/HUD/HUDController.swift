import AppKit
import SpaceNamerCore

/// A compact, click-through pill naming the Space you just arrived on. It appears at
/// full opacity the moment the switch registers, then fades away.
@MainActor
final class HUDController {
    private static let visibleDuration: TimeInterval = 0.85
    private static let height: CGFloat = 38
    private static let edgeMargin: CGFloat = 10

    private let panel: NSPanel
    private let badge = BadgeView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let dots = PageDotsView()
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.height / 2
        background.layer?.masksToBounds = true
        panel.contentView = background

        badge.isCurrent = true
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [badge, titleLabel, dots])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.setCustomSpacing(14, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 22),
        ])

        // A window on every Space is still drawn as part of whichever one is showing, so
        // it would slide away with the Space being left. In a space of its own above the
        // desktops it stays put; it's kept ordered in (clear while hidden) so it never
        // drops back onto a desktop.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        OverlaySpace.adopt(panel)
    }

    func show(
        title: String,
        space: Space,
        display: DisplaySpaces?,
        on screen: NSScreen?,
        position: Preferences.HUDPosition,
        duration: TimeInterval? = nil
    ) {
        guard let screen = screen ?? NSScreen.main else { return }

        titleLabel.stringValue = title
        badge.text = space.position.map(String.init)
        badge.isFullscreen = space.kind == .fullscreen
        if let display, display.spaces.count > 1 {
            dots.configure(spaces: display.spaces, currentID: space.managedID)
            dots.isHidden = false
        } else {
            dots.isHidden = true
        }

        let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
        let dotsWidth = dots.isHidden ? 0 : dots.intrinsicContentSize.width + 14
        let width = min(8 + 26 + 10 + titleWidth + dotsWidth + 16, screen.visibleFrame.width * 0.6)

        let visible = screen.visibleFrame
        let y: CGFloat
        switch position {
        case .top: y = visible.maxY - Self.edgeMargin - Self.height
        case .center: y = visible.midY - Self.height / 2
        case .bottom: y = visible.minY + Self.edgeMargin * 6
        }
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: y, width: width, height: Self.height), display: true)

        hideWork?.cancel()
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (duration ?? Self.visibleDuration), execute: work)
    }

    /// Gone at once, e.g. as Mission Control opens over it.
    func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        panel.alphaValue = 0
    }

    private func hide() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }
    }
}

/// One dot per Space on the display (a bar for full-screen Spaces), current one lit.
final class PageDotsView: NSView {
    private var kinds: [SpaceKind] = []
    private var currentIndex: Int?
    private static let dot: CGFloat = 6
    private static let spacing: CGFloat = 5

    func configure(spaces: [Space], currentID: UInt64) {
        kinds = spaces.map(\.kind)
        currentIndex = spaces.firstIndex { $0.managedID == currentID }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let widths = kinds.map { $0 == .fullscreen ? Self.dot * 2 : Self.dot }
        let total = widths.reduce(0, +) + Self.spacing * CGFloat(max(0, kinds.count - 1))
        return NSSize(width: max(total, 1), height: Self.dot)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x = (bounds.width - intrinsicContentSize.width) / 2
        let y = (bounds.height - Self.dot) / 2
        for (index, kind) in kinds.enumerated() {
            let width = kind == .fullscreen ? Self.dot * 2 : Self.dot
            let rect = NSRect(x: x, y: y, width: width, height: Self.dot)
            NSColor.white.withAlphaComponent(index == currentIndex ? 0.95 : 0.3).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.dot / 2, yRadius: Self.dot / 2).fill()
            x += width + Self.spacing
        }
    }
}
