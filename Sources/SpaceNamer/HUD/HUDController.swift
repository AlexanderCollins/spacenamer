import AppKit
import SpaceNamerCore

/// A compact, click-through pill naming the Space you just arrived on. It appears at
/// full opacity the moment the switch registers, then fades away.
///
/// It also says when an agent has finished on a desktop (see `FinishAlerts`): it pops in,
/// fills with green from the left, and checks itself off.
@MainActor
final class HUDController {
    private static let visibleDuration: TimeInterval = 0.85
    private static let finishedDuration: TimeInterval = 2.6
    private static let height: CGFloat = 38
    private static let edgeMargin: CGFloat = 10
    /// Clear room around the pill inside its window, so it can overshoot as it pops in.
    private static let inset: CGFloat = 14

    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let flood = FinishFloodView()
    private let badge = BadgeView()
    private let check = CheckBadgeView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let dots = PageDotsView()
    private var hideWork: DispatchWorkItem?
    private var shadowWork: DispatchWorkItem?

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

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.height / 2
        background.layer?.masksToBounds = true
        let container = NSView()
        container.addSubview(background)
        panel.contentView = container

        flood.autoresizingMask = [.width, .height]
        background.addSubview(flood)

        badge.isCurrent = true
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        detailLabel.isHidden = true
        check.isHidden = true

        let stack = NSStackView(views: [badge, check, titleLabel, detailLabel, dots])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.setCustomSpacing(6, after: titleLabel)
        stack.setCustomSpacing(14, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 22),
            check.widthAnchor.constraint(equalToConstant: CheckBadgeView.size),
            check.heightAnchor.constraint(equalToConstant: CheckBadgeView.size),
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
        setFinished(false)
        titleLabel.stringValue = title
        badge.text = space.position.map(String.init)
        badge.isFullscreen = space.kind == .fullscreen
        showDots(for: space, display: display)

        let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
        let dotsWidth = dots.isHidden ? 0 : dots.intrinsicContentSize.width + 14
        place(width: 8 + 26 + 10 + titleWidth + dotsWidth + 16, on: screen, position: position)
        present(for: duration ?? Self.visibleDuration)
    }

    /// An agent has finished on `space` (if known): the pill pops in naming it, floods
    /// green and checks itself off, and stays a little longer than for a switch.
    func showFinished(
        title: String,
        detail: String,
        space: Space?,
        display: DisplaySpaces?,
        on screen: NSScreen?,
        position: Preferences.HUDPosition
    ) {
        guard let screen = screen ?? NSScreen.main else { return }
        setFinished(true)
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        if let space { showDots(for: space, display: display) } else { dots.isHidden = true }

        let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
        let detailWidth = ceil(detailLabel.intrinsicContentSize.width) + 6
        let dotsWidth = dots.isHidden ? 0 : dots.intrinsicContentSize.width + 14
        place(width: 8 + CheckBadgeView.size + 10 + titleWidth + detailWidth + dotsWidth + 16, on: screen, position: position)
        present(for: Self.finishedDuration)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            flood.fill(animated: false)
            check.appear(animated: false)
        } else {
            popIn()
            flood.fill(animated: true, after: 0.05)
            check.appear(animated: true, after: 0.2)
        }
        // The window's shadow follows the pill once it has settled.
        shadowWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.invalidateShadow() }
        shadowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Gone at once, e.g. as Mission Control opens over it.
    func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        panel.alphaValue = 0
    }

    private func setFinished(_ finished: Bool) {
        background.layer?.removeAnimation(forKey: "pop")
        background.layer?.removeAnimation(forKey: "popFade")
        badge.isHidden = finished
        check.isHidden = !finished
        detailLabel.isHidden = !finished
        if !finished {
            flood.clear()
            check.clear()
        }
    }

    private func showDots(for space: Space, display: DisplaySpaces?) {
        if let display, display.spaces.count > 1 {
            dots.configure(spaces: display.spaces, currentID: space.managedID)
            dots.isHidden = false
        } else {
            dots.isHidden = true
        }
    }

    /// Sizes the pill and puts it where the user wants it on `screen`.
    private func place(width: CGFloat, on screen: NSScreen, position: Preferences.HUDPosition) {
        let width = min(width, screen.visibleFrame.width * 0.6)
        let visible = screen.visibleFrame
        let y: CGFloat
        switch position {
        case .top: y = visible.maxY - Self.edgeMargin - Self.height
        case .center: y = visible.midY - Self.height / 2
        case .bottom: y = visible.minY + Self.edgeMargin * 6
        }
        let pill = NSRect(x: visible.midX - width / 2, y: y, width: width, height: Self.height)
        // Room for the pop's overshoot, which grows with the pill.
        let inset = NSSize(width: max(Self.inset, ceil(width * 0.04)), height: Self.inset)
        panel.setFrame(pill.insetBy(dx: -inset.width, dy: -inset.height), display: false)
        background.frame = NSRect(origin: NSPoint(x: inset.width, y: inset.height), size: pill.size)
        panel.displayIfNeeded()
    }

    private func present(for duration: TimeInterval) {
        hideWork?.cancel()
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Springs up from a little smaller, fading in, slightly overshooting before it settles.
    private func popIn() {
        guard let layer = background.layer else { return }
        // About the pill's centre, wherever AppKit keeps the layer's anchor.
        let pivot = CGPoint(
            x: (0.5 - layer.anchorPoint.x) * layer.bounds.width,
            y: (0.5 - layer.anchorPoint.y) * layer.bounds.height
        )
        var small = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        small = CATransform3DScale(small, 0.72, 0.72, 1)
        small = CATransform3DTranslate(small, -pivot.x, -pivot.y, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = small
        spring.toValue = CATransform3DIdentity
        spring.mass = 1
        spring.stiffness = 260
        spring.damping = 15
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        layer.add(fade, forKey: "popFade")
    }

    private func hide() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = check.isHidden ? 0.2 : 0.35
            panel.animator().alphaValue = 0
        }
    }
}

/// The green that fills the pill from the left when an agent finishes, with a sheen
/// passing over it once it's full.
final class FinishFloodView: NSView {
    fileprivate let fill = CALayer()
    fileprivate let sheen = CAGradientLayer()
    static let green: NSColor = {
        let green = NSColor.systemGreen.usingColorSpace(.sRGB) ?? .systemGreen
        return green.blended(withFraction: 0.28, of: .black) ?? green
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        fill.backgroundColor = Self.green.withAlphaComponent(0.92).cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        sheen.colors = [0, 0.32, 0].map { NSColor.white.withAlphaComponent($0).cgColor }
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.opacity = 0
        layer?.addSublayer(fill)
        layer?.addSublayer(sheen)
        clear()
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange()
    }

    private func arrange() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.bounds = bounds
        fill.position = CGPoint(x: 0, y: bounds.midY)
        sheen.bounds = CGRect(x: 0, y: 0, width: max(bounds.width * 0.35, 40), height: bounds.height)
        sheen.position = CGPoint(x: -sheen.bounds.width, y: bounds.midY)
        CATransaction.commit()
    }

    func clear() {
        fill.removeAllAnimations()
        sheen.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.isHidden = true
        sheen.opacity = 0
        CATransaction.commit()
    }

    /// Floods the pill with green from the left, easing to a stop, then the sheen passes.
    func fill(animated: Bool, after delay: CFTimeInterval = 0) {
        clear()
        arrange()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.isHidden = false
        CATransaction.commit()
        guard animated else { return }
        let now = CACurrentMediaTime()
        let grow = CABasicAnimation(keyPath: "transform.scale.x")
        grow.fromValue = 0
        grow.toValue = 1
        grow.beginTime = now + delay
        grow.duration = 0.42
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)
        grow.fillMode = .backwards
        fill.add(grow, forKey: "grow")

        let pass = CABasicAnimation(keyPath: "position.x")
        pass.fromValue = -sheen.bounds.width / 2
        pass.toValue = bounds.width + sheen.bounds.width / 2
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 1, 1, 0]
        show.keyTimes = [0, 0.15, 0.8, 1]
        let sweep = CAAnimationGroup()
        sweep.animations = [pass, show]
        sweep.beginTime = now + delay + 0.38
        sweep.duration = 0.65
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sheen.add(sweep, forKey: "sheen")
    }
}

/// A white disc with a green tick, which pops in and draws itself.
final class CheckBadgeView: NSView {
    static let size: CGFloat = 22
    fileprivate let disc = CAShapeLayer()
    fileprivate let tick = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let box = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        disc.path = CGPath(ellipseIn: box, transform: nil)
        disc.fillColor = NSColor.white.withAlphaComponent(0.96).cgColor
        disc.bounds = box
        disc.contentsScale = scale
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6.2, y: 11.4))
        path.addLine(to: CGPoint(x: 9.6, y: 7.9))
        path.addLine(to: CGPoint(x: 15.9, y: 14.6))
        tick.path = path
        tick.bounds = box
        tick.fillColor = nil
        tick.strokeColor = FinishFloodView.green.cgColor
        tick.lineWidth = 2.4
        tick.lineCap = .round
        tick.lineJoin = .round
        tick.contentsScale = scale
        layer?.addSublayer(disc)
        layer?.addSublayer(tick)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.position = centre
        tick.position = centre
        CATransaction.commit()
    }

    func clear() {
        disc.removeAllAnimations()
        tick.removeAllAnimations()
    }

    func appear(animated: Bool, after delay: CFTimeInterval = 0) {
        clear()
        guard animated else { return }
        let now = CACurrentMediaTime()
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.2
        pop.toValue = 1
        pop.stiffness = 320
        pop.damping = 14
        pop.beginTime = now + delay
        pop.duration = pop.settlingDuration
        pop.fillMode = .backwards
        disc.add(pop, forKey: "pop")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = now + delay
        fade.duration = 0.1
        fade.fillMode = .backwards
        disc.add(fade, forKey: "fade")

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = now + delay + 0.14
        draw.duration = 0.26
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        draw.fillMode = .backwards
        tick.add(draw, forKey: "draw")
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

#if DEBUG
extension HUDController {
    /// The finish pop-up at four moments of its animation, top to bottom, drawn offscreen:
    /// popping in, flooding, the sheen passing, settled.
    func renderFinishPreview(to path: String, title: String, space: Space?, display: DisplaySpaces?) {
        guard let screen = NSScreen.main else { return }
        setFinished(true)
        titleLabel.stringValue = title
        detailLabel.stringValue = "finished"
        if let space { showDots(for: space, display: display) } else { dots.isHidden = true }
        let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
        let detailWidth = ceil(detailLabel.intrinsicContentSize.width) + 6
        let dotsWidth = dots.isHidden ? 0 : dots.intrinsicContentSize.width + 14
        place(width: 8 + CheckBadgeView.size + 10 + titleWidth + detailWidth + dotsWidth + 16, on: screen, position: .top)
        guard let container = panel.contentView, let root = container.layer, let pill = background.layer else { return }
        container.layoutSubtreeIfNeeded()
        container.displayIfNeeded()

        let size = container.bounds.size
        let scale: CGFloat = 2
        let moments: [(pop: CGFloat, fill: CGFloat, sheen: CGFloat?, disc: CGFloat, tick: CGFloat)] = [
            (0.8, 0, nil, 0, 0),
            (1.05, 0.5, nil, 0.6, 0),
            (1, 1, 0.5, 1, 0.6),
            (1, 1, nil, 1, 1),
        ]
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale) * moments.count, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        for (index, moment) in moments.enumerated() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let pivot = CGPoint(x: (0.5 - pill.anchorPoint.x) * pill.bounds.width, y: (0.5 - pill.anchorPoint.y) * pill.bounds.height)
            var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
            transform = CATransform3DScale(transform, moment.pop, moment.pop, 1)
            pill.transform = CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
            flood.fill.isHidden = false
            flood.fill.setValue(moment.fill, forKeyPath: "transform.scale.x")
            flood.sheen.opacity = moment.sheen == nil ? 0 : 1
            flood.sheen.position.x = (moment.sheen ?? 0) * flood.bounds.width
            check.disc.setValue(moment.disc, forKeyPath: "transform.scale")
            check.tick.strokeEnd = moment.tick
            CATransaction.commit()
            // A dark backdrop like a desktop's, so the pill's edges show.
            let row = CGFloat(moments.count - 1 - index) * size.height
            context.setFillColor(CGColor(gray: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: size.width, height: size.height))
            context.saveGState()
            context.translateBy(x: 0, y: row)
            root.render(in: context)
            context.restoreGState()
        }
        pill.transform = CATransform3DIdentity
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
#endif
