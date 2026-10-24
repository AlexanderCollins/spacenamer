import CoreGraphics

/// Lays out name pills along one Spaces bar. Every pill covers the Dock's label under it
/// and grows towards room for its text, first to a snug fit, then to its usual padding.
/// It grows evenly on both sides where it can and into whichever side has room where it
/// can't. Pills keep clear of each other and of the labels left unnamed.
public enum PillLayout {
    public struct Item: Equatable {
        /// Centre of the Dock's label.
        public var center: CGFloat
        /// For a named Space, the width that covers the Dock's label; otherwise the width of
        /// the Dock's label, to keep clear of.
        public var cover: CGFloat
        /// For a named Space, the widths its text needs; nil for a label left as it is.
        public var fit: Fit?

        public init(center: CGFloat, cover: CGFloat, fit: Fit?) {
            self.center = center
            self.cover = cover
            self.fit = fit
        }
    }

    public struct Fit: Equatable {
        /// The text with the least padding it can have.
        public var snug: CGFloat
        /// The text with its usual padding.
        public var comfortable: CGFloat

        public init(snug: CGFloat, comfortable: CGFloat) {
            self.snug = snug
            self.comfortable = comfortable
        }
    }

    public struct Pill: Equatable {
        public var center: CGFloat
        public var width: CGFloat
    }

    /// Space between two pills.
    public static let gap: CGFloat = 6
    /// Space between a pill and an unnamed label's reported frame, which already has a
    /// little room around its text.
    public static let clearance: CGFloat = 4

    /// One pill per named item (nil for the others), within `bounds`.
    public static func layout(_ items: [Item], within bounds: ClosedRange<CGFloat>) -> [Pill?] {
        let count = items.count
        // Free room either side of each item's cover: gap `i` lies before item `i`.
        var room = [CGFloat](repeating: 0, count: count + 1)
        // How far each pill reaches beyond its cover, on the left and on the right.
        var left = [CGFloat](repeating: 0, count: count)
        var right = [CGFloat](repeating: 0, count: count)

        func named(_ index: Int?) -> Bool { index.map { items[$0].fit != nil } ?? false }
        func leading(_ index: Int) -> CGFloat { items[index].center - items[index].cover / 2 }
        func trailing(_ index: Int) -> CGFloat { items[index].center + items[index].cover / 2 }

        for index in 0...count {
            let before = index > 0 ? index - 1 : nil
            let after = index < count ? index : nil
            switch (before, after) {
            case let (before?, after?) where named(before) && named(after):
                let space = leading(after) - trailing(before) - gap
                if space < 0 {
                    // Covers that collide give up the overlap between them.
                    let share = items[before].cover / (items[before].cover + items[after].cover)
                    right[before] = space * share
                    left[after] = space * (1 - share)
                }
                room[index] = max(space, 0)
            case let (before?, after?) where named(before) || named(after):
                room[index] = max(leading(after) - trailing(before) - clearance, 0)
            case let (before?, nil) where named(before):
                room[index] = max(bounds.upperBound - trailing(before), 0)
            case let (nil, after?) where named(after):
                room[index] = max(leading(after) - bounds.lowerBound, 0)
            default:
                break
            }
        }

        // Snug first, so no pill gets its usual padding while a neighbour cuts its text short.
        for comfortable in [false, true] {
            let wants = items.indices.map { index -> CGFloat in
                guard let fit = items[index].fit else { return 0 }
                return max(0, (comfortable ? fit.comfortable : fit.snug) - items[index].cover - left[index] - right[index])
            }
            grant(wants, room: &room, left: &left, right: &right)
        }

        return items.indices.map { index in
            guard named(index) else { return nil }
            return Pill(
                center: items[index].center + (right[index] - left[index]) / 2,
                width: items[index].cover + left[index] + right[index]
            )
        }
    }

    /// Shares out the room in each gap between the pills either side of it: evenly at
    /// first, then what's left over to the pills still short of what they want.
    private static func grant(_ wants: [CGFloat], room: inout [CGFloat], left: inout [CGFloat], right: inout [CGFloat]) {
        var unmet = wants
        for round in 0..<4 {
            var askLeft = [CGFloat](repeating: 0, count: wants.count)
            var askRight = askLeft
            for index in wants.indices where unmet[index] > 0.01 {
                let before = room[index], after = room[index + 1]
                if round == 0 {
                    askLeft[index] = unmet[index] / 2
                    askRight[index] = unmet[index] / 2
                } else if before + after > 0 {
                    askLeft[index] = unmet[index] * before / (before + after)
                    askRight[index] = unmet[index] * after / (before + after)
                }
            }
            var granted: CGFloat = 0
            for gap in room.indices {
                let fromBefore = gap > 0 ? askRight[gap - 1] : 0
                let fromAfter = gap < wants.count ? askLeft[gap] : 0
                let asked = fromBefore + fromAfter
                guard asked > 0 else { continue }
                let scale = min(1, room[gap] / asked)
                if fromBefore > 0 {
                    right[gap - 1] += fromBefore * scale
                    unmet[gap - 1] -= fromBefore * scale
                }
                if fromAfter > 0 {
                    left[gap] += fromAfter * scale
                    unmet[gap] -= fromAfter * scale
                }
                room[gap] -= asked * scale
                granted += asked * scale
            }
            if round > 0, granted < 0.01 { break }
        }
    }
}
