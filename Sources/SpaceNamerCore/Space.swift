import Foundation

/// Stable identity of a Space. It is the Space's UUID, which macOS keeps when Spaces are
/// reordered in Mission Control, rearranged automatically, or restored after a reboot.
public typealias SpaceKey = String

public enum SpaceKind: String, Codable, Sendable {
    case desktop
    case fullscreen
}

public struct Space: Identifiable, Hashable, Sendable {
    /// Stable identity used to attach names and shortcuts.
    public let key: SpaceKey
    /// Window-server ID. Stable while logged in, but may be reassigned after a reboot.
    public let managedID: UInt64
    public let kind: SpaceKind
    public let displayID: String
    /// Zero-based position on its display, counting full-screen Spaces, in Mission Control order.
    public let index: Int
    /// The "Desktop N" number Mission Control shows on this display. Nil for full-screen Spaces.
    public let desktopNumber: Int?
    /// One-based number across all displays, counting desktops only. Used by the
    /// numbered shortcuts and matches macOS's own "Switch to Desktop N".
    public let position: Int?
    /// App names reported by the window server for a full-screen Space.
    public let fullscreenAppNames: [String]
    public let fullscreenPIDs: [Int32]

    public var id: SpaceKey { key }

    public init(
        key: SpaceKey,
        managedID: UInt64,
        kind: SpaceKind,
        displayID: String,
        index: Int,
        desktopNumber: Int?,
        position: Int?,
        fullscreenAppNames: [String] = [],
        fullscreenPIDs: [Int32] = []
    ) {
        self.key = key
        self.managedID = managedID
        self.kind = kind
        self.displayID = displayID
        self.index = index
        self.desktopNumber = desktopNumber
        self.position = position
        self.fullscreenAppNames = fullscreenAppNames
        self.fullscreenPIDs = fullscreenPIDs
    }

    /// The name macOS itself would show.
    public var systemName: String {
        switch kind {
        case .desktop:
            return "Desktop \(desktopNumber ?? index + 1)"
        case .fullscreen:
            return fullscreenAppNames.isEmpty ? "Full Screen" : fullscreenAppNames.joined(separator: " & ")
        }
    }
}

public struct DisplaySpaces: Identifiable, Hashable, Sendable {
    public let id: String
    public let currentManagedID: UInt64
    public let spaces: [Space]

    public init(id: String, currentManagedID: UInt64, spaces: [Space]) {
        self.id = id
        self.currentManagedID = currentManagedID
        self.spaces = spaces
    }

    public var current: Space? {
        spaces.first { $0.managedID == currentManagedID }
    }
}

public struct SpacesSnapshot: Equatable, Sendable {
    public let displays: [DisplaySpaces]
    /// Display that owns the active menu bar.
    public let activeDisplayID: String?

    public static let empty = SpacesSnapshot(displays: [], activeDisplayID: nil)

    public init(displays: [DisplaySpaces], activeDisplayID: String?) {
        self.displays = displays
        self.activeDisplayID = activeDisplayID
    }

    public var isEmpty: Bool { displays.allSatisfy { $0.spaces.isEmpty } }

    public var allSpaces: [Space] { displays.flatMap(\.spaces) }

    public var desktops: [Space] { allSpaces.filter { $0.kind == .desktop } }

    public var activeDisplay: DisplaySpaces? {
        displays.first { $0.id == activeDisplayID } ?? displays.first
    }

    /// The Space showing on the display that owns the active menu bar.
    public var current: Space? { activeDisplay?.current }

    public func display(withID id: String) -> DisplaySpaces? {
        displays.first { $0.id == id }
    }

    public func space(forKey key: SpaceKey) -> Space? {
        allSpaces.first { $0.key == key }
    }

    public func space(atPosition position: Int) -> Space? {
        allSpaces.first { $0.position == position }
    }

    public func isCurrent(_ space: Space) -> Bool {
        display(withID: space.displayID)?.currentManagedID == space.managedID
    }

    /// Current Space per display, used to detect switches.
    public var currentByDisplay: [String: UInt64] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.currentManagedID) })
    }
}
