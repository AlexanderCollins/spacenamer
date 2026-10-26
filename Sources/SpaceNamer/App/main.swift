import AppKit

#if DEBUG
// `--render-labels <file.png>`: draws Mission Control's names offscreen and quits.
if let index = CommandLine.arguments.firstIndex(of: "--render-labels"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { LabelPreview.render(to: CommandLine.arguments[index + 1]) }
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
