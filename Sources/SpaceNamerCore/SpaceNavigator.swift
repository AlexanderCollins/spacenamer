import Foundation
import os

/// Moves to a Space without SIP changes or Dock injection.
///
/// macOS offers no public "go to Space X" call, but the Dock does respond to input:
/// - `.instant` posts synthetic trackpad swipes with a very high exit velocity, which the
///   Dock completes immediately, one Space per swipe. Works for any number of Spaces,
///   including full-screen apps, and needs no system shortcuts to be configured.
/// - `.keyboard` presses the user's own Mission Control shortcuts: "Switch to Desktop N"
///   when enabled, otherwise "Move left/right a space" step by step.
///
/// Every step is verified against the window server. If swipes stop landing, the navigator
/// falls back to the keyboard; if a swipe lands the wrong way it learns the direction.
@MainActor
public final class SpaceNavigator {
    public enum Method: String, Codable, CaseIterable, Sendable {
        case instant
        case keyboard
    }

    public enum Outcome: Equatable, Sendable {
        case arrived
        case alreadyThere
        case notFound
        case needsPermission
        case noShortcut
        case cancelled
        case failed
    }

    public var method: Method = .instant
    public private(set) var isJumping = false

    private let reader: SpaceReader
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.alexandercollins.SpaceNamer", category: "jump")
    private var generation = 0
    private static let swipeSignKey = "SwipeDirectionSign"

    public init(reader: SpaceReader, defaults: UserDefaults = .standard) {
        self.reader = reader
        self.defaults = defaults
    }

    /// +1 or -1: which swipe direction moves to the next Space on this Mac.
    public private(set) var swipeSign: Int {
        get { defaults.integer(forKey: Self.swipeSignKey) < 0 ? -1 : 1 }
        set { defaults.set(newValue, forKey: Self.swipeSignKey) }
    }

    /// Jumps to a Space. A newer call cancels one still in flight.
    public func jump(to key: SpaceKey) async -> Outcome {
        generation &+= 1
        let token = generation
        let started = Date()
        let outcome = await performJump(to: key, token: token)
        log.info("jump \(key, privacy: .public) via \(self.method.rawValue, privacy: .public): \(String(describing: outcome), privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return outcome
    }

    private func performJump(to key: SpaceKey, token: Int) async -> Outcome {
        let snapshot = reader.snapshot()
        guard let target = snapshot.space(forKey: key),
              let display = snapshot.display(withID: target.displayID)
        else { return .notFound }

        let otherDisplay = snapshot.displays.count > 1 && !DisplayResolver.isCursor(onDisplay: display.id)
        if display.currentManagedID == target.managedID {
            // Already showing; just bring that display forward.
            if otherDisplay { DisplayResolver.moveCursor(toDisplay: display.id) }
            return .alreadyThere
        }

        guard EventSynth.canPost else { return .needsPermission }

        isJumping = true
        defer { if token == generation { isJumping = false } }

        if otherDisplay {
            DisplayResolver.moveCursor(toDisplay: display.id)
            await pause(milliseconds: 40)
        }

        if method == .keyboard, let number = target.position, let shortcut = SymbolicHotKeys.switchToDesktop(number) {
            EventSynth.press(shortcut)
            if await waitUntilCurrent(target.managedID, on: display.id, timeout: 1.5, token: token) {
                return .arrived
            }
            guard token == generation else { return .cancelled }
        }

        return await step(toward: target.managedID, on: display.id, token: token)
    }

    // MARK: Stepping

    private func step(toward targetID: UInt64, on displayID: String, token: Int) async -> Outcome {
        var useSwipes = method == .instant
        var stalls = 0
        var rounds = 0

        while true {
            guard token == generation else { return .cancelled }
            let snapshot = reader.snapshot()
            guard let display = snapshot.display(withID: displayID), let current = display.current else { return .failed }
            // The target may have been closed or moved to another display mid-jump.
            guard let target = display.spaces.first(where: { $0.managedID == targetID }) else { return .notFound }
            if current.managedID == targetID { return .arrived }

            rounds += 1
            if rounds > 2 * display.spaces.count + 6 { return .failed }

            let offset = target.index - current.index
            let direction = offset > 0 ? 1 : -1
            log.debug("round \(rounds): index \(current.index) → \(target.index) using \(useSwipes ? "swipes" : "keys", privacy: .public)")
            if useSwipes {
                // The Dock folds a burst of swipes into a single move straight to the target.
                EventSynth.swipe(direction: direction * swipeSign, count: abs(offset))
            } else if let shortcut = SymbolicHotKeys.moveSpace(direction: direction) {
                EventSynth.press(shortcut)
            } else {
                return .noShortcut
            }

            let landedID = await waitForChange(
                from: current.managedID,
                on: displayID,
                timeout: useSwipes ? 0.5 : 1.2,
                settle: useSwipes ? 0.05 : 0,
                token: token
            )
            guard let landedID else {
                guard token == generation else { return .cancelled }
                stalls += 1
                log.debug("no change after \(useSwipes ? "swipes" : "keys", privacy: .public) (stall \(stalls))")
                if stalls >= 2 {
                    guard useSwipes else { return .failed }
                    useSwipes = false
                    stalls = 0
                }
                continue
            }
            stalls = 0

            if useSwipes, let landed = reader.snapshot().display(withID: displayID)?.spaces.first(where: { $0.managedID == landedID }) {
                let moved = landed.index - current.index
                if moved != 0, (moved > 0) != (direction > 0) {
                    log.info("swipes moved the other way; flipping direction")
                    swipeSign = -swipeSign
                }
            }
        }
    }

    /// Waits for the display's current Space to change, then (if `settle` > 0) until it
    /// has stopped changing for that long. Returns the Space it ended on.
    private func waitForChange(from managedID: UInt64, on displayID: String, timeout: TimeInterval, settle: TimeInterval, token: Int) async -> UInt64? {
        let deadline = Date().addingTimeInterval(timeout)
        var landed: UInt64?
        var lastChange = Date()
        while Date() < deadline || landed != nil {
            await pause(milliseconds: 4)
            guard token == generation else { return nil }
            guard let now = reader.currentManagedID(onDisplay: displayID) else { continue }
            if now != (landed ?? managedID) {
                landed = now
                lastChange = Date()
            }
            if let landed, Date().timeIntervalSince(lastChange) >= settle {
                return landed
            }
        }
        return landed
    }

    private func waitUntilCurrent(_ managedID: UInt64, on displayID: String, timeout: TimeInterval, token: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await pause(milliseconds: 10)
            guard token == generation else { return false }
            if reader.currentManagedID(onDisplay: displayID) == managedID { return true }
        }
        return false
    }

    private func pause(milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}
