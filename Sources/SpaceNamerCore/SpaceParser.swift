import Foundation

/// Turns the window server's managed-display-spaces dictionaries into a `SpacesSnapshot`.
/// Kept free of side effects so it can be tested against recorded layouts.
public enum SpaceParser {
    private enum Raw {
        static let displayIdentifier = "Display Identifier"
        static let currentSpace = "Current Space"
        static let spaces = "Spaces"
        static let managedID = "ManagedSpaceID"
        static let id64 = "id64"
        static let type = "type"
        static let uuid = "uuid"
        static let tileLayoutManager = "TileLayoutManager"
        static let tileSpaces = "TileSpaces"
        static let appName = "appName"
        static let pid = "pid"
    }

    private enum RawType {
        static let user: UInt64 = 0
        static let fullscreen: UInt64 = 4
    }

    public static func parse(_ rawDisplays: [[String: Any]], activeDisplayID: String?) -> SpacesSnapshot {
        var displays: [DisplaySpaces] = []
        var seenKeys = Set<SpaceKey>()
        var position = 0

        for rawDisplay in rawDisplays {
            guard let displayID = rawDisplay[Raw.displayIdentifier] as? String,
                  let rawSpaces = rawDisplay[Raw.spaces] as? [[String: Any]]
            else { continue }

            let currentID = (rawDisplay[Raw.currentSpace] as? [String: Any]).flatMap { managedID(of: $0) } ?? 0
            var spaces: [Space] = []
            var desktopNumber = 0
            var assignedPrimary = false

            for rawSpace in rawSpaces {
                guard let managedID = managedID(of: rawSpace) else { continue }
                let type = number(rawSpace[Raw.type]) ?? RawType.user
                let tiles = (rawSpace[Raw.tileLayoutManager] as? [String: Any])?[Raw.tileSpaces] as? [[String: Any]]
                let isFullscreen = type == RawType.fullscreen || rawSpace[Raw.tileLayoutManager] != nil
                guard type == RawType.user || isFullscreen else { continue }

                // Some systems report the original desktop of a display with an empty UUID.
                // There is at most one such desktop per display, so key it by display.
                let uuid = (rawSpace[Raw.uuid] as? String) ?? ""
                var key: SpaceKey
                if !uuid.isEmpty {
                    key = uuid
                } else if !isFullscreen && !assignedPrimary {
                    key = "\(displayID)/primary"
                    assignedPrimary = true
                } else {
                    key = "space-\(managedID)"
                }
                if seenKeys.contains(key) { key += "#\(managedID)" }
                seenKeys.insert(key)

                let kind: SpaceKind = isFullscreen ? .fullscreen : .desktop
                var thisDesktopNumber: Int?
                var thisPosition: Int?
                if kind == .desktop {
                    desktopNumber += 1
                    position += 1
                    thisDesktopNumber = desktopNumber
                    thisPosition = position
                }

                var appNames = (tiles ?? []).compactMap { $0[Raw.appName] as? String }.filter { !$0.isEmpty }
                appNames = appNames.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
                var pids = (tiles ?? []).compactMap { number($0[Raw.pid]).map { Int32(truncatingIfNeeded: $0) } }
                if let pid = number(rawSpace[Raw.pid]) { pids.append(Int32(truncatingIfNeeded: pid)) }

                spaces.append(Space(
                    key: key,
                    managedID: managedID,
                    kind: kind,
                    displayID: displayID,
                    index: spaces.count,
                    desktopNumber: thisDesktopNumber,
                    position: thisPosition,
                    fullscreenAppNames: appNames,
                    fullscreenPIDs: Array(Set(pids)).sorted()
                ))
            }

            displays.append(DisplaySpaces(id: displayID, currentManagedID: currentID, spaces: spaces))
        }

        return SpacesSnapshot(displays: displays, activeDisplayID: activeDisplayID)
    }

    /// Reads only the current Space of one display; cheaper than a full parse.
    public static func currentManagedID(in rawDisplays: [[String: Any]], displayID: String) -> UInt64? {
        guard let rawDisplay = rawDisplays.first(where: { ($0[Raw.displayIdentifier] as? String) == displayID }),
              let current = rawDisplay[Raw.currentSpace] as? [String: Any]
        else { return nil }
        return managedID(of: current)
    }

    private static func managedID(of raw: [String: Any]) -> UInt64? {
        number(raw[Raw.managedID]) ?? number(raw[Raw.id64])
    }

    private static func number(_ value: Any?) -> UInt64? {
        switch value {
        case let number as NSNumber: return number.uint64Value
        case let int as Int: return UInt64(truncatingIfNeeded: int)
        case let uint as UInt64: return uint
        default: return nil
        }
    }
}
