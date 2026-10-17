import AppKit
import Carbon.HIToolbox
import Combine
import SpaceNamerCore

/// Keyboard-first switcher: type to filter, ↩ to jump, ⌘R to rename, ⌘1–⌘0 to jump by number.
@MainActor
final class SwitcherController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Mode: Equatable {
        case search
        /// Renaming one Space. `returnToSearch` is false when opened straight into rename.
        case rename(SpaceKey, returnToSearch: Bool)
    }

    private struct Item {
        let space: Space
        let title: String
        let ranges: [NSRange]
        let subtitle: String?
        let isCurrent: Bool
        let accessory: String?
        let apps: [NSRunningApplication]
    }

    private enum Row {
        case header(String)
        case space(Item)
    }

    private static let width: CGFloat = 600
    private static let headerHeight: CGFloat = 54
    private static let footerHeight: CGFloat = 30
    private static let maximumListHeight: CGFloat = 8 * SpaceCellView.height + 2 * HeaderCellView.height
    private static let emptyListHeight: CGFloat = 56

    private let model: AppModel
    private let panel = SwitcherPanel()
    private let searchField = NSTextField()
    private let modeIcon = NSImageView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No matching Spaces")
    private let footerLabel = NSTextField(labelWithString: "")
    private var listHeight: NSLayoutConstraint!
    private var rows: [Row] = []
    private var mode: Mode = .search
    private var cancellables = Set<AnyCancellable>()
    private var anchorTop: CGFloat?

    init(model: AppModel) {
        self.model = model
        super.init()
        buildInterface()

        panel.keyEquivalentHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        panel.cancelHandler = { [weak self] in self?.cancel() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }

        Publishers.Merge3(
            model.$snapshot.map { _ in () },
            model.$namesRevision.map { _ in () },
            model.$appsBySpace.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            guard let self, panel.isVisible else { return }
            reload(keepingSelection: true)
        }
        .store(in: &cancellables)
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Showing

    func toggle() {
        if panel.isVisible { close() } else { show() }
    }

    func show() {
        present(mode: .search)
    }

    /// Opens straight into renaming the current Space.
    func renameCurrentSpace() {
        model.refresh()
        guard let current = model.snapshot.current else {
            NSSound.beep()
            return
        }
        present(mode: .rename(current.key, returnToSearch: false))
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        anchorTop = nil
    }

    private func present(mode: Mode) {
        model.refresh()
        model.refreshApps()
        anchorTop = nil
        enter(mode)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        if case .rename = mode { searchField.currentEditor()?.selectAll(nil) }
    }

    private func enter(_ newMode: Mode) {
        mode = newMode
        switch newMode {
        case .search:
            searchField.stringValue = ""
            searchField.placeholderString = "Jump to a Space…"
            modeIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
            footerLabel.stringValue = "↩ Jump    ⌘R Rename    ⌘1–⌘0 Jump to number    esc Close"
        case .rename(let key, _):
            let space = model.snapshot.space(forKey: key)
            searchField.stringValue = space.flatMap { model.store.name(for: $0.key) } ?? ""
            let systemName = space.map { model.systemName(for: $0) } ?? "this Space"
            searchField.placeholderString = "Name for “\(systemName)”"
            modeIcon.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Rename")
            footerLabel.stringValue = "↩ Save    Leave empty to use “\(systemName)”    esc Cancel"
        }
        reload(keepingSelection: false)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: (searchField.stringValue as NSString).length, length: 0)
        }
    }

    // MARK: Building the list

    private func reload(keepingSelection: Bool) {
        let selectedKey = keepingSelection ? selectedItem?.space.key : nil
        rows = buildRows()
        tableView.reloadData()

        if let selectedKey, let row = rowIndex(for: selectedKey) {
            select(row)
        } else {
            select(defaultSelection())
        }
        layout()
    }

    private func buildRows() -> [Row] {
        let snapshot = model.snapshot
        switch mode {
        case .rename(let key, _):
            guard let space = snapshot.space(forKey: key) else { return [] }
            return [.space(item(for: space, ranges: [], showDisplay: snapshot.displays.count > 1))]
        case .search:
            break
        }

        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            let showHeaders = snapshot.displays.count > 1
            return snapshot.displays.flatMap { display -> [Row] in
                let header: [Row] = showHeaders ? [.header(model.displayName(for: display.id))] : []
                return header + display.spaces.map { .space(item(for: $0, ranges: [], showDisplay: false)) }
            }
        }

        let ordered = snapshot.allSpaces.enumerated().compactMap { offset, space -> (Int, Int, Item)? in
            guard let (score, ranges) = score(space, query: query) else { return nil }
            return (score, offset, item(for: space, ranges: ranges, showDisplay: snapshot.displays.count > 1))
        }
        return ordered
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map { .space($0.2) }
    }

    private func score(_ space: Space, query: String) -> (Int, [NSRange])? {
        var best: (Int, [NSRange])?
        func consider(_ score: Int, _ ranges: [NSRange] = []) {
            if best == nil || score > best!.0 { best = (score, ranges) }
        }

        if let position = space.position, query == String(position) { consider(10_000) }
        if let match = FuzzyMatcher.match(query, in: model.title(for: space)) { consider(match.score + 300, match.ranges) }
        if model.hasCustomName(space), let match = FuzzyMatcher.match(query, in: model.systemName(for: space)) {
            consider(match.score)
        }
        for app in model.appsBySpace[space.managedID] ?? [] {
            if let name = app.localizedName, let match = FuzzyMatcher.match(query, in: name) { consider(match.score - 400) }
        }
        return best
    }

    private func item(for space: Space, ranges: [NSRange], showDisplay: Bool) -> Item {
        let isCurrent = model.snapshot.isCurrent(space)
        var details: [String] = []
        if model.hasCustomName(space) {
            details.append(model.systemName(for: space))
        } else if space.kind == .fullscreen {
            details.append("Full Screen")
        }
        if showDisplay { details.append(model.displayName(for: space.displayID)) }

        return Item(
            space: space,
            title: model.title(for: space),
            ranges: ranges,
            subtitle: details.isEmpty ? nil : details.joined(separator: " · "),
            isCurrent: isCurrent,
            accessory: isCurrent ? "Current" : model.shortcutLabel(for: space),
            apps: model.appsBySpace[space.managedID] ?? []
        )
    }

    private func defaultSelection() -> Int? {
        let spaceRows = rows.indices.filter { if case .space = rows[$0] { return true } else { return false } }
        guard case .search = mode, searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            return spaceRows.first
        }
        // Like ⌘-Tab: start on the Space you were on before this one.
        if let previous = model.previousSpace, let row = rowIndex(for: previous.key) { return row }
        return spaceRows.first { row in
            if case .space(let item) = rows[row] { return !item.isCurrent }
            return false
        } ?? spaceRows.first
    }

    private func rowIndex(for key: SpaceKey) -> Int? {
        rows.firstIndex { row in
            if case .space(let item) = row { return item.space.key == key }
            return false
        }
    }

    private var selectedItem: Item? {
        let row = tableView.selectedRow
        guard rows.indices.contains(row), case .space(let item) = rows[row] else { return nil }
        return item
    }

    private func select(_ row: Int?) {
        guard let row, rows.indices.contains(row) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func moveSelection(by offset: Int) {
        let spaceRows = rows.indices.filter { if case .space = rows[$0] { return true } else { return false } }
        guard !spaceRows.isEmpty else { return }
        let current = spaceRows.firstIndex(of: tableView.selectedRow)
        let next: Int
        if let current {
            next = (current + offset + spaceRows.count) % spaceRows.count
        } else {
            next = offset > 0 ? 0 : spaceRows.count - 1
        }
        select(spaceRows[next])
    }

    // MARK: Actions

    private func activateSelection() {
        guard let item = selectedItem else {
            NSSound.beep()
            return
        }
        jump(to: item.space)
    }

    private func jump(to space: Space) {
        close()
        // Let the panel leave the screen before the Space changes underneath it.
        DispatchQueue.main.async { [model] in model.jump(to: space) }
    }

    private func beginRename() {
        guard let item = selectedItem else { return }
        enter(.rename(item.space.key, returnToSearch: true))
        searchField.currentEditor()?.selectAll(nil)
    }

    private func commitRename() {
        guard case .rename(let key, let returnToSearch) = mode else { return }
        if let space = model.snapshot.space(forKey: key) {
            model.rename(space, to: searchField.stringValue)
        }
        if returnToSearch {
            enter(.search)
            if let row = rowIndex(for: key) { select(row) }
        } else {
            close()
        }
    }

    private func cancel() {
        if case .rename(let key, true) = mode {
            enter(.search)
            if let row = rowIndex(for: key) { select(row) }
        } else {
            close()
        }
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags == .command else { return false }
        let keyCode = Int(event.keyCode)

        // No main menu is visible while the panel is up, so route editing keys ourselves.
        let editing: [Int: Selector] = [
            kVK_ANSI_A: #selector(NSText.selectAll(_:)),
            kVK_ANSI_C: #selector(NSText.copy(_:)),
            kVK_ANSI_V: #selector(NSText.paste(_:)),
            kVK_ANSI_X: #selector(NSText.cut(_:)),
            kVK_ANSI_Z: Selector(("undo:")),
        ]
        if let action = editing[keyCode] {
            return NSApp.sendAction(action, to: nil, from: self)
        }

        switch keyCode {
        case kVK_ANSI_R:
            if case .search = mode { beginRename() }
            return true
        case kVK_ANSI_W:
            close()
            return true
        case kVK_ANSI_Comma:
            close()
            model.actions.showSettings()
            return true
        default:
            if case .search = mode, let index = HotKey.numberRowKeyCodes.firstIndex(of: UInt32(keyCode)) {
                if let space = model.snapshot.space(atPosition: index + 1) { jump(to: space) } else { NSSound.beep() }
                return true
            }
            return false
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard rows.indices.contains(row), case .space(let item) = rows[row] else { return }
        if case .rename = mode { return }
        jump(to: item.space)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard case .search = mode else { return }
        rows = buildRows()
        tableView.reloadData()
        select(defaultSelection())
        layout()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let renaming: Bool
        if case .rename = mode { renaming = true } else { renaming = false }

        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            if renaming { commitRename() } else { activateSelection() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            guard !renaming else { return false }
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            guard !renaming else { return false }
            moveSelection(by: 1)
            return true
        default:
            return false
        }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return HeaderCellView.height }
        return SpaceCellView.height
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .space = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SwitcherRowView()
        if case .header = rows[row] { view.selectionHighlightStyle = .none }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: HeaderCellView.identifier, owner: nil) as? HeaderCellView ?? HeaderCellView()
            cell.configure(title)
            return cell
        case .space(let item):
            let cell = tableView.makeView(withIdentifier: SpaceCellView.identifier, owner: nil) as? SpaceCellView ?? SpaceCellView()
            cell.configure(
                title: item.title,
                ranges: item.ranges,
                subtitle: item.subtitle,
                space: item.space,
                isCurrent: item.isCurrent,
                accessory: item.accessory,
                apps: item.apps
            )
            return cell
        }
    }

    // MARK: Layout

    private func layout() {
        let contentHeight = rows.reduce(CGFloat(0)) { total, row in
            if case .header = row { return total + HeaderCellView.height }
            return total + SpaceCellView.height
        } + 12
        let list = rows.isEmpty ? Self.emptyListHeight : min(contentHeight, Self.maximumListHeight)
        listHeight.constant = list
        emptyLabel.isHidden = !rows.isEmpty
        scrollView.isHidden = rows.isEmpty

        let height = Self.headerHeight + 1 + list + 1 + Self.footerHeight
        let screen = screenForPanel()
        let visible = screen.visibleFrame
        let top = anchorTop ?? (visible.maxY - visible.height * 0.18)
        anchorTop = top
        let frame = NSRect(x: visible.midX - Self.width / 2, y: top - height, width: Self.width, height: height)
        panel.setFrame(frame, display: true)
    }

    private func screenForPanel() -> NSScreen {
        if panel.isVisible, let screen = panel.screen { return screen }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func buildInterface() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background

        modeIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        modeIcon.contentTintColor = .secondaryLabelColor
        modeIcon.setContentHuggingPriority(.required, for: .horizontal)

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 22, weight: .light)
        searchField.delegate = self
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true

        let header = NSStackView(views: [modeIcon, searchField])
        header.orientation = .horizontal
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Space"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.floatsGroupRows = false
        tableView.refusesFirstResponder = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator

        let listContainer = NSView()
        for view in [scrollView, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            listContainer.addSubview(view)
        }

        for view in [header, topSeparator, listContainer, bottomSeparator, footerLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }

        listHeight = listContainer.heightAnchor.constraint(equalToConstant: Self.emptyListHeight)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: background.topAnchor),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            topSeparator.topAnchor.constraint(equalTo: header.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            listContainer.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            listContainer.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            listHeight,

            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),

            bottomSeparator.topAnchor.constraint(equalTo: listContainer.bottomAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            footerLabel.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor),
            footerLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            footerLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            footerLabel.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
    }
}
