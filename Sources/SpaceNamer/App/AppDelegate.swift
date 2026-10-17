import AppKit
import Combine
import SpaceNamerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusItem: StatusItemController!
    private var switcher: SwitcherController!
    private var hud: HUDController!
    private var missionControl: MissionControlOverlay!
    private let predictor = SwitchPredictor()
    private let input = InputMonitor()
    private var cancellables = Set<AnyCancellable>()
    private lazy var settings = SettingsWindowController(model: model)
    private var pendingCommands: [URLCommand] = []
    private var launched = false

    private static let requestedAccessKey = "RequestedEventAccess"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningInstance() { return }

        NSApp.mainMenu = Self.makeMainMenu()
        model = AppModel(preferences: Preferences(), store: NameStore())
        hud = HUDController()
        switcher = SwitcherController(model: model)

        model.actions = AppModel.Actions(
            toggleSwitcher: { [weak self] in self?.switcher.toggle() },
            renameCurrentSpace: { [weak self] in self?.switcher.renameCurrentSpace() },
            showSettings: { [weak self] in self?.settings.show() },
            showHUD: { [weak self] space, early in self?.showHUD(for: space, early: early) },
            switchStarted: { [weak self] space in self?.missionControl.switchStarted(to: space) },
            explainPermission: { [weak self] in self?.explainPermission() },
            explainMissingShortcuts: { [weak self] in self?.explainMissingShortcuts() }
        )
        model.start()
        statusItem = StatusItemController(model: model)
        missionControl = MissionControlOverlay(model: model)
        missionControl.onOpening = { [weak self] in self?.hud.dismiss() }
        missionControl.start()

        predictor.onMove = { [weak self] move in self?.model.predictSwitch(move) }
        predictor.swipeSign = { [weak self] in self?.model.swipeSign ?? 1 }
        input.onKey = [
            { [weak self] key in self?.predictor.handle(key) },
            { [weak self] key in self?.missionControl.handle(key) },
        ]
        input.onDockSwipe = [
            { [weak self] swipe in self?.predictor.handle(swipe) },
            { [weak self] swipe in self?.missionControl.handle(swipe) },
        ]
        let preferences = model.preferences
        Publishers.CombineLatest3(preferences.$showSwitchHUD, preferences.$showNamesInMissionControl, model.$hasAccess)
            .sink { [weak self] hud, names, access in
                guard let self else { return }
                predictor.isEnabled = (hud || names) && access
                // One tap serves both features; it only runs while one of them needs it.
                input.setEnabled(access && (hud || names))
            }
            .store(in: &cancellables)

        if !model.spacesAvailable {
            showUnsupportedAlert()
        } else if model.preferences.consumeFirstLaunch() {
            settings.show(tab: .general)
            if !model.hasAccess { requestAccessOnce() }
        }

        launched = true
        pendingCommands.forEach(model.handle)
        pendingCommands.removeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            #if DEBUG
            if url.host == "debug" {
                DebugCommands.handle(url, model: model)
                continue
            }
            #endif
            guard let command = URLCommand(url: url) else { continue }
            if launched { model.handle(command) } else { pendingCommands.append(command) }
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows Settings, since the
    /// menu bar item may be hidden behind the notch or a menu bar manager.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Single instance

    private func handOffToRunningInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let other = others.first else { return false }
        other.activate()
        NSApp.terminate(nil)
        return true
    }

    // MARK: HUD

    private func showHUD(for space: Space, early: Bool) {
        // Mission Control's bar already shows where you are, and the pill would sit on it.
        guard !missionControl.isMissionControlUp else { return }
        hud.show(
            title: model.title(for: space),
            space: space,
            display: model.snapshot.display(withID: space.displayID),
            on: model.screen(for: space.displayID),
            position: model.preferences.hudPosition,
            // Bridge the slide animation so the pill doesn't blink out before macOS lands.
            duration: early ? 1.5 : nil
        )
    }

    // MARK: Explanations

    private func requestAccessOnce() {
        UserDefaults.standard.set(true, forKey: Self.requestedAccessKey)
        EventSynth.requestAccess()
    }

    private func explainPermission() {
        guard UserDefaults.standard.bool(forKey: Self.requestedAccessKey) else {
            requestAccessOnce()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Allow SpaceNamer to switch Spaces"
        alert.informativeText = "Turn on SpaceNamer in System Settings › Privacy & Security › Accessibility. SpaceNamer uses it only to send the swipe and keyboard events that change Spaces, and to find Mission Control's labels so it can show your names there. It restarts itself once access is on."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            EventSynth.requestAccess()
            SystemSettings.openAccessibility()
        }
    }

    private func explainMissingShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Mission Control shortcuts are turned off"
        alert.informativeText = "Mission Control shortcut mode needs “Move left a space” and “Move right a space” turned on in System Settings › Keyboard › Keyboard Shortcuts › Mission Control. You can also switch to Instant mode in SpaceNamer's settings, which doesn't need them."
        alert.addButton(withTitle: "Open Keyboard Shortcuts")
        alert.addButton(withTitle: "Use Instant Mode")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: SystemSettings.openKeyboardShortcuts()
        case .alertSecondButtonReturn: model.preferences.switchMethod = .instant
        default: break
        }
    }

    private func showUnsupportedAlert() {
        let alert = NSAlert()
        alert.messageText = "SpaceNamer can't read your Spaces"
        alert.informativeText = "This version of macOS doesn't expose the Spaces layout SpaceNamer relies on. Please check for an update."
        alert.alertStyle = .critical
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Menu

    /// Never visible (the app lives in the menu bar), but it routes ⌘C, ⌘V, ⌘W and
    /// friends to text fields and windows.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit SpaceNamer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }
}
