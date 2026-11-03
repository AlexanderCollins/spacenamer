import AppKit
import SpaceNamerCore

#if DEBUG
// `--render-labels <file.png>`: draws Mission Control's names offscreen and quits.
if let index = CommandLine.arguments.firstIndex(of: "--render-labels"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { LabelPreview.render(to: CommandLine.arguments[index + 1]) }
    exit(0)
}
// `--render-finish <file.png>`: draws the pop-up for an agent finishing offscreen and quits.
if let index = CommandLine.arguments.firstIndex(of: "--render-finish"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let model = AppModel(preferences: Preferences(), store: NameStore())
        model.refresh()
        let space = model.snapshot.current
        HUDController().renderFinishPreview(
            to: CommandLine.arguments[index + 1],
            title: space.map(model.title(for:)) ?? "CRM",
            space: space,
            display: space.flatMap { model.snapshot.display(withID: $0.displayID) }
        )
    }
    exit(0)
}
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
