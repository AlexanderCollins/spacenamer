import AppKit
import ObjectiveC

/// With "Displays have separate Spaces" every display has a menu bar, but only the active one
/// holds the real status item. AppKit fills the others with replicants: views showing a
/// snapshot of the real button, so every menu bar names the same Space.
///
/// This hands AppKit replicant views of our own (through the status item's private delegate
/// hook) and draws each one from a hidden twin of the button, set up for that replicant's
/// display. The twin is snapshotted by the same AppKit code as the real button, so inactive
/// menu bars dim it like everything else on them. Where the private API is missing, every
/// menu bar mirrors the real button as before.
@MainActor
final class MenuBarReplicas: NSObject {
    /// Sets a button up to show what the menu bar on a display (by UUID) should show.
    typealias Configure = (NSStatusBarButton, _ displayID: String) -> Void

    fileprivate static weak var current: MenuBarReplicas?

    private let statusItem: NSStatusItem
    private let configure: Configure
    private let views = NSHashTable<NSView>.weakObjects()
    /// A hidden status item, so its button draws exactly like the real one. Made outside
    /// AppKit's own replicant updates, the first time there is a replicant to draw.
    private var twin: NSStatusItem?
    private var drawing = false

    init?(statusItem: NSStatusItem, configure: @escaping Configure) {
        guard Runtime.isAvailable else { return nil }
        self.statusItem = statusItem
        self.configure = configure
        super.init()
        Self.current = self
        _ = statusItem.perform(Runtime.setDelegate, with: self)
    }

    /// Sizes the item to fit what every menu bar shows (they all give it the same width) and
    /// redraws the replicants. Call after changing the real button.
    func update() {
        guard let button = statusItem.button else { return }
        var length = NSStatusItem.variableLength
        // Replicant views live as long as AppKit keeps the replicant (one per other menu bar).
        if !views.allObjects.isEmpty, let source = twinButton() {
            let widths = NSScreen.screens.compactMap(\.displayUUID).map { displayID in
                configure(source, displayID)
                return source.intrinsicContentSize.width
            }
            if let widest = widths.max() { length = ceil(widest) }
        }
        if statusItem.length != length { statusItem.length = length }
        // AppKit redraws the replicants whenever the real button redraws.
        button.needsDisplay = true
    }

    private func twinButton() -> NSStatusBarButton? {
        if twin == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "SpaceNamerReplica"
            item.isVisible = false
            item.button?.imagePosition = .imageLeading
            item.button?.imageHugsTitle = true
            twin = item
        }
        return twin?.button
    }

    @objc(createReplicantViewOfStatusItem:)
    private func createReplicantView(of item: NSStatusItem) -> NSView {
        let view = Runtime.viewClass!.init(frame: .zero)
        views.add(view)
        DispatchQueue.main.async { [weak self] in self?.update() }
        return view
    }

    /// Draws a replicant from the twin, set up for the replicant's display. False leaves
    /// AppKit's snapshot of the real button in place.
    fileprivate func draw(_ view: NSView) -> Bool {
        guard !drawing, let button = statusItem.button, let twin, let source = twin.button,
              let window = view.window, window.responds(to: Runtime.windowStatusItem),
              let replicant = window.perform(Runtime.windowStatusItem)?.takeUnretainedValue() as? NSStatusItem,
              // Set once AppKit has placed the replicant, and kept up to date as menu bars swap.
              let displayID = replicant.perform(Runtime.displayIdentifier)?.takeUnretainedValue() as? String
        else { return false }

        configure(source, displayID)
        if twin.length != button.frame.width { twin.length = button.frame.width }
        // A hidden item's window has no height, and the button centres its title in its window.
        if let height = button.window?.frame.height, let sourceWindow = source.window,
           sourceWindow.frame.height != height, sourceWindow.responds(to: Runtime.setMenuBarHeight) {
            sourceWindow.setValue(height, forKey: "menuBarHeight")
            sourceWindow.layoutIfNeeded()
        }
        source.setFrameSize(button.frame.size)
        drawing = true
        defer { drawing = false }
        // Snapshots `source` and hands the image back to the replicant view (which passes it
        // straight through while `drawing`).
        _ = twin.perform(Runtime.redrawSnapshot, with: replicant, with: source)
        return true
    }
}

/// The private AppKit API the replicants rely on, all checked before use.
private enum Runtime {
    static let setDelegate = NSSelectorFromString("setDelegate:")
    static let displayIdentifier = NSSelectorFromString("_displayIdentifier")
    static let redrawSnapshot = NSSelectorFromString("_redrawReplicantSnapshot:sourceView:")
    static let windowStatusItem = NSSelectorFromString("statusItem")
    static let setMenuBarHeight = NSSelectorFromString("setMenuBarHeight:")
    static let setSnapshot = NSSelectorFromString("setSnapshotImage:needsInactiveTemplateStyling:appearance:needsShadow:")

    static var isAvailable: Bool {
        viewClass != nil && [setDelegate, displayIdentifier, redrawSnapshot].allSatisfy { NSStatusItem.instancesRespond(to: $0) }
    }

    /// AppKit's replicant view, with its snapshot setter first asking `MenuBarReplicas` to draw
    /// it. AppKit only redraws replicant views of its own class.
    static let viewClass: NSView.Type? = {
        typealias SetSnapshot = @convention(c) (NSView, Selector, NSImage?, ObjCBool, UInt32, ObjCBool) -> Void
        guard let base = NSClassFromString("NSStatusItemReplicantView"),
              let method = class_getInstanceMethod(base, setSnapshot),
              let encoding = method_getTypeEncoding(method),
              // (image, needs inactive styling, appearance theme, needs shadow); BOOL is `c` on Intel.
              ["v@:@BIB", "v@:@cIc"].contains(String(cString: encoding).filter { !$0.isNumber }),
              let subclass = objc_allocateClassPair(base, "SpaceNamerReplicantView", 0)
        else { return nil }

        let original = unsafeBitCast(method_getImplementation(method), to: SetSnapshot.self)
        let override: @convention(block) (NSView, NSImage?, ObjCBool, UInt32, ObjCBool) -> Void = { view, image, inactive, theme, shadow in
            let drawn = MainActor.assumeIsolated { MenuBarReplicas.current?.draw(view) ?? false }
            if !drawn { original(view, setSnapshot, image, inactive, theme, shadow) }
        }
        class_addMethod(subclass, setSnapshot, imp_implementationWithBlock(override), encoding)
        objc_registerClassPair(subclass)
        return subclass as? NSView.Type
    }()
}
