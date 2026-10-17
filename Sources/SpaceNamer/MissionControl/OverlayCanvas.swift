import AppKit
import QuartzCore
import SpaceNamerCore

/// Where and how big one name pill is, in the overlay's screen-local, top-left-origin space.
struct LabelGeometry: Equatable {
    var center: CGPoint
    var size: CGSize
    var textScale: CGFloat

    var hitRect: CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

/// How one label should move to its new geometry: the Dock's timing per axis, anchored
/// at a host time.
struct LabelTransition {
    let reference: CFTimeInterval
    let x: DockMotion.Timing
    let y: DockMotion.Timing
    let size: DockMotion.Timing

    /// A quick ease to the target's size (and place), e.g. undoing the names' growth.
    static func resize(at reference: CFTimeInterval, duration: CFTimeInterval) -> LabelTransition {
        let timing = DockMotion.Timing(delay: 0, duration: duration, curve: CubicBezier(0.25, 0.1, 0.25, 1))
        return LabelTransition(reference: reference, x: timing, y: timing, size: timing)
    }

    static func expand(at reference: CFTimeInterval) -> LabelTransition {
        LabelTransition(reference: reference, x: DockMotion.expand, y: DockMotion.expand, size: DockMotion.expand)
    }

    static func shift(at reference: CFTimeInterval) -> LabelTransition {
        LabelTransition(reference: reference, x: DockMotion.shift, y: DockMotion.shift, size: DockMotion.shift)
    }

    static func add(at reference: CFTimeInterval) -> LabelTransition {
        LabelTransition(reference: reference, x: DockMotion.addX, y: DockMotion.addY, size: DockMotion.addY)
    }

    static func remove(at reference: CFTimeInterval) -> LabelTransition {
        LabelTransition(reference: reference, x: DockMotion.remove, y: DockMotion.remove, size: DockMotion.remove)
    }
}

struct LabelStyle: Equatable {
    var fill: CGColor
    var currentFill: CGColor
    var text: CGColor

    static func resolve(for appearance: NSAppearance) -> LabelStyle {
        var style = LabelStyle(fill: .black, currentFill: .black, text: .black)
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            style = LabelStyle(
                // Opaque, so the Dock's own label underneath can never show through.
                fill: (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.94, alpha: 1)).cgColor,
                currentFill: (dark ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.80, alpha: 1)).cgColor,
                text: (dark ? NSColor.white : NSColor(white: 0.08, alpha: 1)).cgColor
            )
        }
        return style
    }
}

/// A transparent, click-through window above Mission Control on one display.
final class OverlayWindow: NSPanel {
    let canvas: OverlayCanvas

    init(screen: NSScreen) {
        canvas = OverlayCanvas(scale: screen.backingScaleFactor)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = Self.everySpace
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // The window is on every Space, so without this the Dock would draw it into each
        // desktop's Mission Control preview.
        sharingType = .none
        #if DEBUG
        // Lets screen recordings see the names, to check them against the Dock's.
        if UserDefaults.standard.bool(forKey: "OverlayCapturable") { sharingType = .readOnly }
        #endif

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.layer = canvas.root
        host.wantsLayer = true
        contentView = host
        canvas.resize(to: screen.frame.size)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// On every Space, so the names are there whichever Space Mission Control opens on.
    private static let everySpace: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    private static let currentSpaceOnly: NSWindow.CollectionBehavior = [.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]

    /// The desktop the window is lent to, if any (see `lend(toDesktop:)`).
    private(set) var lentTo: UInt64?

    /// Shows the window above the desktops, where Space switches inside Mission Control
    /// slide past it rather than carrying it along.
    func show() {
        orderFrontRegardless()
        returnFromDesktop()
    }

    /// When a desktop is clicked in Mission Control, the window server zooms that
    /// desktop's windows up over the bar. Lent to the current desktop for that moment,
    /// the zoom covers the names just as it covers the Dock's own labels.
    func lend(toDesktop desktop: UInt64) {
        guard lentTo != desktop else { return }
        collectionBehavior = Self.currentSpaceOnly
        OverlaySpace.lend(self, toDesktop: desktop)
        lentTo = desktop
    }

    func returnFromDesktop() {
        collectionBehavior = Self.everySpace
        OverlaySpace.adopt(self)
        lentTo = nil
    }
}

/// Layer tree for one display's labels. `slide` moves with the Spaces bar as it slides
/// in and out; each label moves within it as the bar's layout changes.
final class OverlayCanvas {
    /// Owned by the hosting view; AppKit manages its geometry.
    let root = CALayer()
    /// Top-left-origin space matching Accessibility coordinates. AppKit resets
    /// `isGeometryFlipped` on a view's own layer, so the flip lives one level down.
    private let content = CALayer()
    let slide = CALayer()
    private(set) var labels: [SpaceKey: NameLabelLayer] = [:]
    private let scale: CGFloat
    var style = LabelStyle.resolve(for: NSApp.effectiveAppearance) {
        didSet { if style != oldValue { labels.values.forEach { $0.apply(style: style) } } }
    }

    init(scale: CGFloat) {
        self.scale = scale
        root.actions = OverlayCanvas.noActions
        content.actions = OverlayCanvas.noActions
        content.isGeometryFlipped = true
        content.anchorPoint = .zero
        slide.actions = OverlayCanvas.noActions
        slide.anchorPoint = .zero
        root.addSublayer(content)
        content.addSublayer(slide)
    }

    static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "opacity": NSNull(),
        "transform": NSNull(), "sublayerTransform": NSNull(), "contents": NSNull(),
        "backgroundColor": NSNull(), "cornerRadius": NSNull(), "hidden": NSNull(),
        "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
        "string": NSNull(), "foregroundColor": NSNull(),
    ]

    func resize(to size: CGSize) {
        withoutAnimation {
            root.frame = CGRect(origin: .zero, size: size)
            content.frame = root.bounds
            slide.frame = content.bounds
        }
    }

    // MARK: Slide

    /// Current vertical offset of the bar (0 = fully in), as shown on screen right now.
    var presentedOffset: CGFloat {
        (slide.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat)
            ?? (slide.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
    }

    var presentedOpacity: Float { slide.presentation()?.opacity ?? slide.opacity }

    /// Places the bar directly (gesture tracking): no animation.
    func setSlide(offset: CGFloat, opacity: Float) {
        withoutAnimation {
            slide.removeAnimation(forKey: "slide")
            slide.removeAnimation(forKey: "fade")
            slide.setValue(offset, forKeyPath: "transform.translation.y")
            slide.opacity = opacity
        }
    }

    /// Animates the bar between offsets on a Dock timing, with opacity following the
    /// same progress through `opacity(progress)`.
    func animateSlide(from: CGFloat, to: CGFloat, timing: DockMotion.Timing, reference: CFTimeInterval, opacity: @escaping (Double) -> Double) {
        withoutAnimation {
            slide.setValue(to, forKeyPath: "transform.translation.y")
            slide.opacity = Float(opacity(1))
        }
        let move = timing.animation("transform.translation.y", from: from, to: to, reference: reference, on: slide)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = (0...48).map { NSNumber(value: opacity(timing.curve.value(at: Double($0) / 48))) }
        fade.keyTimes = move.keyTimes
        fade.calculationMode = .linear
        fade.duration = move.duration
        fade.beginTime = move.beginTime
        fade.fillMode = .both
        slide.add(move, forKey: "slide")
        slide.add(fade, forKey: "fade")
    }

    /// Slides along any path: `offset` and `opacity` give the values at each host time
    /// from `reference` to `reference + duration`, sampled into keyframes.
    func animateSlide(reference: CFTimeInterval, duration: CFTimeInterval, offset: (CFTimeInterval) -> CGFloat, opacity: (CFTimeInterval) -> Float) {
        let samples = max(8, Int(duration * 120))
        let times = (0...samples).map { reference + duration * Double($0) / Double(samples) }
        withoutAnimation {
            slide.setValue(offset(times.last!), forKeyPath: "transform.translation.y")
            slide.opacity = opacity(times.last!)
        }
        let keyTimes = (0...samples).map { NSNumber(value: Double($0) / Double(samples)) }
        let move = CAKeyframeAnimation(keyPath: "transform.translation.y")
        move.values = times.map { NSNumber(value: Double(offset($0))) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = times.map { NSNumber(value: opacity($0)) }
        for animation in [move, fade] {
            animation.keyTimes = keyTimes
            animation.calculationMode = .linear
            animation.duration = duration
            animation.beginTime = slide.convertTime(reference, from: nil)
            animation.fillMode = .both
        }
        slide.add(move, forKey: "slide")
        slide.add(fade, forKey: "fade")
    }

    /// Fades the whole bar in or out without moving it.
    func fadeSlide(to opacity: Float, duration: CFTimeInterval) {
        let from = presentedOpacity
        withoutAnimation {
            slide.removeAnimation(forKey: "fade")
            slide.opacity = opacity
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = opacity
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        slide.add(fade, forKey: "fade")
    }

    // MARK: Labels

    struct Target {
        let key: SpaceKey
        let name: String
        let isCurrent: Bool
        let geometry: LabelGeometry
        let maxWidth: CGFloat
    }

    /// Brings the labels in line with `targets`. Existing labels move with `transition`
    /// (or jump when nil); new ones fade in where they belong; stale ones fade out.
    func update(_ targets: [Target], transition: LabelTransition?, fadeNew: Bool) {
        var seen = Set<SpaceKey>()
        for target in targets {
            seen.insert(target.key)
            if let label = labels[target.key], !label.isLeaving {
                label.setContent(name: target.name, isCurrent: target.isCurrent, width: target.maxWidth, textScale: target.geometry.textScale)
                label.move(to: geometry(fitting: target, label: label), transition: transition)
            } else {
                labels[target.key]?.removeFromSuperlayer()
                let label = NameLabelLayer(scale: scale, style: style)
                label.setContent(name: target.name, isCurrent: target.isCurrent, width: target.maxWidth, textScale: target.geometry.textScale)
                label.move(to: geometry(fitting: target, label: label), transition: nil)
                slide.addSublayer(label)
                labels[target.key] = label
                if fadeNew { label.fade(from: 0, to: 1, duration: 0.14) }
            }
        }
        for (key, label) in labels where !seen.contains(key) && !label.isLeaving {
            label.leave()
            labels[key] = nil
        }
    }

    /// Makes every pill at least `height` tall over `duration`, so the Dock's labels stay
    /// covered through the timing jitter of a fast exit.
    func growLabels(toHeight height: CGFloat, duration: CFTimeInterval) {
        labels.values.forEach { $0.grow(toHeight: height, duration: duration) }
    }

    func removeAllLabels() {
        labels.values.forEach { $0.removeFromSuperlayer() }
        labels.removeAll()
    }

    /// The target's width already accounts for text and neighbours (see `layoutWidths`).
    private func geometry(fitting target: Target, label: NameLabelLayer) -> LabelGeometry {
        var geometry = target.geometry
        geometry.size.width = target.maxWidth
        return geometry
    }

    /// Horizontal padding inside a pill, either side of the text, at full scale.
    static let padding: CGFloat = 9

    /// Pill widths for one bar: each pill wants room for its text (and to cover the
    /// Dock's label under it); neighbours that would collide share the gap between them
    /// in proportion, and no pill reaches over an unnamed neighbour's label.
    static func layoutWidths(
        centers: [CGFloat],
        baseWidths: [CGFloat],
        names: [String?],
        textScale: [CGFloat],
        nativeWidths: [CGFloat]
    ) -> [CGFloat] {
        var widths = names.indices.map { index -> CGFloat in
            guard let name = names[index] else { return nativeWidths[index] }
            let text = NameLabelLayer.textWidth(of: name) * textScale[index]
            return min(max(baseWidths[index], ceil(text) + 2 * padding * textScale[index]), 260)
        }
        for index in 0..<max(0, widths.count - 1) {
            let gap = centers[index + 1] - centers[index] - 6
            let left = widths[index] / 2, right = widths[index + 1] / 2
            guard left + right > gap, gap > 0 else { continue }
            switch (names[index] != nil, names[index + 1] != nil) {
            case (true, true):
                let scale = gap / (left + right)
                widths[index] = 2 * left * scale
                widths[index + 1] = 2 * right * scale
            case (true, false):
                widths[index] = 2 * max(gap - right, baseWidths[index] / 2)
            case (false, true):
                widths[index + 1] = 2 * max(gap - left, baseWidths[index + 1] / 2)
            case (false, false):
                break
            }
        }
        return widths
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// One name pill. Its bounds are centred on (0, 0) so the text stays centred while the
/// pill's size animates.
final class NameLabelLayer: CALayer {
    private let text = CATextLayer()
    private(set) var geometry: LabelGeometry?
    private(set) var isLeaving = false
    private var labelName = ""
    private var isCurrent = false
    private var labelStyle: LabelStyle
    private var textRoom: CGFloat = 0
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    init(scale: CGFloat, style: LabelStyle) {
        labelStyle = style
        super.init()
        actions = OverlayCanvas.noActions
        contentsScale = scale
        masksToBounds = false
        text.actions = OverlayCanvas.noActions
        text.contentsScale = scale
        text.font = Self.font
        text.fontSize = Self.font.pointSize
        text.alignmentMode = .center
        text.truncationMode = .end
        text.isWrapped = false
        text.position = .zero
        addSublayer(text)
        apply(style: style)
    }

    override init(layer: Any) {
        labelStyle = (layer as? NameLabelLayer)?.labelStyle ?? LabelStyle.resolve(for: NSApp.effectiveAppearance)
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var textWidth: CGFloat { Self.textWidth(of: labelName) }

    static func textWidth(of name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: font]).width)
    }

    func apply(style: LabelStyle) {
        labelStyle = style
        backgroundColor = isCurrent ? style.currentFill : style.fill
        text.foregroundColor = style.text
    }

    /// `width` is the pill's width on screen; the text is drawn at full size and scaled
    /// by `textScale`, so the room it gets is measured before scaling.
    /// How long the current-Space highlight takes to move, as the Dock's does.
    static let highlightFade: CFTimeInterval = 0.1

    func setContent(name: String, isCurrent: Bool, width: CGFloat, textScale: CGFloat) {
        let room = max(10, width / max(textScale, 0.1) - 2 * OverlayCanvas.padding + 2)
        if name != labelName || room != textRoom {
            labelName = name
            textRoom = room
            text.string = name
            let height = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
            text.bounds = CGRect(x: 0, y: 0, width: min(textWidth + 2, room), height: height)
        }
        if isCurrent != self.isCurrent {
            self.isCurrent = isCurrent
            let from = presentation()?.backgroundColor ?? backgroundColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backgroundColor = isCurrent ? labelStyle.currentFill : labelStyle.fill
            CATransaction.commit()
            // Cross-fade like the Dock's highlight when the current Space changes; a pill
            // that isn't on screen yet just takes its colour.
            if superlayer != nil, let from {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = from
                fade.toValue = backgroundColor
                fade.duration = Self.highlightFade
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                add(fade, forKey: "highlight")
            }
        }
    }

    func move(to target: LabelGeometry, transition: LabelTransition?) {
        // Re-rendering the same layout (names or the Space list refreshing) must never
        // disturb a move that's already under way.
        if target == geometry { return }
        let presented = presentation()
        let fromPosition = presented?.position ?? position
        let fromSize = presented?.bounds.size ?? bounds.size
        let fromScale = (text.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat)
            ?? (text.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = target.center
        bounds = Self.centeredBounds(target.size)
        cornerRadius = target.size.height / 2
        text.setValue(target.textScale, forKeyPath: "transform.scale")
        CATransaction.commit()

        let previous = geometry
        geometry = target
        guard let transition, previous != nil else {
            removeAnimation(forKey: "x")
            removeAnimation(forKey: "y")
            removeAnimation(forKey: "bounds")
            removeAnimation(forKey: "radius")
            text.removeAnimation(forKey: "scale")
            return
        }

        add(transition.x.animation("position.x", from: fromPosition.x, to: target.center.x, reference: transition.reference, on: self), forKey: "x")
        add(transition.y.animation("position.y", from: fromPosition.y, to: target.center.y, reference: transition.reference, on: self), forKey: "y")

        let sizeTiming = transition.size
        let bounds = CAKeyframeAnimation(keyPath: "bounds")
        let radius = CAKeyframeAnimation(keyPath: "cornerRadius")
        var boundsValues: [NSValue] = []
        var radiusValues: [NSNumber] = []
        var times: [NSNumber] = []
        for index in 0...48 {
            let t = Double(index) / 48
            let p = CGFloat(sizeTiming.curve.value(at: t))
            let size = CGSize(
                width: fromSize.width + (target.size.width - fromSize.width) * p,
                height: fromSize.height + (target.size.height - fromSize.height) * p
            )
            boundsValues.append(NSValue(rect: Self.centeredBounds(size)))
            radiusValues.append(NSNumber(value: Double(size.height / 2)))
            times.append(NSNumber(value: t))
        }
        for animation in [bounds, radius] {
            animation.keyTimes = times
            animation.calculationMode = .linear
            animation.duration = sizeTiming.duration
            animation.beginTime = convertTime(transition.reference + sizeTiming.delay, from: nil)
            animation.fillMode = .both
        }
        bounds.values = boundsValues
        radius.values = radiusValues
        add(bounds, forKey: "bounds")
        add(radius, forKey: "radius")
        text.add(sizeTiming.animation("transform.scale", from: fromScale, to: target.textScale, reference: transition.reference, on: text), forKey: "scale")
    }

    func grow(toHeight height: CGFloat, duration: CFTimeInterval) {
        guard var target = geometry, target.size.height < height else { return }
        target.size.height = height
        let now = CACurrentMediaTime()
        move(to: target, transition: LabelTransition(
            reference: now,
            x: DockMotion.Timing(delay: 0, duration: duration, curve: CubicBezier(0.25, 0.1, 0.25, 1)),
            y: DockMotion.Timing(delay: 0, duration: duration, curve: CubicBezier(0.25, 0.1, 0.25, 1)),
            size: DockMotion.Timing(delay: 0, duration: duration, curve: CubicBezier(0.25, 0.1, 0.25, 1))
        ))
    }

    func fade(from: Float, to: Float, duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = to
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(fade, forKey: "fade")
    }

    /// Fades out, then removes itself.
    func leave() {
        isLeaving = true
        let current = presentation()?.opacity ?? opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperlayer() }
        fade(from: current, to: 0, duration: 0.07)
        CATransaction.commit()
    }

    private static func centeredBounds(_ size: CGSize) -> CGRect {
        CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    }
}
