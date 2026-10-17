import CGSBridge
import CoreGraphics
import Foundation

/// Reads the live Spaces layout from the window server. Read-only; needs no permissions.
public final class SpaceReader: Sendable {
    public init() {}

    public var isAvailable: Bool { SNSpacesAvailable() }

    public func snapshot() -> SpacesSnapshot {
        SpaceParser.parse(rawDisplays(), activeDisplayID: activeDisplayID())
    }

    public func currentManagedID(onDisplay displayID: String) -> UInt64? {
        SpaceParser.currentManagedID(in: rawDisplays(), displayID: displayID)
    }

    public func activeDisplayID() -> String? {
        SNCopyActiveMenuBarDisplayIdentifier() as String?
    }

    /// Every Space a window is on. Windows that appear on all Spaces return several IDs.
    public func spaces(forWindow windowID: CGWindowID) -> [UInt64] {
        guard let ids = SNCopySpacesForWindow(windowID) as? [NSNumber] else { return [] }
        return ids.map(\.uint64Value)
    }

    private func rawDisplays() -> [[String: Any]] {
        (SNCopyManagedDisplaySpaces() as? [[String: Any]]) ?? []
    }
}
