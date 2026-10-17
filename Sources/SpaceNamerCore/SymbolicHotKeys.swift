import Carbon.HIToolbox
import Foundation

/// A keyboard shortcut macOS handles itself, as stored in com.apple.symbolichotkeys.
public struct SystemShortcut: Equatable, Sendable {
    public let keyCode: UInt16
    /// NSEvent-style modifier mask; bit-compatible with CGEventFlags.
    public let modifierFlags: UInt64

    public init(keyCode: UInt16, modifierFlags: UInt64) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }
}

/// Reads the user's Mission Control shortcuts so the keyboard fallback presses exactly
/// what the user has configured, and so new shortcuts can be checked for clashes.
public enum SymbolicHotKeys {
    public static let missionControlID = 32
    public static let missionControlSlowID = 34 // the same with ⇧, played in slow motion
    public static let moveLeftSpaceID = 79
    public static let moveRightSpaceID = 81
    public static let switchToDesktopBaseID = 118 // Desktop 1 ... Desktop 16 are 118 ... 133

    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString

    private static let controlFlag: UInt64 = 1 << 18
    private static let functionFlag: UInt64 = 1 << 23

    private struct Entry {
        let enabled: Bool
        let shortcut: SystemShortcut?
    }

    /// The shortcut for moving one Space left (-1) or right (+1), if enabled.
    public static func moveSpace(direction: Int) -> SystemShortcut? {
        let id = direction < 0 ? moveLeftSpaceID : moveRightSpaceID
        let defaultShortcut = SystemShortcut(
            keyCode: UInt16(direction < 0 ? kVK_LeftArrow : kVK_RightArrow),
            modifierFlags: controlFlag | functionFlag
        )
        // These two are on by default, so a missing entry means "enabled with defaults".
        guard let entry = entries()[id] else { return defaultShortcut }
        guard entry.enabled else { return nil }
        return entry.shortcut ?? defaultShortcut
    }

    /// Every enabled shortcut that opens (or closes) Mission Control, including the
    /// dedicated Mission Control key found on Apple keyboards.
    public static func missionControl() -> [SystemShortcut] {
        let entries = entries()
        var result: [SystemShortcut] = [SystemShortcut(keyCode: missionControlKeyCode, modifierFlags: 0)]
        let defaultShortcut = SystemShortcut(keyCode: UInt16(kVK_UpArrow), modifierFlags: controlFlag | functionFlag)
        if let entry = entries[missionControlID] {
            if entry.enabled { result.append(entry.shortcut ?? defaultShortcut) }
        } else {
            result.append(defaultShortcut)
        }
        if let entry = entries[missionControlSlowID], entry.enabled, let shortcut = entry.shortcut {
            result.append(shortcut)
        }
        return result
    }

    /// Key code sent by the Mission Control (F3) key on Apple keyboards.
    public static let missionControlKeyCode: UInt16 = 160

    /// The "Switch to Desktop N" shortcut, if the user has enabled it.
    public static func switchToDesktop(_ number: Int) -> SystemShortcut? {
        guard (1...16).contains(number), let entry = entries()[switchToDesktopBaseID + number - 1], entry.enabled else { return nil }
        if let shortcut = entry.shortcut { return shortcut }
        guard number <= 10 else { return nil }
        let keyCode = HotKey.numberRowKeyCodes[number - 1]
        return SystemShortcut(keyCode: UInt16(keyCode), modifierFlags: controlFlag)
    }

    /// True when an enabled macOS shortcut uses the same keys, which would win over ours.
    public static func conflicts(with hotKey: HotKey) -> Bool {
        let wanted = UInt64(hotKey.cocoaModifiers)
        let mask = UInt64(HotKey.cocoaModifierMask)
        return entries().values.contains { entry in
            guard entry.enabled, let shortcut = entry.shortcut else { return false }
            return UInt32(shortcut.keyCode) == hotKey.keyCode && shortcut.modifierFlags & mask == wanted
        }
    }

    private static func entries() -> [Int: Entry] {
        CFPreferencesAppSynchronize(domain)
        guard let raw = CFPreferencesCopyAppValue(key, domain) as? [String: Any] else { return [:] }
        var result: [Int: Entry] = [:]
        for (rawID, value) in raw {
            guard let id = Int(rawID), let dictionary = value as? [String: Any] else { continue }
            let enabled = (dictionary["enabled"] as? NSNumber)?.boolValue ?? false
            var shortcut: SystemShortcut?
            if let parameters = (dictionary["value"] as? [String: Any])?["parameters"] as? [NSNumber],
               parameters.count >= 3, parameters[1].intValue != 65535 {
                shortcut = SystemShortcut(keyCode: parameters[1].uint16Value, modifierFlags: parameters[2].uint64Value)
            }
            result[id] = Entry(enabled: enabled, shortcut: shortcut)
        }
        return result
    }
}
