import QuartzCore

/// How the Dock animates Mission Control's Spaces bar, measured frame by frame from
/// 120 fps recordings (macOS 26). Each timing says when, relative to an event we can
/// observe, the Dock's motion starts, how long it lasts, and its easing.
///
/// The overlay replays these with Core Animation so the render server interpolates our
/// labels on exactly the same frames as the Dock's own, instead of chasing them.
enum DockMotion {
    struct Timing {
        /// Seconds from the reference event to the start of the motion.
        let delay: CFTimeInterval
        let duration: CFTimeInterval
        let curve: CubicBezier
    }

    /// Bar slides down from above. Reference: the Dock creating Mission Control's
    /// interface, which tracks the start of its slide more closely than the key press
    /// does (the Dock takes a variable few milliseconds to act on a key). Over 12 runs
    /// this lands within 0.8 pt rms of the Dock's labels, 3.4 pt at worst.
    static let open = Timing(delay: 0.0038, duration: 0.2642, curve: CubicBezier(0.488, 0.040, 0.587, 1.003))
    /// Bar slides back up. Reference: the Dock removing Mission Control's interface.
    static let closeCollapsed = Timing(delay: 0.0326, duration: 0.3154, curve: CubicBezier(0.411, 0.457, 0.337, 1.132))
    static let closeExpanded = Timing(delay: 0.0330, duration: 0.2357, curve: CubicBezier(0.436, 0.241, 0.514, 1.046))
    /// Leaving by clicking the background or the current desktop: the same slide, anchored
    /// to the click (the Dock keeps its interface around for another ~250 ms, too late to
    /// wait for). Clicking another desktop zooms it up over the bar instead.
    static let closeExpandedAfterClick = Timing(delay: 0.0295, duration: 0.2357, curve: CubicBezier(0.436, 0.241, 0.514, 1.046))
    static let closeCollapsedAfterClick = Timing(delay: 0.0291, duration: 0.3154, curve: CubicBezier(0.411, 0.457, 0.337, 1.132))

    /// Asked back while leaving: the bar turns around from wherever it is, eased in and
    /// out, whatever asked (a key, or a swipe it then ignores).
    static let reverse = Timing(delay: 0.010, duration: 0.245, curve: CubicBezier(0.42, 0, 0.58, 1))

    /// A click while the bar is still growing into thumbnails: the names carry on growing
    /// as the bar slides, and the slide starts sooner and covers less of the bar's height
    /// the earlier the click (~5 ms and 86% up to half way; the usual once grown).
    static func closeExpandedAfterClick(expandProgress progress: Double) -> (timing: Timing, distance: Double) {
        let late = smoothstep(min(max((progress - 0.5) / 0.45, 0), 1))
        let base = closeExpandedAfterClick
        let timing = Timing(delay: 0.005 + (base.delay - 0.005) * late, duration: base.duration, curve: base.curve)
        return (timing, 0.865 + (1 - 0.865) * late)
    }
    /// Names-only bar grows into thumbnails on hover; names move and shrink together.
    /// Reference: the Dock publishing the new layout. Fit within 0.5 pt rms, 1.1 pt worst.
    static let expand = Timing(delay: 0.0035, duration: 0.2639, curve: CubicBezier(0.435, 0.013, 0.546, 1.050))
    /// Thumbnails glide to a new position (pointer leaves, Spaces added or removed).
    /// Reference: the Dock publishing the new layout. Fit within 1.1 pt rms.
    static let shift = Timing(delay: 0.0106, duration: 0.2355, curve: CubicBezier(0.200, 0.000, 0.231, 0.982))
    /// A desktop added with the + button: names drop to thumbnail height quickly while
    /// sliding sideways to their new places over about a second. Reference: the Dock
    /// publishing the new layout. Fit within 0.4 pt (y) and 1.0 pt (x) rms.
    static let addX = Timing(delay: -0.0470, duration: 1.1340, curve: CubicBezier(0.465, -0.059, 0.548, 1.055))
    static let addY = Timing(delay: 0.0133, duration: 0.2523, curve: CubicBezier(0.414, 0.011, 0.492, 1.032))
    /// A desktop removed: the others close the gap. Fit within 1.0 pt rms.
    static let remove = Timing(delay: 0.0039, duration: 0.2682, curve: CubicBezier(0.341, 0.001, 0.270, 0.990))
    /// Used when we only learn about Mission Control once it has finished opening.
    static let lateFade: CFTimeInterval = 0.16

    /// How far into a slide (0...1) the labels reach full opacity when appearing, and
    /// start fading when leaving. Both happen while the labels are at the screen edge:
    /// a pill that is see-through while on screen would let the Dock's label show.
    static let fadeInEnd = 0.3
    static let fadeOutStart = 0.85

    /// Opacity for a given slide progress, shared by timed and gesture-driven motion.
    static func openingOpacity(_ progress: Double) -> Double {
        smoothstep(min(max(progress / fadeInEnd, 0), 1))
    }

    static func closingOpacity(_ progress: Double) -> Double {
        1 - smoothstep(min(max((progress - fadeOutStart) / (1 - fadeOutStart), 0), 1))
    }

    private static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}

/// How the Dock finishes a three-finger swipe once it's let go: the bar springs the rest of
/// the way in (or out, or back) from where the fingers left it, starting at a speed that
/// grows with how fast they were moving. Fitted to the Dock's own reports over replays of
/// real swipes, opening and closing, names-only and with previews (about 1.2 pt rms on
/// the names-only bar). Works in fractions of the bar's height.
struct DockFinish {
    static let omega = 8.77
    static let zeta = 0.767

    /// Starting speed, in bar heights per second, for a swipe let go at `velocity`.
    static func speed(forReleaseVelocity velocity: Double) -> Double {
        2.0 + 1.53 * abs(velocity)
    }

    /// Host time it starts from.
    let reference: CFTimeInterval
    /// How much of the bar is left to go at the start (0...1).
    let distance: Double
    /// Speed toward the end at the start, in bar heights per second.
    let speed: Double

    /// How much is left to go at host time `time`; never past the end.
    func remaining(at time: CFTimeInterval) -> Double {
        let t = time - reference
        guard t > 0 else { return distance }
        let w = Self.omega, z = Self.zeta
        let wd = w * (1 - z * z).squareRoot()
        let r = exp(-z * w * t) * (distance * cos(wd * t) + (z * w * distance - speed) / wd * sin(wd * t))
        return max(r, 0)
    }

    /// Speed toward the end at host time `time`, in bar heights per second.
    func speed(at time: CFTimeInterval) -> Double {
        let step = 0.002
        return (remaining(at: time - step) - remaining(at: time + step)) / (2 * step)
    }

    /// Long enough to be within a hair of the end.
    var duration: CFTimeInterval {
        var t = 0.05
        while t < 1.5, remaining(at: reference + t) > 0.002 || speed(at: reference + t) > 0.02 { t += 0.01 }
        return t
    }
}

/// A CSS/Core Animation style cubic Bézier easing from (0,0) to (1,1). Unlike
/// `CAMediaTimingFunction`, control points may leave 0...1 in y, which the Dock's
/// spring-like curves need; we sample it into keyframes instead.
struct CubicBezier {
    let x1: Double, y1: Double, x2: Double, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    func value(at x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let s = parameter(for: x)
        return 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s
    }

    /// Solves x(s) = x with Newton's method, falling back to bisection.
    private func parameter(for x: Double) -> Double {
        var s = x
        for _ in 0..<8 {
            let error = sampleX(s) - x
            if abs(error) < 1e-7 { return s }
            let slope = derivativeX(s)
            if abs(slope) < 1e-6 { break }
            s -= error / slope
        }
        var low = 0.0, high = 1.0
        s = x
        for _ in 0..<40 {
            let current = sampleX(s)
            if abs(current - x) < 1e-7 { return s }
            if current < x { low = s } else { high = s }
            s = (low + high) / 2
        }
        return s
    }

    private func sampleX(_ s: Double) -> Double {
        3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s
    }

    private func derivativeX(_ s: Double) -> Double {
        3 * (1 - s) * (1 - s) * x1 + 6 * (1 - s) * s * (x2 - x1) + 3 * s * s * (1 - x2)
    }
}

extension DockMotion.Timing {
    /// A keyframe animation of `keyPath` from `from` to `to` that follows this timing,
    /// starting `delay` after `reference` (host time, as from `CACurrentMediaTime`).
    func animation(_ keyPath: String, from: CGFloat, to: CGFloat, reference: CFTimeInterval, on layer: CALayer, samples: Int = 48) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        var values: [NSNumber] = []
        var times: [NSNumber] = []
        for index in 0...samples {
            let t = Double(index) / Double(samples)
            values.append(NSNumber(value: Double(from) + Double(to - from) * curve.value(at: t)))
            times.append(NSNumber(value: t))
        }
        animation.values = values
        animation.keyTimes = times
        animation.calculationMode = .linear
        animation.duration = duration
        animation.beginTime = layer.convertTime(reference + delay, from: nil)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = true
        return animation
    }

    /// Progress (0...1) of this motion at host time `time`.
    func progress(at time: CFTimeInterval, reference: CFTimeInterval) -> Double {
        curve.value(at: (time - reference - delay) / duration)
    }

    var end: CFTimeInterval { delay + duration }
}
