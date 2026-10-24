import AppKit
import SwiftUI

/// The Settings window, with native toolbar tabs.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: Int {
        case general
        case spaces
        case shortcuts
        case agents
        case about
    }

    private let model: AppModel
    private let tabs = NSTabViewController()

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        super.init(window: window)
        window.delegate = self

        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        addTab("General", symbol: "gearshape", GeneralSettingsView(model: model, preferences: model.preferences, updates: model.updates))
        addTab("Spaces", symbol: "rectangle.3.group", SpacesSettingsView(model: model))
        addTab("Shortcuts", symbol: "keyboard", ShortcutsSettingsView(model: model, preferences: model.preferences))
        addTab("Agents", symbol: "sparkles", AgentsSettingsView(model: model, preferences: model.preferences, agents: model.agents))
        addTab("About", symbol: "info.circle", AboutView())
        window.contentViewController = tabs
        window.toolbarStyle = .preference
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func addTab<Content: View>(_ title: String, symbol: String, _ view: Content) {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    func show(tab: Tab? = nil) {
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        model.refresh()
        model.refreshApps()
        model.refreshPermission()
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
