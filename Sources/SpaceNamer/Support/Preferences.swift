import Carbon.HIToolbox
import Combine
import Foundation
import SpaceNamerCore

/// User-facing settings, persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    enum MenuBarStyle: String, CaseIterable, Identifiable {
        case numberAndName
        case name
        case number

        var id: String { rawValue }

        var title: String {
            switch self {
            case .numberAndName: return "Number and name"
            case .name: return "Name only"
            case .number: return "Number only"
            }
        }
    }

    enum HUDPosition: String, CaseIterable, Identifiable {
        case top
        case center
        case bottom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .top: return "Top"
            case .center: return "Center"
            case .bottom: return "Bottom"
            }
        }
    }

    enum PositionModifiers: String, CaseIterable, Identifiable {
        case controlOption
        case controlCommand
        case optionCommand
        case controlShift
        case controlOptionCommand

        var id: String { rawValue }

        var carbonFlags: UInt32 {
            switch self {
            case .controlOption: return UInt32(controlKey | optionKey)
            case .controlCommand: return UInt32(controlKey | cmdKey)
            case .optionCommand: return UInt32(optionKey | cmdKey)
            case .controlShift: return UInt32(controlKey | shiftKey)
            case .controlOptionCommand: return UInt32(controlKey | optionKey | cmdKey)
            }
        }

        var symbols: String { HotKey.modifierSymbols(carbon: carbonFlags) }
    }

    private enum Key {
        static let menuBarStyle = "MenuBarStyle"
        static let showSwitchHUD = "ShowSwitchHUD"
        static let hudPosition = "HUDPosition"
        static let showNamesInMissionControl = "ShowNamesInMissionControl"
        static let switchMethod = "SwitchMethod"
        static let positionShortcutsEnabled = "PositionShortcutsEnabled"
        static let positionModifiers = "PositionModifiers"
        static let wrapAround = "WrapAround"
        static let switcherHotKey = "HotKey.Switcher"
        static let backHotKey = "HotKey.Back"
        static let nextHotKey = "HotKey.Next"
        static let previousHotKey = "HotKey.Previous"
        static let renameHotKey = "HotKey.Rename"
        static let hasLaunchedBefore = "HasLaunchedBefore"
        static let checkForUpdates = "CheckForUpdates"
        static let showAgentStatus = "ShowAgentStatus"
        static let nameDesktopsFromChats = "NameDesktopsFromChats"
        static let nameChatsFromDesktops = "NameChatsFromDesktops"
    }

    static let defaultSwitcherHotKey = HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey))
    static let defaultBackHotKey = HotKey(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(controlKey | optionKey))

    private let defaults: UserDefaults

    @Published var menuBarStyle: MenuBarStyle { didSet { save(menuBarStyle.rawValue, oldValue.rawValue, Key.menuBarStyle) } }
    @Published var showSwitchHUD: Bool { didSet { save(showSwitchHUD, oldValue, Key.showSwitchHUD) } }
    @Published var hudPosition: HUDPosition { didSet { save(hudPosition.rawValue, oldValue.rawValue, Key.hudPosition) } }
    @Published var showNamesInMissionControl: Bool { didSet { save(showNamesInMissionControl, oldValue, Key.showNamesInMissionControl) } }
    @Published var switchMethod: SpaceNavigator.Method { didSet { save(switchMethod.rawValue, oldValue.rawValue, Key.switchMethod) } }
    @Published var positionShortcutsEnabled: Bool { didSet { save(positionShortcutsEnabled, oldValue, Key.positionShortcutsEnabled) } }
    @Published var positionModifiers: PositionModifiers { didSet { save(positionModifiers.rawValue, oldValue.rawValue, Key.positionModifiers) } }
    @Published var wrapAround: Bool { didSet { save(wrapAround, oldValue, Key.wrapAround) } }
    @Published var switcherHotKey: HotKey? { didSet { save(switcherHotKey, oldValue, Key.switcherHotKey) } }
    @Published var backHotKey: HotKey? { didSet { save(backHotKey, oldValue, Key.backHotKey) } }
    @Published var nextHotKey: HotKey? { didSet { save(nextHotKey, oldValue, Key.nextHotKey) } }
    @Published var previousHotKey: HotKey? { didSet { save(previousHotKey, oldValue, Key.previousHotKey) } }
    @Published var renameHotKey: HotKey? { didSet { save(renameHotKey, oldValue, Key.renameHotKey) } }
    @Published var checkForUpdates: Bool { didSet { save(checkForUpdates, oldValue, Key.checkForUpdates) } }
    @Published var showAgentStatus: Bool { didSet { save(showAgentStatus, oldValue, Key.showAgentStatus) } }
    @Published var nameDesktopsFromChats: Bool { didSet { save(nameDesktopsFromChats, oldValue, Key.nameDesktopsFromChats) } }
    @Published var nameChatsFromDesktops: Bool { didSet { save(nameChatsFromDesktops, oldValue, Key.nameChatsFromDesktops) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarStyle = defaults.string(forKey: Key.menuBarStyle).flatMap(MenuBarStyle.init) ?? .numberAndName
        showSwitchHUD = defaults.object(forKey: Key.showSwitchHUD) as? Bool ?? true
        hudPosition = defaults.string(forKey: Key.hudPosition).flatMap(HUDPosition.init) ?? .top
        showNamesInMissionControl = defaults.object(forKey: Key.showNamesInMissionControl) as? Bool ?? true
        switchMethod = defaults.string(forKey: Key.switchMethod).flatMap(SpaceNavigator.Method.init) ?? .instant
        positionShortcutsEnabled = defaults.object(forKey: Key.positionShortcutsEnabled) as? Bool ?? true
        positionModifiers = defaults.string(forKey: Key.positionModifiers).flatMap(PositionModifiers.init) ?? .controlOption
        wrapAround = defaults.object(forKey: Key.wrapAround) as? Bool ?? true
        switcherHotKey = Self.load(Key.switcherHotKey, from: defaults, default: Self.defaultSwitcherHotKey)
        backHotKey = Self.load(Key.backHotKey, from: defaults, default: Self.defaultBackHotKey)
        nextHotKey = Self.load(Key.nextHotKey, from: defaults, default: nil)
        previousHotKey = Self.load(Key.previousHotKey, from: defaults, default: nil)
        renameHotKey = Self.load(Key.renameHotKey, from: defaults, default: nil)
        checkForUpdates = defaults.object(forKey: Key.checkForUpdates) as? Bool ?? true
        showAgentStatus = defaults.object(forKey: Key.showAgentStatus) as? Bool ?? true
        nameDesktopsFromChats = defaults.object(forKey: Key.nameDesktopsFromChats) as? Bool ?? true
        nameChatsFromDesktops = defaults.object(forKey: Key.nameChatsFromDesktops) as? Bool ?? true
    }

    /// True exactly once, on the very first launch.
    func consumeFirstLaunch() -> Bool {
        guard !defaults.bool(forKey: Key.hasLaunchedBefore) else { return false }
        defaults.set(true, forKey: Key.hasLaunchedBefore)
        return true
    }

    /// Every global shortcut the app owns, for duplicate checks.
    var globalHotKeys: [HotKey] {
        [switcherHotKey, backHotKey, nextHotKey, previousHotKey, renameHotKey].compactMap { $0 }
    }

    func positionHotKey(_ position: Int) -> HotKey? {
        guard positionShortcutsEnabled, (1...HotKey.numberRowKeyCodes.count).contains(position) else { return nil }
        return HotKey(keyCode: HotKey.numberRowKeyCodes[position - 1], carbonModifiers: positionModifiers.carbonFlags)
    }

    private func save<Value: Equatable>(_ value: Value, _ oldValue: Value, _ key: String) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
    }

    // A missing key means "use the default"; an empty value means "cleared by the user".
    private func save(_ hotKey: HotKey?, _ oldValue: HotKey?, _ key: String) {
        guard hotKey != oldValue else { return }
        let data = hotKey.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: key)
    }

    private static func load(_ key: String, from defaults: UserDefaults, default fallback: HotKey?) -> HotKey? {
        guard let data = defaults.data(forKey: key) else { return fallback }
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(HotKey.self, from: data)) ?? fallback
    }
}
