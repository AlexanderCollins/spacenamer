import AppKit
import Combine
import SpaceNamerCore

/// The menu bar item: shows the current Space and lists every Space to jump to.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let maximumTitleLength = 32

    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        super.init()

        statusItem.autosaveName = "SpaceNamer"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageHugsTitle = true
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        Publishers.Merge4(
            model.$snapshot.map { _ in () },
            model.$arriving.map { _ in () },
            model.$namesRevision.map { _ in () },
            model.preferences.$menuBarStyle.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updateButton() }
        .store(in: &cancellables)

        model.$hasAccess
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        guard let space = model.arriving ?? model.snapshot.current else {
            button.image = Badges.number("–", filled: false)
            button.title = ""
            button.toolTip = "SpaceNamer"
            return
        }

        let name = model.title(for: space)
        let truncated = name.count > Self.maximumTitleLength ? String(name.prefix(Self.maximumTitleLength - 1)) + "…" : name
        let isFullscreen = space.kind == .fullscreen

        switch model.preferences.menuBarStyle {
        case .numberAndName:
            button.image = Badges.badge(for: space, filled: true)
            button.title = " " + truncated
        case .name:
            button.image = nil
            button.title = truncated
        case .number:
            button.image = isFullscreen ? Badges.fullscreen() : Badges.badge(for: space, filled: true)
            button.title = ""
        }

        var tooltip = name
        if model.hasCustomName(space) { tooltip += " (\(model.systemName(for: space)))" }
        if !model.hasAccess { tooltip += "\nAccessibility access is needed to switch Spaces." }
        button.toolTip = tooltip
        button.setAccessibilityLabel("Current Space: \(name)")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
        model.refreshPermission()
        menu.removeAllItems()

        if !model.hasAccess {
            let item = NSMenuItem(title: "Allow Switching Spaces…", action: #selector(grantAccess), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let snapshot = model.snapshot
        let showHeaders = snapshot.displays.count > 1
        for (offset, display) in snapshot.displays.enumerated() {
            if showHeaders {
                if offset > 0 { menu.addItem(.separator()) }
                menu.addItem(Self.header(model.displayName(for: display.id)))
            }
            for space in display.spaces {
                menu.addItem(item(for: space, isCurrent: space.managedID == display.currentManagedID))
            }
        }
        if snapshot.isEmpty {
            let item = NSMenuItem(title: "Spaces are unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let rename = NSMenuItem(title: "Rename Current Space…", action: #selector(renameCurrent), keyEquivalent: "")
        rename.target = self
        rename.showShortcut(model.preferences.renameHotKey)
        menu.addItem(rename)

        let switcher = NSMenuItem(title: "Open Switcher", action: #selector(openSwitcher), keyEquivalent: "")
        switcher.target = self
        switcher.showShortcut(model.preferences.switcherHotKey)
        menu.addItem(switcher)

        menu.addItem(.separator())

        let hud = NSMenuItem(title: "Show Name When Switching", action: #selector(toggleHUD), keyEquivalent: "")
        hud.target = self
        hud.state = model.preferences.showSwitchHUD ? .on : .off
        menu.addItem(hud)

        let missionControl = NSMenuItem(title: "Show Names in Mission Control", action: #selector(toggleMissionControl), keyEquivalent: "")
        missionControl.target = self
        missionControl.state = model.preferences.showNamesInMissionControl ? .on : .off
        menu.addItem(missionControl)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit SpaceNamer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(for space: Space, isCurrent: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: model.title(for: space), action: #selector(jump(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = space.key
        item.state = isCurrent ? .on : .off
        item.image = Badges.badge(for: space, filled: isCurrent)
        if model.hasCustomName(space) { item.toolTip = model.systemName(for: space) }
        if let hotKey = model.store.hotKey(for: space.key) {
            item.showShortcut(hotKey)
        } else if let position = space.position {
            item.showShortcut(model.preferences.positionHotKey(position))
        }
        return item
    }

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return .sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // Menu actions run while the menu is closing; defer anything that posts events.

    @objc private func jump(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? SpaceKey else { return }
        DispatchQueue.main.async { [model] in model.jump(toKey: key) }
    }

    @objc private func renameCurrent() {
        DispatchQueue.main.async { [model] in model.actions.renameCurrentSpace() }
    }

    @objc private func openSwitcher() {
        DispatchQueue.main.async { [model] in model.actions.toggleSwitcher() }
    }

    @objc private func toggleHUD() {
        model.preferences.showSwitchHUD.toggle()
    }

    @objc private func toggleMissionControl() {
        model.preferences.showNamesInMissionControl.toggle()
    }

    @objc private func openSettings() {
        model.actions.showSettings()
    }

    @objc private func grantAccess() {
        model.actions.explainPermission()
    }
}
