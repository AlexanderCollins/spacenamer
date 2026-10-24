import AppKit
import Combine
import SpaceNamerCore

/// The menu bar item: shows the current Space and lists every Space to jump to. With a menu
/// bar on each display, each names the Space on its own display.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let maximumTitleLength = 32

    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var replicas: MenuBarReplicas?
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
        replicas = MenuBarReplicas(statusItem: statusItem) { [weak self] button, displayID in
            guard let self else { return }
            show(model.menuBarSpace(onDisplay: displayID), on: button)
        }

        // The real button moves to whichever display's menu bar is active.
        NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)
            .sink { [weak self] notification in
                guard let self, (notification.object as? NSWindow) === statusItem.button?.window else { return }
                updateButton()
            }
            .store(in: &cancellables)

        Publishers.Merge4(
            model.$snapshot.map { _ in () },
            model.$arriving.map { _ in () },
            model.$namesRevision.map { _ in () },
            model.preferences.$menuBarStyle.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updateButton() }
        .store(in: &cancellables)

        Publishers.Merge4(
            model.$hasAccess.map { _ in () },
            model.updates.$status.map { _ in () },
            model.agents.$statusBySpace.map { _ in () },
            model.preferences.$showAgentStatus.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updateButton() }
        .store(in: &cancellables)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let space = model.menuBarSpace(onDisplay: button.window?.screen?.displayUUID)
        show(space, on: button)
        if let space {
            let name = model.title(for: space)
            var tooltip = name
            if model.hasCustomName(space) { tooltip += " (\(model.systemName(for: space)))" }
            if !model.hasAccess { tooltip += "\nAccessibility access is needed to switch Spaces." }
            if let (state, space) = attention {
                tooltip += "\n\(model.title(for: space)): \(state.title.lowercased())"
            }
            if model.updates.available != nil { tooltip += "\nAn update is available." }
            button.toolTip = tooltip
            button.setAccessibilityLabel("Current Space: \(name)")
        } else {
            button.toolTip = "SpaceNamer"
        }
        replicas?.update()
    }

    /// Sets a button up to name `space`: the real one, or the twin that draws another
    /// display's menu bar.
    private func show(_ space: Space?, on button: NSStatusBarButton) {
        showSpace(space, on: button)
        var marks: [NSImage] = []
        if let (state, _) = attention { marks.append(AgentStyle.dot(state, diameter: 7)) }
        if model.updates.available != nil { marks.append(Badges.update(pointSize: 11)) }
        guard !marks.isEmpty else { return }
        // After the name, keeping the title's own font and colour; only the marks are coloured.
        let title = NSMutableAttributedString(attributedString: button.attributedTitle)
        let font = button.font ?? NSFont.menuBarFont(ofSize: 0)
        let attributes = title.length > 0 ? title.attributes(at: 0, effectiveRange: nil) : [.font: font]
        for image in marks {
            let mark = NSTextAttachment()
            mark.image = image
            mark.bounds = NSRect(x: 0, y: round((font.capHeight - image.size.height) / 2), width: image.size.width, height: image.size.height)
            title.append(NSAttributedString(string: " ", attributes: attributes))
            title.append(NSAttributedString(attachment: mark))
        }
        button.attributedTitle = title
    }

    /// The desktop most in need of a look: an agent waiting on the user, failed or done
    /// (working isn't worth a mark).
    private var attention: (AgentState, Space)? {
        var found: (AgentState, Space)?
        for space in model.snapshot.allSpaces {
            guard let state = model.agents.status(for: space)?.state, state != .working,
                  state.urgency > (found?.0.urgency ?? 0)
            else { continue }
            found = (state, space)
        }
        return found
    }

    private func showSpace(_ space: Space?, on button: NSStatusBarButton) {
        guard let space else {
            button.image = Badges.number("–", filled: false)
            button.title = ""
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

        if let update = model.updates.available {
            let item = NSMenuItem(title: "Update SpaceNamer…", action: #selector(offerUpdate), keyEquivalent: "")
            item.target = self
            item.image = Badges.update()
            menu.addItem(item)
            for change in update.changes.prefix(UpdateChecker.listedChanges) {
                menu.addItem(self.item(for: change, indented: true))
            }
            let more = update.changes.count - UpdateChecker.listedChanges
            if more > 0 {
                let all = NSMenu()
                update.changes.forEach { all.addItem(self.item(for: $0, indented: false)) }
                all.addItem(.separator())
                let page = NSMenuItem(title: "View All on GitHub", action: #selector(openPage(_:)), keyEquivalent: "")
                page.target = self
                page.representedObject = update.page
                all.addItem(page)
                let item = NSMenuItem(title: "• and \(more) more", action: nil, keyEquivalent: "")
                item.indentationLevel = 1
                item.submenu = all
                menu.addItem(item)
            }
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
        if let status = model.agents.status(for: space) {
            // The agent's state after the name: a coloured dot and a few words.
            let title = NSMutableAttributedString(string: model.title(for: space) + "  ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
            let dot = NSTextAttachment()
            dot.image = AgentStyle.dot(status.state)
            dot.bounds = NSRect(x: 0, y: 0.5, width: 8, height: 8)
            title.append(NSAttributedString(attachment: dot))
            title.append(NSAttributedString(string: " " + AgentStyle.describe(status), attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = title
        }
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

    /// A change in an update; choosing it opens the commit on GitHub.
    private func item(for change: AvailableUpdate.Change, indented: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: (indented ? "• " : "") + change.summary, action: #selector(openPage(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = change.page
        item.indentationLevel = indented ? 1 : 0
        item.toolTip = "Open on GitHub"
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

    @objc private func openPage(_ sender: NSMenuItem) {
        guard let page = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(page)
    }

    @objc private func offerUpdate() {
        DispatchQueue.main.async { [model] in model.updates.offerUpdate() }
    }
}
